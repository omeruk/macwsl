import Darwin
import Foundation
import MawClient
import MawCore
import MawProtocol
import MawXPC
import Testing
import os

@testable import MawDaemonKit

/// An exporting machine that writes the chunks it is given, and fails, holds, or reports a
/// file system check as the test says.
final class FakeExportingMachine: ExportingMachine, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(
        initialState: (calls: [String](), failingStep: String?.none, heldStep: String?.none))
    let chunks: [[UInt8]]
    let checkStatus: Int
    private let released = OneTimeSignal()
    let discarded = OneTimeSignal()
    private let quiet = OSAllocatedUnfairLock(initialState: false)

    init(chunks: [[UInt8]] = [Array("first ".utf8), Array("second".utf8)], checkStatus: Int = 0) {
        self.chunks = chunks
        self.checkStatus = checkStatus
    }

    var calls: [String] { state.withLock { $0.calls } }
    var failingStep: String? {
        get { state.withLock { $0.failingStep } }
        set { state.withLock { $0.failingStep = newValue } }
    }
    /// A step that waits until `release()` or `discard()`.
    var heldStep: String? {
        get { state.withLock { $0.heldStep } }
        set { state.withLock { $0.heldStep = newValue } }
    }

    /// Whether a held archive goes on after `discard()` instead of failing, as the provisioning
    /// machine's does: it hands over the next chunk, and returns without an error once the
    /// output refuses it.
    var archivesOnAfterDiscard: Bool {
        get { quiet.withLock { $0 } }
        set { quiet.withLock { $0 = newValue } }
    }

    func release() {
        released.fire()
    }

    private func step(_ name: String) async throws(MawError) {
        state.withLock { $0.calls.append(name) }
        if heldStep == name {
            await released.wait()
            if calls.contains("discard") {
                throw .vmFailed(reason: "the machine was stopped")
            }
        }
        if failingStep == name {
            throw .provisioningFailed(step: "\(name)ing", reason: "the test failed it")
        }
    }

    func boot(disk: URL) async throws(MawError) {
        try await step("boot")
        state.withLock { $0.calls.append("disk \(disk.lastPathComponent)") }
    }

    func checkFileSystem() async throws(MawError) -> RootFileSystemCheck {
        try await step("check")
        return RootFileSystemCheck(e2fsckStatus: checkStatus)
    }

    func mountReadOnly() async throws(MawError) {
        try await step("mount")
    }

    func archive(into consume: @escaping @Sendable (UnsafeRawBufferPointer) -> Bool)
        async throws(MawError)
    {
        state.withLock { $0.calls.append("archive") }
        for (index, chunk) in chunks.enumerated() {
            let accepted = chunk.withUnsafeBytes { consume($0) }
            if !accepted {
                state.withLock { $0.calls.append("stopped") }
                return
            }
            if index == 0, heldStep == "archive" {
                await released.wait()
                if calls.contains("discard"), !archivesOnAfterDiscard {
                    throw .guestAgentFailed(reason: "the machine was stopped")
                }
            }
        }
        if failingStep == "archive" {
            throw .provisioningFailed(step: "writing the archive", reason: "bsdtar exited with 1")
        }
    }

    func finish() async throws(MawError) {
        try await step("finish")
    }

    func discard() async {
        state.withLock { $0.calls.append("discard") }
        discarded.fire()
        released.fire()
    }
}

/// The exporter against a fake exporting machine and a store in a temporary directory.
@Suite(.timeLimit(.minutes(2))) struct ExporterTests {
    let distros: TemporaryStore
    let operations = DistributionOperations()
    let machine: FakeExportingMachine
    let running = OSAllocatedUnfairLock(initialState: false)
    let made = OSAllocatedUnfairLock(initialState: 0)
    let logs: URL

    init() throws {
        distros = try TemporaryStore()
        try distros.install("Copy")
        machine = FakeExportingMachine()
        logs = distros.home.appending(path: "logs", directoryHint: .isDirectory)
    }

    init(machine: FakeExportingMachine) throws {
        distros = try TemporaryStore()
        try distros.install("Copy")
        self.machine = machine
        logs = distros.home.appending(path: "logs", directoryHint: .isDirectory)
    }

    var exporter: Exporter {
        let machine = self.machine
        let running = self.running
        let made = self.made
        return Exporter(
            store: distros.store, operations: operations,
            makeMachine: { (_: DistroName) throws(MawError) -> any ExportingMachine in
                made.withLock { $0 += 1 }
                return machine
            },
            isStopped: { _ in !running.withLock { $0 } }, logDirectory: logs)
    }

    static let copy = try! DistroName("Copy")

    @Test func exportsThroughEachStepInOrder() async throws {
        let pipe = try DrainedPipe()
        let destination = OwnedDescriptor(dup(pipe.writer.rawValue))
        pipe.writer.close()
        let events = OSAllocatedUnfairLock(initialState: [InstallProgress]())
        let summary = try await exporter.export(
            ExportRequest(name: try DistroName("COPY"), format: .tar), to: destination,
            for: 42
        ) { event in events.withLock { $0.append(event) } }

        #expect(summary.name == Self.copy)
        #expect(summary.format == .tar)
        #expect(summary.bytes == 12)
        #expect(try await pipe.bytes() == Array("first second".utf8))
        #expect(machine.calls == ["boot", "disk disk.img", "check", "mount", "archive", "finish"])
        let steps = events.withLock { $0 }.compactMap { event -> String? in
            if case .started(let step) = event { return step.rawValue }
            return nil
        }
        #expect(steps == ["prepare", "check", "archive", "finish"])
        #expect(destination.rawValue == -1, "The descriptor was not closed.")
        #expect(operations.operation(on: Self.copy) == nil)
    }

    @Test func refusesADistributionThatIsNotStopped() async throws {
        running.withLock { $0 = true }
        await #expect(throws: MawError.distributionRunning(Self.copy)) {
            try await exporter.check(try DistroName("copy"))
        }
        await #expect(throws: MawError.distributionRunning(Self.copy)) {
            try await exporter.export(
                ExportRequest(name: Self.copy, format: .tar), to: OwnedDescriptor(-1), for: 1
            ) { _ in }
        }
        #expect(made.withLock { $0 } == 0)
        #expect(operations.operation(on: Self.copy) == nil)
    }

    @Test func refusesANameThatIsNotInstalled() async throws {
        let debian = try DistroName("Debian")
        await #expect(throws: MawError.distributionNotInstalled(debian)) {
            try await exporter.check(debian)
        }
        await #expect(throws: MawError.distributionNotInstalled(debian)) {
            try await exporter.export(
                ExportRequest(name: debian, format: .tar), to: OwnedDescriptor(-1), for: 1
            ) { _ in }
        }
    }

    /// A removal or a second export of the name is refused, and an export holds the name
    /// until it has ended.
    @Test func holdsTheNameWhileItRuns() async throws {
        let removal = try operations.claim(Self.copy, for: .removal)
        await expectBusy(.removal, checking: exporter)
        operations.release(removal)

        machine.heldStep = "archive"
        let pipe = try DrainedPipe()
        let destination = OwnedDescriptor(dup(pipe.writer.rawValue))
        pipe.writer.close()
        let exporter = self.exporter
        let first = Task {
            try await exporter.export(
                ExportRequest(name: Self.copy, format: .tar), to: destination, for: 1
            ) { _ in }
        }
        try await eventually("the archive step") { machine.calls.contains("archive") }
        #expect(operations.operation(on: Self.copy) == .export)
        await expectBusy(.export, exporting: exporter)
        machine.release()
        #expect(try await first.value.bytes == 12)
        #expect(operations.operation(on: Self.copy) == nil)
    }

    // Swift 6.3.3's ClosureLifetimeFixup pass does not finish on holdsTheNameWhileItRuns when
    // both expectations are in its body with the Task's closure, which stalled CI's test build;
    // in functions of their own, they compile at once with 6.3.3 and 6.4.2.

    /// Expects `check` to fail because `operation` holds the name.
    private func expectBusy(_ operation: DistributionOperation, checking exporter: Exporter) async {
        await #expect(throws: MawError.distributionBusy(Self.copy, operation: operation)) {
            try await exporter.check(Self.copy)
        }
    }

    /// Expects a second `export` to fail because `operation` holds the name.
    private func expectBusy(_ operation: DistributionOperation, exporting exporter: Exporter) async
    {
        await #expect(throws: MawError.distributionBusy(Self.copy, operation: operation)) {
            try await exporter.export(
                ExportRequest(name: Self.copy, format: .tar), to: OwnedDescriptor(-1), for: 2
            ) { _ in }
        }
    }

    @Test func refusesADiskThatFailsItsCheck() async throws {
        let failing = try ExporterTests(machine: FakeExportingMachine(checkStatus: 4))
        let file = FileManager.default.temporaryDirectory.appending(
            path: "maw-x-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let destination = OwnedDescriptor(open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600))
        await #expect(
            throws: MawError.rootFileSystemCheckFailed(
                distribution: Self.copy, e2fsckStatus: 4,
                diskImage: failing.distros.store.paths.diskImage(for: Self.copy).path,
                consoleLog: MawPaths.exportLogFile(for: Self.copy, in: failing.logs).path)
        ) {
            try await failing.exporter.export(
                ExportRequest(name: Self.copy, format: .tar), to: destination, for: 1
            ) { _ in }
        }
        #expect(failing.machine.calls == ["boot", "disk disk.img", "check", "discard"])
        #expect(try Data(contentsOf: file).isEmpty)
    }

    @Test func namesAFailedStepAsTheExports() async throws {
        machine.failingStep = "mount"
        await #expect(
            throws: MawError.exportFailed(Self.copy, step: "mounting", reason: "the test failed it")
        ) {
            try await exporter.export(
                ExportRequest(name: Self.copy, format: .tar), to: OwnedDescriptor(dup(1)), for: 1
            ) { _ in }
        }
        #expect(machine.calls.last == "discard")
        #expect(operations.operation(on: Self.copy) == nil)
    }

    /// Once the archive is complete, a machine that does not stop cleanly, or a cancellation
    /// while it stops, does not fail the export: the client keeps its complete file.
    @Test(arguments: ["fails", "cancelled"])
    func keepsACompleteArchiveWhenTheLastStepFails(_ how: String) async throws {
        let pipe = try DrainedPipe()
        let destination = OwnedDescriptor(dup(pipe.writer.rawValue))
        pipe.writer.close()
        if how == "fails" {
            machine.failingStep = "finish"
        } else {
            machine.heldStep = "finish"
        }
        let exporter = self.exporter
        let task = Task {
            try await exporter.export(
                ExportRequest(name: Self.copy, format: .tar), to: destination, for: 1
            ) { _ in }
        }
        if how == "cancelled" {
            try await eventually("the last step") { machine.calls.contains("finish") }
            task.cancel()
        }
        #expect(try await task.value.bytes == 12)
        #expect(try await pipe.bytes() == Array("first second".utf8))
        #expect(machine.calls.last == "discard")
        #expect(operations.operation(on: Self.copy) == nil)
    }

    @Test func reportsAReaderThatClosedThePipe() async throws {
        ignoreSIGPIPE()
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        close(fds[0])
        await #expect(throws: MawError.exportOutputClosed(Self.copy)) {
            try await exporter.export(
                ExportRequest(name: Self.copy, format: .tar), to: OwnedDescriptor(fds[1]), for: 1
            ) { _ in }
        }
        #expect(machine.calls.contains("stopped"))
        #expect(machine.calls.last == "discard")
    }

    @Test func stopsTheMachineAtOnceWhenCancelled() async throws {
        machine.heldStep = "archive"
        let pipe = try DrainedPipe()
        let destination = OwnedDescriptor(dup(pipe.writer.rawValue))
        pipe.writer.close()
        let exporter = self.exporter
        let task = Task {
            try await exporter.export(
                ExportRequest(name: Self.copy, format: .tarGzip), to: destination, for: 1
            ) { _ in }
        }
        try await eventually("the archive step") { machine.calls.contains("archive") }
        task.cancel()
        await #expect(throws: MawError.exportCancelled(Self.copy)) { try await task.value }
        #expect(machine.calls.contains("discard"))
        #expect(!machine.calls.contains("finish"))
        #expect(destination.rawValue == -1)
        #expect(operations.operation(on: Self.copy) == nil)
        _ = try await pipe.bytes()
    }

    /// The provisioning machine's archive returns without an error when the output refuses a
    /// chunk, which it does once a cancellation has aborted it, and the machine's last step then
    /// fails because the machine was discarded. The export still fails as cancelled, so that maw
    /// removes the partial file, as integration run 7 found it did not.
    @Test(arguments: [ArchiveFormat.tar, .tarGzip])
    func reportsACancellationThatEndsTheArchiveWithoutAnError(_ format: ArchiveFormat)
        async throws
    {
        machine.heldStep = "archive"
        machine.archivesOnAfterDiscard = true
        machine.failingStep = "finish"
        let pipe = try DrainedPipe()
        let destination = OwnedDescriptor(dup(pipe.writer.rawValue))
        pipe.writer.close()
        let exporter = self.exporter
        let task = Task {
            try await exporter.export(
                ExportRequest(name: Self.copy, format: format), to: destination, for: 1
            ) { _ in }
        }
        try await eventually("the archive step") { machine.calls.contains("archive") }
        task.cancel()
        await #expect(throws: MawError.exportCancelled(Self.copy)) { try await task.value }
        #expect(machine.calls.contains("stopped"))
        #expect(machine.calls.contains("discard"))
        #expect(destination.rawValue == -1)
        #expect(operations.operation(on: Self.copy) == nil)
        _ = try await pipe.bytes()
    }
}

/// `checkExport` and `export` through XPC, and the requests that an export refuses or allows.
@Suite(.timeLimit(.minutes(2))) struct ExportServiceTests {
    static let copy = try! DistroName("Copy")

    static func daemon(_ distros: TemporaryStore, machine: FakeExportingMachine)
        -> DaemonServiceTests.Daemon
    {
        let logs = distros.home.appending(path: "logs", directoryHint: .isDirectory)
        return DaemonServiceTests.Daemon(store: distros.store) { registry, operations, log in
            Exporter(
                store: distros.store, operations: operations,
                makeMachine: { (_: DistroName) throws(MawError) -> any ExportingMachine in
                    machine
                },
                isStopped: { machine in await registry.isStopped(machine) }, logDirectory: logs,
                log: log)
        }
    }

    @Test func exportsThroughTheClient() async throws {
        let distros = try TemporaryStore()
        try distros.install("Copy")
        let daemon = Self.daemon(distros, machine: FakeExportingMachine())
        let client = try await daemon.connect()
        defer { client.close() }
        #expect(try await client.checkExport(try DistroName("copy")) == Self.copy)

        let pipe = try DrainedPipe()
        let summary = try await client.export(
            ExportRequest(name: Self.copy, format: .tar), to: pipe.writer.rawValue)
        pipe.writer.close()
        #expect(summary.bytes == 12)
        #expect(try await pipe.bytes() == Array("first second".utf8))
        #expect(daemon.lines.count(containing: "Copy: export as tar started for process") == 1)
        #expect(daemon.lines.count(containing: "Copy: exported 12 bytes as tar") == 1)
    }

    @Test func refusesARunningDistribution() async throws {
        let distros = try TemporaryStore()
        try distros.install("Copy")
        let daemon = Self.daemon(distros, machine: FakeExportingMachine())
        let user = try await daemon.connect()
        defer { user.close() }
        _ = try await user.openSession(on: .distribution(Self.copy))
        let client = try await daemon.connect()
        defer { client.close() }
        await #expect(throws: MawError.distributionRunning(Self.copy)) {
            try await client.checkExport(Self.copy)
        }
        await #expect(throws: MawError.distributionRunning(Self.copy)) {
            try await client.export(ExportRequest(name: Self.copy, format: .tar), to: STDOUT_FILENO)
        }
    }

    /// During an export, sessions, a removal, and a second export of the distribution are
    /// refused; `--terminate` and `--set-default` work as for any stopped distribution; and
    /// `cancel` stops it.
    @Test func refusesWhatWouldDisturbAnExportAndCancelsIt() async throws {
        let distros = try TemporaryStore()
        try distros.install("Copy")
        let machine = FakeExportingMachine()
        machine.heldStep = "archive"
        let daemon = Self.daemon(distros, machine: machine)
        let exporting = try await daemon.connect()
        defer { exporting.close() }
        let pipe = try DrainedPipe()
        let export = Task {
            try await exporting.export(
                ExportRequest(name: Self.copy, format: .tar), to: pipe.writer.rawValue)
        }
        try await eventually("the archive step") { machine.calls.contains("archive") }

        let other = try await daemon.connect()
        defer { other.close() }
        let busy = MawError.distributionBusy(Self.copy, operation: .export)
        await #expect(throws: busy) {
            _ = try await other.openSession(on: .distribution(Self.copy))
        }
        await #expect(throws: busy) { try await other.checkUnregister(Self.copy) }
        await #expect(throws: busy) { try await other.unregister(Self.copy) }
        await #expect(throws: busy) { try await other.checkExport(Self.copy) }
        await #expect(throws: busy) {
            try await other.export(ExportRequest(name: Self.copy, format: .tar), to: STDOUT_FILENO)
        }
        #expect(
            try await other.terminate(Self.copy)
                == TerminateSummary(wasRunning: false, endedSessions: 0))
        #expect(try await other.setDefault(Self.copy) == Self.copy)
        #expect(
            try await other.listDistributions().distributions
                == [DistributionEntry(name: Self.copy, state: .stopped)])
        #expect(daemon.factory.machines.isEmpty, "A request started the distribution's machine.")

        #expect(try await exporting.cancel())
        await #expect(throws: MawError.exportCancelled(Self.copy)) { try await export.value }
        #expect(machine.calls.contains("discard"))
        pipe.writer.close()
        _ = try await pipe.bytes()
        _ = try await other.checkExport(Self.copy)
    }

    /// A daemon without an exporter, as some unit tests wire it, says so instead of calling an
    /// installed distribution not installed.
    @Test func reportsADaemonWithoutExports() async throws {
        let distros = try TemporaryStore()
        try distros.install("Copy")
        let daemon = DaemonServiceTests.Daemon(store: distros.store)
        let client = try await daemon.connect()
        defer { client.close() }
        let expected = MawError.daemonProtocolError(
            reason: "this daemon was started without exports")
        await #expect(throws: expected) { try await client.checkExport(Self.copy) }
        await #expect(throws: expected) {
            try await client.export(ExportRequest(name: Self.copy, format: .tar), to: STDOUT_FILENO)
        }
    }

    /// The descriptor must be open for writing and must not be a terminal.
    @Test func checksTheArchivesDescriptor() throws {
        let request = DaemonRequest.export(ExportRequest(name: Self.copy, format: .tar))
        #expect(
            throws: MawError.daemonProtocolError(reason: "the export request carries no descriptor")
        ) {
            _ = try DaemonService<TestClock>.archiveDestination(
                in: try InterfaceCoding.encode(request))
        }

        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        #expect(
            throws: MawError.daemonProtocolError(
                reason: "the export request's descriptor is not open for writing")
        ) {
            _ = try DaemonService<TestClock>.archiveDestination(
                in: try InterfaceCoding.encode(request, descriptor: fds[0]))
        }
        let writable = try DaemonService<TestClock>.archiveDestination(
            in: try InterfaceCoding.encode(request, descriptor: fds[1]))
        writable.close()

        let primary = posix_openpt(O_RDWR | O_NOCTTY)
        try #require(primary >= 0)
        defer { close(primary) }
        try #require(grantpt(primary) == 0 && unlockpt(primary) == 0)
        let secondary = open(String(cString: ptsname(primary)), O_RDWR | O_NOCTTY)
        try #require(secondary >= 0)
        defer { close(secondary) }
        #expect(throws: MawError.exportToTerminal) {
            _ = try DaemonService<TestClock>.archiveDestination(
                in: try InterfaceCoding.encode(request, descriptor: secondary))
        }
    }
}
