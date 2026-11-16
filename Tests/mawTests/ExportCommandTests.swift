import Darwin
import Foundation
import MawClient
import MawCore
import MawXPC
import Testing
import os

@testable import maw

/// `maw --export`'s file and its cancellation, with a fake daemon that writes to the descriptor
/// it receives.
@Suite struct ExportCommandTests {
    final class FakeDaemon: ExportDaemon, @unchecked Sendable {
        let events: AsyncStream<DaemonClient.Event>
        private let continuation: AsyncStream<DaemonClient.Event>.Continuation
        private let state = OSAllocatedUnfairLock(
            initialState: (
                requests: [String](), cancelled: false,
                waiter: CheckedContinuation<Void, Never>?.none
            ))
        var checkError: MawError?
        var exportError: MawError?
        var holdsUntilCancelled = false
        /// With `holdsUntilCancelled`: the archive was complete, so the export succeeds although
        /// the cancellation reached it, as while its machine stops.
        var succeedsWhenCancelled = false
        /// Runs while the export writes, after the first bytes.
        var duringExport: (@Sendable () -> Void)?

        init() {
            (events, continuation) = AsyncStream.makeStream(of: DaemonClient.Event.self)
        }

        var requests: [String] { state.withLock { $0.requests } }

        func checkExport(_ name: DistroName) async throws(MawError) -> DistroName {
            state.withLock { $0.requests.append("checkExport \(name)") }
            if let checkError { throw checkError }
            return try! DistroName("Copy")
        }

        func export(_ request: ExportRequest, to descriptor: Int32) async throws(MawError)
            -> ExportSummary
        {
            state.withLock {
                $0.requests.append("export \(request.name) \(request.format.rawValue)")
            }
            continuation.yield(.installProgress(.started(.archive)))
            _ = Array("archive".utf8).withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress, $0.count)
            }
            duringExport?()
            if holdsUntilCancelled {
                await withCheckedContinuation { waiter in
                    let resumeNow = state.withLock { state -> Bool in
                        if state.cancelled { return true }
                        state.waiter = waiter
                        return false
                    }
                    if resumeNow { waiter.resume() }
                }
                if !succeedsWhenCancelled {
                    throw .exportCancelled(request.name)
                }
            }
            if let exportError { throw exportError }
            continuation.yield(.installProgress(.finished(.archive, milliseconds: 5)))
            // As from the daemon, the events go before the reply; here they have time to arrive.
            try? await Task.sleep(for: .milliseconds(100))
            return ExportSummary(
                name: request.name, format: request.format, bytes: 7, milliseconds: 9)
        }

        func cancel() async throws(MawError) -> Bool {
            let waiter = state.withLock { state in
                state.requests.append("cancel")
                state.cancelled = true
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
            return true
        }

        func close() {
            continuation.finish()
        }
    }

    let directory: URL
    let errors: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "maw-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        errors = directory.appending(path: "stderr.txt")
        try Data().write(to: errors)
    }

    func path(_ name: String) -> String {
        directory.appending(path: name).path(percentEncoded: false)
    }

    func command(
        _ daemon: FakeDaemon, file: String, format: ArchiveFormat = .tar,
        outputIsTerminal: Bool = false
    ) -> ExportCommand {
        var command = ExportCommand(name: try! DistroName("copy"), file: file, format: format)
        command.connect = { () async throws(MawError) -> any ExportDaemon in daemon }
        command.outputIsTerminal = outputIsTerminal
        command.outputIsWritable = true
        command.errorIsTerminal = false
        command.output = OutputQueue(
            standardOutput: open("/dev/null", O_WRONLY), standardError: open(errors.path, O_WRONLY))
        return command
    }

    var standardError: String {
        (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
    }

    /// No signal arrives.
    var noSignals: AsyncStream<Int32> {
        AsyncStream { _ in }
    }

    @Test func writesTheArchiveToANewFileOfMode600() async throws {
        let daemon = FakeDaemon()
        let file = path("ubuntu.tar")
        #expect(try await command(daemon, file: file).run(signals: noSignals) == 0)
        #expect(daemon.requests == ["checkExport copy", "export Copy tar"])
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "archive")
        var status = stat()
        #expect(stat(file, &status) == 0)
        #expect(status.st_mode & 0o777 == 0o600)
        #expect(standardError.contains("Writing the archive"))
        #expect(standardError.hasSuffix("Copy was exported to \(file): 7 bytes.\n"))
    }

    @Test func namesStandardOutputInItsLastLine() {
        #expect(
            ExportCommand.summary(
                ExportSummary(
                    name: try! DistroName("Ubuntu-24.04"), format: .tar, bytes: 1_300_000_000,
                    milliseconds: 1),
                file: "-") == "Ubuntu-24.04 was exported to standard output: 1.3 GB.")
    }

    /// An existing file, or a link in its place, dangling or not, is never replaced, and no
    /// export starts.
    @Test(arguments: ["file", "dangling link", "link"])
    func neverReplacesAnEntry(_ kind: String) async throws {
        let file = path("ubuntu.tar")
        switch kind {
        case "file":
            try Data("mine".utf8).write(to: URL(filePath: file))
        case "dangling link":
            try FileManager.default.createSymbolicLink(
                atPath: file, withDestinationPath: path("nowhere"))
        default:
            try Data("mine".utf8).write(to: URL(filePath: path("target")))
            try FileManager.default.createSymbolicLink(
                atPath: file, withDestinationPath: path("target"))
        }
        let daemon = FakeDaemon()
        await #expect(throws: MawError.exportFileExists(path: file)) {
            try await command(daemon, file: file).run(signals: noSignals)
        }
        #expect(daemon.requests == ["checkExport copy"])
        #expect(!FileManager.default.fileExists(atPath: path("nowhere")))
        if kind != "dangling link" {
            #expect(try String(contentsOfFile: file, encoding: .utf8) == "mine")
        }
    }

    /// A refused export, such as one of a running distribution, creates no file.
    @Test func createsNoFileWhenTheDaemonRefuses() async throws {
        let daemon = FakeDaemon()
        let error = MawError.distributionRunning(try DistroName("Copy"))
        daemon.checkError = error
        let file = path("ubuntu.tar")
        await #expect(throws: error) {
            try await command(daemon, file: file).run(signals: noSignals)
        }
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test func removesTheFileOfAFailedExport() async throws {
        let daemon = FakeDaemon()
        let error = MawError.exportOutputClosed(try DistroName("Copy"))
        daemon.exportError = error
        let file = path("ubuntu.tar.gz")
        await #expect(throws: error) {
            try await command(daemon, file: file, format: .tarGzip).run(signals: noSignals)
        }
        #expect(daemon.requests == ["checkExport copy", "export Copy tar.gz"])
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    /// A file that replaced maw's own at its path while the export ran is not maw's to remove.
    @Test func removesOnlyTheFileItCreated() async throws {
        let daemon = FakeDaemon()
        daemon.exportError = .exportFailed(try DistroName("Copy"), step: "x", reason: "y")
        let file = path("ubuntu.tar")
        let moved = path("moved.tar")
        daemon.duringExport = {
            try? FileManager.default.moveItem(atPath: file, toPath: moved)
            try? Data("someone else's".utf8).write(to: URL(filePath: file))
        }
        await #expect(throws: MawError.self) {
            try await command(daemon, file: file).run(signals: noSignals)
        }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "someone else's")
    }

    /// `-` with standard output on a terminal is refused before the daemon is asked.
    @Test func refusesATerminalAsStandardOutput() async throws {
        let connected = OSAllocatedUnfairLock(initialState: false)
        var command = command(FakeDaemon(), file: "-", outputIsTerminal: true)
        command.connect = { () async throws(MawError) -> any ExportDaemon in
            connected.withLock { $0 = true }
            return FakeDaemon()
        }
        await #expect(throws: MawError.exportToTerminal) {
            try await command.run(signals: noSignals)
        }
        #expect(!connected.withLock { $0 })
        // A file name on a terminal is fine.
        #expect(
            try await self.command(FakeDaemon(), file: path("u.tar"), outputIsTerminal: true)
                .run(signals: noSignals) == 0)
    }

    /// `-` with standard output closed or open only for reading is refused before the daemon
    /// is asked, rather than as the daemon's protocol error.
    @Test func refusesAStandardOutputThatIsNotWritable() async throws {
        let connected = OSAllocatedUnfairLock(initialState: false)
        var command = command(FakeDaemon(), file: "-")
        command.outputIsWritable = false
        command.connect = { () async throws(MawError) -> any ExportDaemon in
            connected.withLock { $0 = true }
            return FakeDaemon()
        }
        await #expect(throws: MawError.exportOutputNotWritable) {
            try await command.run(signals: noSignals)
        }
        #expect(!connected.withLock { $0 })
    }

    /// Ctrl-C asks the daemon to cancel, removes the file, and exits as a signal does.
    @Test func cancelsOnASignalAndRemovesTheFile() async throws {
        let daemon = FakeDaemon()
        daemon.holdsUntilCancelled = true
        let file = path("ubuntu.tar")
        let (signals, sender) = AsyncStream.makeStream(of: Int32.self)
        let run = Task { try await command(daemon, file: file).run(signals: signals) }
        try await waitFor { daemon.requests.contains("export Copy tar") }
        sender.yield(SIGINT)
        #expect(try await run.value == 128 + SIGINT)
        #expect(daemon.requests.last == "cancel")
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(standardError.contains("Cancelling the export..."))
        #expect(standardError.contains("maw: The export of Copy was cancelled."))
    }

    /// A cancellation that reaches an export whose archive is already complete keeps the file:
    /// the export's own reply is a success.
    @Test func keepsTheFileWhenTheExportSucceedsDespiteTheSignal() async throws {
        let daemon = FakeDaemon()
        daemon.holdsUntilCancelled = true
        daemon.succeedsWhenCancelled = true
        let file = path("ubuntu.tar")
        let (signals, sender) = AsyncStream.makeStream(of: Int32.self)
        let run = Task { try await command(daemon, file: file).run(signals: signals) }
        try await waitFor { daemon.requests.contains("export Copy tar") }
        sender.yield(SIGINT)
        #expect(try await run.value == 0)
        #expect(daemon.requests.last == "cancel")
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "archive")
        #expect(standardError.hasSuffix("Copy was exported to \(file): 7 bytes.\n"))
    }

    /// Waits until `condition` holds, for at most 5 seconds.
    func waitFor(_ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "the condition did not become true")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// The export's step labels line up, and none is wider than an installation's.
    @Test func labelsTheExportsSteps() throws {
        let text = InstallProgressText(
            name: try DistroName("Copy"), displayName: "", operation: .export)
        #expect(
            text.steps.map { text.label(for: $0) } == [
                "Starting the virtual machine", "Checking the file system", "Writing the archive",
                "Stopping the virtual machine",
            ])
        #expect(Set(text.steps.map { text.padded($0).count }) == [30])
    }
}
