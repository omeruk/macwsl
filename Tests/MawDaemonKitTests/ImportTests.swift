import Darwin
import Foundation
import MawClient
import MawCore
import MawProtocol
import MawXPC
import Testing
import os

@testable import MawDaemonKit

/// An importing machine that reports an inspection and files that the test chooses, and fails,
/// holds, or finds a path it cannot resolve as the test says.
final class FakeImportingMachine: ImportingMachine, @unchecked Sendable {
    struct Configuration: Equatable {
        var hostname: String
        var defaultUser: DefaultUserChoice
        var mawConf: String?
    }

    private struct State {
        var calls: [String] = []
        var failingStep: String?
        var heldStep: String?
        var configuration: Configuration?
        var unresolvable: (path: String, reason: String)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let released = OneTimeSignal()
    let discarded = OneTimeSignal()
    /// The inspection's output, and the files by resolved path.
    let inspection: String
    let files: [String: String]

    /// A root with `/sbin/init` leading to systemd, and the files given.
    static func inspection(
        passwd: Bool = true, usr: Bool = true, initProgram: String = "/usr/lib/systemd/systemd",
        mawConf: Bool = false, wslConf: Bool = false
    ) -> String {
        """
        entry\tetc/
        entry\tusr/
        entries\t2
        path\t/etc/passwd\t\(passwd ? "file" : "missing")\tplain\t/etc/passwd
        path\t/usr\t\(usr ? "directory" : "missing")\tplain\t/usr
        path\t/sbin/init\texecutable\tlink\t\(initProgram)
        path\t/etc/maw.conf\t\(mawConf ? "file" : "missing")\tplain\t/etc/maw.conf
        path\t/etc/wsl.conf\t\(wslConf ? "file" : "missing")\tplain\t/etc/wsl.conf

        """
    }

    static let passwd = """
        root:x:0:0:root:/root:/bin/bash
        ayse:x:1000:1000::/home/ayse:/bin/bash
        omer:x:1001:1001::/home/omer:/bin/bash

        """

    init(inspection: String = FakeImportingMachine.inspection(), files: [String: String] = [:]) {
        self.inspection = inspection
        self.files = ["/etc/passwd": Self.passwd].merging(files) { $1 }
    }

    var calls: [String] { state.withLock { $0.calls } }
    var configuration: Configuration? { state.withLock { $0.configuration } }
    var failingStep: String? {
        get { state.withLock { $0.failingStep } }
        set { state.withLock { $0.failingStep = newValue } }
    }
    /// A step that waits until `release()` or `discard()`.
    var heldStep: String? {
        get { state.withLock { $0.heldStep } }
        set { state.withLock { $0.heldStep = newValue } }
    }
    var unresolvable: (path: String, reason: String)? {
        get { state.withLock { $0.unresolvable } }
        set { state.withLock { $0.unresolvable = newValue } }
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
    }

    func format() async throws(MawError) {
        try await step("format")
    }

    /// Whether the archive is not a tar archive once decompressed.
    var isNotATarArchive = false

    func extract(archive source: OwnedDescriptor) async throws(MawError) -> ArchiveExtraction {
        source.close()
        try await step("extract")
        return isNotATarArchive ? .notATarArchive : .extracted(bytes: 1_234)
    }

    func inspect() async throws(MawError) -> String {
        try await step("inspect")
        return inspection
    }

    func readFile(_ path: String) async throws(MawError) -> String {
        state.withLock { $0.calls.append("read \(path)") }
        guard let text = files[path] else {
            throw .provisioningFailed(step: "reading \(path)", reason: "no such file")
        }
        return text
    }

    func configureImport(hostname: String, defaultUser: DefaultUserChoice, mawConf: String?)
        async throws(MawError) -> (path: String, reason: String)?
    {
        try await step("configure")
        state.withLock {
            $0.configuration = Configuration(
                hostname: hostname, defaultUser: defaultUser, mawConf: mawConf)
        }
        return unresolvable
    }

    func finish() async throws(MawError) {
        try await step("finish")
    }

    /// Whether `discard()` waits until `release()`, as a machine's forced stop takes time.
    var holdsDiscard = false
    private let discardReleased = OneTimeSignal()

    func releaseDiscard() {
        discardReleased.fire()
    }

    func discard() async {
        state.withLock { $0.calls.append("discard") }
        discarded.fire()
        released.fire()
        if holdsDiscard {
            await discardReleased.wait()
        }
    }
}

/// The importer against a fake importing machine and a store in a temporary directory.
///
/// The tasks that run an import are untyped: Swift 6.4.2's IR generation crashed on a task's
/// closure that calls `import` with `throws(MawError)`.
@Suite struct ImporterTests {
    static let copy = try! DistroName("Copy")

    let distros: TemporaryStore
    let operations = DistributionOperations()
    let machine: FakeImportingMachine
    let made = OSAllocatedUnfairLock(initialState: 0)
    let started = OSAllocatedUnfairLock(initialState: [MachineID]())
    let events = OSAllocatedUnfairLock(initialState: [String]())
    let startError = OSAllocatedUnfairLock(initialState: MawError?.none)
    let available = OSAllocatedUnfairLock(initialState: UInt64(1) << 40)
    let logs: URL

    init() throws {
        try self.init(machine: FakeImportingMachine())
    }

    init(machine: FakeImportingMachine) throws {
        distros = try TemporaryStore()
        self.machine = machine
        logs = distros.home.appending(path: "logs", directoryHint: .isDirectory)
    }

    var importer: Importer {
        let machine = self.machine
        let made = self.made
        let started = self.started
        let events = self.events
        let startError = self.startError
        let available = self.available
        return Importer(
            store: distros.store, operations: operations,
            makeMachine: { (_: DistroName) throws(MawError) -> any ImportingMachine in
                made.withLock { $0 += 1 }
                return machine
            },
            freeSpace: { _ in (available.withLock { $0 }, "Macintosh HD") },
            startMachine: { machine throws(MawError) in
                events.withLock { $0.append("start") }
                started.withLock { $0.append(machine) }
                if let error = startError.withLock({ $0 }) {
                    throw error
                }
            },
            makeMACAddress: { "02:00:00:00:00:42" },
            registered: { events.withLock { $0.append("registered") } }, logDirectory: logs)
    }

    func request(
        _ name: String = "Copy", user: String? = nil, archive: String = "/Users/ayse/ubuntu.tar"
    ) throws -> ImportRequest {
        ImportRequest(name: try DistroName(name), user: user, archive: archive)
    }

    /// A descriptor of a file in the store's temporary directory.
    func source(_ bytes: [UInt8] = Array(repeating: 0, count: 512)) throws -> OwnedDescriptor {
        let file = distros.home.appending(path: "archive-\(UUID().uuidString)")
        try Data(bytes).write(to: file)
        let descriptor = open(file.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        try #require(descriptor >= 0)
        return OwnedDescriptor(descriptor)
    }

    func run(_ request: ImportRequest, progress: OSAllocatedUnfairLock<[InstallProgress]>? = nil)
        async throws(MawError) -> ImportSummary
    {
        let source: OwnedDescriptor
        do {
            source = try self.source()
        } catch {
            throw .fileNotAccessible(path: "the test's archive", reason: "\(error)")
        }
        return try await importer.import(request, from: source, for: 42) { event in
            progress?.withLock { $0.append(event) }
        }
    }

    /// Nothing of a failed or cancelled import is left: no distribution, no staging
    /// directory, and no claim on the name.
    func expectNothingLeft(_ name: DistroName = ImporterTests.copy) throws {
        #expect(!distros.store.isInstalled(name))
        #expect(distros.store.leftoverEntry(for: name) == nil)
        let staging = distros.store.stagingDirectory(for: name).deletingLastPathComponent()
        let left =
            (try? FileManager.default.contentsOfDirectory(
                atPath: staging.path(percentEncoded: false))) ?? []
        #expect(left.isEmpty, "\(left)")
        #expect(operations.operation(on: name) == nil)
        #expect(started.withLock { $0 }.isEmpty)
    }

    @Test func importsThroughEachStepInOrder() async throws {
        let machine = FakeImportingMachine(
            inspection: FakeImportingMachine.inspection(mawConf: true),
            files: ["/etc/maw.conf": "[user]\ndefault = ayse\n"])
        let tests = try ImporterTests(machine: machine)
        let progress = OSAllocatedUnfairLock(initialState: [InstallProgress]())
        let summary = try await tests.run(try tests.request(), progress: progress)

        #expect(summary.name == Self.copy)
        #expect(summary.defaultUser == "ayse")
        #expect(summary.defaultUserSource == .mawConf)
        #expect(summary.isDefault)
        #expect(summary.extractedBytes == 1_234)
        #expect(summary.firstStartFailure == nil)
        #expect(
            machine.calls == [
                "boot", "format", "extract", "inspect", "read /etc/passwd", "read /etc/maw.conf",
                "configure", "finish",
            ])
        // maw.conf already names the user, so it is not written again.
        #expect(
            machine.configuration
                == .init(
                    hostname: "copy", defaultUser: .init(user: "ayse", source: .mawConf),
                    mawConf: nil))
        let steps = progress.withLock { $0 }.compactMap { event -> InstallStep? in
            if case .started(let step) = event { return step }
            return nil
        }
        #expect(steps == InstallStep.import)
        #expect(tests.events.withLock { $0 } == ["registered", "start"])
        #expect(tests.started.withLock { $0 } == [.distribution(Self.copy)])

        let metadata = try #require(try tests.distros.store.metadata(for: Self.copy))
        #expect(metadata.importedFrom == .init(archive: "/Users/ayse/ubuntu.tar"))
        #expect(metadata.catalogEntry == nil)
        #expect(metadata.defaultUser == "ayse")
        #expect(metadata.macAddress == "02:00:00:00:00:42")
        #expect(metadata.schemaVersion == 2)
        #expect(tests.distros.store.defaultDistribution() == Self.copy)
        #expect(tests.operations.operation(on: Self.copy) == nil)
    }

    /// The choice from wsl.conf is written into maw.conf, which the archive did not have.
    @Test func writesTheChoiceFromWslConfIntoMawConf() async throws {
        let machine = FakeImportingMachine(
            inspection: FakeImportingMachine.inspection(wslConf: true),
            files: ["/etc/wsl.conf": "[boot]\nsystemd=true\n[user]\ndefault=omer\n"])
        let tests = try ImporterTests(machine: machine)
        let summary = try await tests.run(try tests.request())
        #expect(summary.defaultUser == "omer")
        #expect(summary.defaultUserSource == .wslConf)
        #expect(machine.configuration?.mawConf == "[user]\ndefault = omer\n")
        #expect(machine.configuration?.defaultUser.lingers == true)
    }

    /// Without a user named anywhere, sessions run as root, which is written into maw.conf.
    @Test func fallsBackToRoot() async throws {
        let summary = try await run(try request())
        #expect(summary.defaultUser == "root")
        #expect(summary.defaultUserSource == .fallback)
        #expect(machine.configuration?.mawConf == "[user]\ndefault = root\n")
        #expect(machine.configuration?.defaultUser.lingers == false)
    }

    @Test func takesTheUserOfTheOption() async throws {
        let summary = try await run(try request(user: "omer"))
        #expect(summary.defaultUser == "omer")
        #expect(summary.defaultUserSource == .option)
    }

    /// A user that the archive does not have fails the import before the registration.
    @Test func refusesAUserThatTheArchiveDoesNotHave() async throws {
        await #expect(throws: MawError.userNotFound("zeynep", distribution: "the archive")) {
            try await run(try request(user: "zeynep"))
        }
        #expect(machine.calls.contains("discard"))
        #expect(!machine.calls.contains("configure"))
        try expectNothingLeft()
    }

    @Test func refusesAnArchiveWithoutARootFileSystem() async throws {
        let tests = try ImporterTests(
            machine: FakeImportingMachine(
                inspection: FakeImportingMachine.inspection(passwd: false, usr: true)))
        await #expect(
            throws: MawError.importNotARootFileSystem(
                Self.copy, found: "its top level holds etc/, usr/,\nbut no etc/passwd")
        ) {
            try await tests.run(try tests.request())
        }
        #expect(tests.machine.calls.last == "discard")
        try tests.expectNothingLeft()
    }

    @Test func refusesAnInitThatIsNotSystemd() async throws {
        let tests = try ImporterTests(
            machine: FakeImportingMachine(
                inspection: FakeImportingMachine.inspection(initProgram: "/bin/busybox")))
        await #expect(
            throws: MawError.importInitNotSystemd(
                Self.copy, reason: "/sbin/init leads to /bin/busybox")
        ) {
            try await tests.run(try tests.request())
        }
        try tests.expectNothingLeft()
    }

    /// An archive that is not a tar archive once decompressed is refused at the extraction.
    @Test func refusesAnArchiveThatIsNotTar() async throws {
        machine.isNotATarArchive = true
        await #expect(throws: MawError.importNotATarArchive(Self.copy)) {
            try await run(try request())
        }
        #expect(!machine.calls.contains("inspect"))
        #expect(machine.calls.last == "discard")
        try expectNothingLeft()
    }

    @Test func refusesAPathThatTheConfigurationCannotResolve() async throws {
        machine.unresolvable = ("/etc/netplan/50-maw.yaml", "it has more than 40 links, or a loop")
        await #expect(
            throws: MawError.importPathNotResolvable(
                Self.copy, path: "/etc/netplan/50-maw.yaml",
                reason: "it has more than 40 links, or a loop")
        ) {
            try await run(try request())
        }
        #expect(machine.calls.last == "discard")
        try expectNothingLeft()
    }

    @Test(arguments: ["boot", "format", "extract", "inspect", "configure", "finish"])
    func namesTheStepThatFailed(_ step: String) async throws {
        machine.failingStep = step
        await #expect(
            throws: MawError.importFailed(
                Self.copy, step: "\(step)ing", reason: "the test failed it")
        ) {
            try await run(try request())
        }
        #expect(machine.calls.last == "discard")
        try expectNothingLeft()
    }

    /// A cancellation at each step stops the machine and removes everything.
    @Test(arguments: ["boot", "format", "extract", "inspect", "configure", "finish"])
    func removesEverythingWhenCancelled(_ step: String) async throws {
        machine.heldStep = step
        let importer = self.importer
        let source = try self.source()
        let request = try self.request()
        let running = Task { () async throws -> ImportSummary in
            try await importer.import(request, from: source, for: 42) { _ in }
        }
        let machine = self.machine
        try await eventually("the step \(step)") { machine.calls.contains(step) }
        running.cancel()
        await #expect(throws: MawError.importCancelled(Self.copy)) { try await running.value }
        #expect(machine.calls.contains("discard"))
        #expect(source.rawValue == -1, "The descriptor was not closed.")
        try expectNothingLeft()
    }

    /// A refusal keeps its reason when a cancellation arrives while the machine is stopped
    /// after it.
    @Test func keepsTheReasonOfARefusalThatACancellationFollows() async throws {
        let tests = try ImporterTests(
            machine: FakeImportingMachine(
                inspection: FakeImportingMachine.inspection(initProgram: "/bin/busybox")))
        tests.machine.holdsDiscard = true
        let importer = tests.importer
        let source = try tests.source()
        let request = try tests.request()
        let running = Task { () async throws -> ImportSummary in
            try await importer.import(request, from: source, for: 42) { _ in }
        }
        await tests.machine.discarded.wait()
        running.cancel()
        tests.machine.releaseDiscard()
        await #expect(
            throws: MawError.importInitNotSystemd(
                Self.copy, reason: "/sbin/init leads to /bin/busybox")
        ) {
            try await running.value
        }
        try tests.expectNothingLeft()
    }

    /// The refusals that come before anything is created.
    @Test func refusesBeforeItCreatesAnything() async throws {
        try distros.install("Ubuntu-24.04")
        await #expect(throws: MawError.distributionAlreadyInstalled(try DistroName("Ubuntu-24.04")))
        {
            try await run(try request("Ubuntu-24.04"))
        }
        await #expect(throws: MawError.self) { try await run(try request("mawd")) }
        await #expect(throws: MawError.self) { try await run(try request(user: "Upper")) }
        await #expect(throws: MawError.self) { try await run(try request(archive: "relative.tar")) }

        let claim = try operations.claim(Self.copy, for: .install)
        // The error names the spelling that was asked for, as an installation's does.
        await #expect(
            throws: MawError.installationInProgress(try DistroName("COPY"), by: .install)
        ) {
            try await run(try request("COPY"))
        }
        operations.release(claim)

        try FileManager.default.createDirectory(
            at: distros.store.paths.distrosDirectory.appending(path: "copy"),
            withIntermediateDirectories: true)
        await #expect(throws: MawError.self) { try await run(try request()) }
        try FileManager.default.removeItem(
            at: distros.store.paths.distrosDirectory.appending(path: "copy"))

        available.withLock { $0 = 1 << 20 }
        await #expect(
            throws: MawError.insufficientDiskSpace(
                required: 6 * 512 + (1 << 30), available: 1 << 20, volume: "Macintosh HD",
                for: .import)
        ) {
            try await run(try request())
        }
        #expect(made.withLock { $0 } == 0)
        try expectNothingLeft()
    }

    /// While an import holds a name, an installation or a second import of it fails, in any
    /// case of the letters.
    @Test func holdsTheNameWhileItRuns() async throws {
        machine.heldStep = "extract"
        let importer = self.importer
        let source = try self.source()
        let request = try self.request()
        let running = Task { () async throws -> ImportSummary in
            try await importer.import(request, from: source, for: 42) { _ in }
        }
        let machine = self.machine
        try await eventually("the extraction") { machine.calls.contains("extract") }
        #expect(throws: MawError.installationInProgress(try DistroName("copy"), by: .import)) {
            try operations.check(try DistroName("copy"), for: .install)
        }
        await expectASecondImportToFail()
        machine.release()
        _ = try await running.value
    }

    private func expectASecondImportToFail() async {
        await #expect(
            throws: MawError.installationInProgress(try! DistroName("COPY"), by: .import)
        ) {
            try await run(try request("COPY"))
        }
    }

    /// A first start that fails leaves the distribution installed, and the reply names the
    /// console log.
    @Test func reportsAFailedFirstStart() async throws {
        startError.withLock { $0 = .guestAgentUnavailable(reason: "no answer within 30 seconds") }
        let summary = try await run(try request())
        let log = MawPaths.consoleLogFile(forMachineNamed: "Copy", in: logs)
            .path(percentEncoded: false)
        #expect(
            summary.firstStartFailure
                == .importStartFailed(
                    Self.copy, consoleLog: log,
                    reason: MawError.guestAgentUnavailable(reason: "no answer within 30 seconds")
                        .description))
        #expect(distros.store.isInstalled(Self.copy))
        #expect(operations.operation(on: Self.copy) == nil)
    }

    @Test func doesNotBecomeTheDefaultBesideAnotherDistribution() async throws {
        try distros.install("Ubuntu-24.04")
        let summary = try await run(try request())
        #expect(!summary.isDefault)
        // Nothing is recorded; the first installed distribution by name stays the default.
        #expect(try distros.recordedDefault() == nil)
    }

    // MARK: The archive's size

    @Test func readsTheSizeAndCompressionOfARegularFileFromItsOffset() throws {
        var tar = [UInt8](repeating: 0, count: 1_024)
        tar.replaceSubrange(257..<262, with: Array("ustar".utf8))
        let plain = try source(tar)
        #expect(Importer.archiveSize(of: plain.rawValue).size == 1_024)
        #expect(Importer.archiveSize(of: plain.rawValue).compression == .none)

        let gzip = try source([0x1F, 0x8B] + Array(repeating: 0, count: 98))
        #expect(Importer.archiveSize(of: gzip.rawValue).compression == .gzip)

        // From the current offset, which the check leaves where it was.
        let shifted = try source(Array(repeating: 7, count: 100) + tar)
        #expect(lseek(shifted.rawValue, 100, SEEK_SET) == 100)
        #expect(Importer.archiveSize(of: shifted.rawValue).size == 1_024)
        #expect(Importer.archiveSize(of: shifted.rawValue).compression == .none)
        #expect(lseek(shifted.rawValue, 0, SEEK_CUR) == 100)
    }

    @Test func hasNoSizeForAPipe() throws {
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        let archive = Importer.archiveSize(of: fds[0])
        #expect(archive.size == nil)
        #expect(archive.compression == .other)
    }

    @Test func escapesControlCharactersForTheLog() {
        #expect(Importer.loggable("/Users/a/b\nc.tar") == "/Users/a/b\\nc.tar")
        #expect(Importer.loggable("standard input") == "standard input")
    }
}

/// `maw --import` through the daemon's interface.
@Suite struct ImportTests {
    static let copy = try! DistroName("Copy")

    /// A daemon without an importer, as some unit tests wire it, says so.
    @Test func reportsADaemonWithoutImports() async throws {
        let distros = try TemporaryStore()
        let daemon = DaemonServiceTests.Daemon(store: distros.store)
        let client = try await daemon.connect()
        defer { client.close() }
        await #expect(
            throws: MawError.daemonProtocolError(reason: "this daemon was started without imports")
        ) {
            try await client.import(
                ImportRequest(name: Self.copy, user: nil, archive: "standard input"),
                from: STDIN_FILENO)
        }
    }

    /// The descriptor must be present and open for reading.
    @Test func checksTheArchivesDescriptor() throws {
        let request = DaemonRequest.import(
            ImportRequest(name: Self.copy, user: nil, archive: "standard input"))
        #expect(
            throws: MawError.daemonProtocolError(reason: "the import request carries no descriptor")
        ) {
            _ = try DaemonService<TestClock>.archiveSource(in: try InterfaceCoding.encode(request))
        }
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        #expect(
            throws: MawError.daemonProtocolError(
                reason: "the import request's descriptor is not open for reading")
        ) {
            _ = try DaemonService<TestClock>.archiveSource(
                in: try InterfaceCoding.encode(request, descriptor: fds[1]))
        }
        let source = try DaemonService<TestClock>.archiveSource(
            in: try InterfaceCoding.encode(request, descriptor: fds[0]))
        #expect(source.rawValue >= 0)
        source.close()
    }

    /// An import through the daemon replies with its summary, and a cancellation from its
    /// client removes everything.
    @Test func importsAndCancelsThroughTheDaemon() async throws {
        let distros = try TemporaryStore()
        let machine = FakeImportingMachine()
        machine.heldStep = "extract"
        let daemon = DaemonServiceTests.Daemon(
            store: distros.store,
            makeImporter: { operations, log in
                Importer(
                    store: distros.store, operations: operations,
                    makeMachine: { (_: DistroName) throws(MawError) -> any ImportingMachine in
                        machine
                    },
                    freeSpace: { _ in (1 << 40, "Macintosh HD") },
                    startMachine: { _ throws(MawError) in },
                    makeMACAddress: { "02:00:00:00:00:42" },
                    logDirectory: distros.home, log: log)
            })
        let importing = try await daemon.connect()
        defer { importing.close() }
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        let reader = fds[0]
        let running = Task { () async throws -> ImportSummary in
            try await importing.import(
                ImportRequest(name: Self.copy, user: nil, archive: "standard input"), from: reader)
        }
        try await eventually("the extraction") { machine.calls.contains("extract") }
        #expect(try await importing.cancel())
        await #expect(throws: MawError.importCancelled(Self.copy)) { try await running.value }
        #expect(machine.calls.contains("discard"))
        #expect(!distros.store.isInstalled(Self.copy))
        #expect(daemon.operations.operation(on: Self.copy) == nil)
    }
}
