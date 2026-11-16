import Darwin
import Foundation
import MawClient
import MawCore
import MawXPC
import Testing
import os

@testable import maw

/// `maw --import`'s archive, its result, and its cancellation, with a fake daemon that reads
/// the descriptor it receives.
@Suite struct ImportCommandTests {
    final class FakeDaemon: ImportDaemon, @unchecked Sendable {
        let events: AsyncStream<DaemonClient.Event>
        private let continuation: AsyncStream<DaemonClient.Event>.Continuation
        private struct State {
            var requests: [String] = []
            var received: [ImportRequest] = []
            var readBytes: [UInt8] = []
            var cancelled = false
            var waiter: CheckedContinuation<Void, Never>?
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        var importError: MawError?
        var holdsUntilCancelled = false
        /// With `holdsUntilCancelled`: the distribution was registered, so the import succeeds
        /// although the cancellation reached it.
        var succeedsWhenCancelled = false
        /// With `holdsUntilCancelled`: the import failed on its own before the cancellation
        /// reached it, with this error.
        var failsWhenCancelled: MawError?
        /// Whether `cancel` never answers, as while the first start runs.
        var cancelHangs = false
        var summary = ImportSummary(
            name: try! DistroName("Copy"), defaultUser: "ayse", defaultUserSource: .mawConf,
            isDefault: false, extractedBytes: 7, milliseconds: 9, firstStartFailure: nil)

        init() {
            (events, continuation) = AsyncStream.makeStream(of: DaemonClient.Event.self)
        }

        var requests: [String] { state.withLock { $0.requests } }
        var received: [ImportRequest] { state.withLock { $0.received } }
        var readBytes: [UInt8] { state.withLock { $0.readBytes } }

        func `import`(_ request: ImportRequest, from descriptor: Int32) async throws(MawError)
            -> ImportSummary
        {
            var buffer = [UInt8](repeating: 0, count: 64)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            let read = Array(buffer.prefix(max(0, count)))
            state.withLock {
                $0.requests.append("import \(request.name)")
                $0.received.append(request)
                $0.readBytes = read
            }
            continuation.yield(.installProgress(.started(.extract)))
            if holdsUntilCancelled {
                await withCheckedContinuation { waiter in
                    let resumeNow = state.withLock { state -> Bool in
                        if state.cancelled { return true }
                        state.waiter = waiter
                        return false
                    }
                    if resumeNow { waiter.resume() }
                }
                if let failsWhenCancelled {
                    throw failsWhenCancelled
                }
                if !succeedsWhenCancelled {
                    throw .importCancelled(request.name)
                }
            }
            if let importError { throw importError }
            continuation.yield(.installProgress(.finished(.extract, milliseconds: 5)))
            try? await Task.sleep(for: .milliseconds(100))
            return summary
        }

        func cancel() async throws(MawError) -> Bool {
            if cancelHangs {
                state.withLock { $0.requests.append("cancel") }
                try? await Task.sleep(for: .seconds(60))
                return false
            }
            let waiter = state.withLock { state in
                state.requests.append("cancel")
                state.cancelled = true
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
            // As the daemon answers: false when the import was no longer running.
            return !succeedsWhenCancelled && failsWhenCancelled == nil
        }

        func close() {
            continuation.finish()
        }
    }

    let directory: URL
    let errors: URL
    let standardOutputFile: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "maw-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        errors = directory.appending(path: "stderr.txt")
        standardOutputFile = directory.appending(path: "stdout.txt")
        try Data().write(to: errors)
        try Data().write(to: standardOutputFile)
    }

    func path(_ name: String) -> String {
        directory.appending(path: name).path(percentEncoded: false)
    }

    func command(
        _ daemon: FakeDaemon, file: String, user: String? = nil, inputIsTerminal: Bool = false,
        inputIsReadable: Bool = true
    ) -> ImportCommand {
        var command = ImportCommand(name: try! DistroName("Copy"), file: file, user: user)
        command.connect = { () async throws(MawError) -> any ImportDaemon in daemon }
        command.inputIsTerminal = inputIsTerminal
        command.inputIsReadable = inputIsReadable
        command.errorIsTerminal = false
        command.output = OutputQueue(
            standardOutput: open(standardOutputFile.path, O_WRONLY),
            standardError: open(errors.path, O_WRONLY))
        return command
    }

    var standardError: String {
        (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
    }

    var standardOutput: String {
        (try? String(contentsOf: standardOutputFile, encoding: .utf8)) ?? ""
    }

    var noSignals: AsyncStream<Int32> {
        AsyncStream { _ in }
    }

    /// maw opens the file and hands its descriptor over, with the file's absolute path.
    @Test func handsTheOpenedFileAndItsPathToTheDaemon() async throws {
        let file = path("ubuntu.tar")
        try Data("archive".utf8).write(to: URL(filePath: file))
        let daemon = FakeDaemon()
        let status = try await command(daemon, file: file, user: "ayse").run(signals: noSignals)
        #expect(status == 0)
        #expect(daemon.readBytes == Array("archive".utf8))
        let request = try #require(daemon.received.first)
        #expect(request.user == "ayse")
        // The kernel's path of the file, which resolves /var to /private/var, as realpath does.
        let real = try #require(realpath(file, nil))
        defer { free(real) }
        #expect(request.archive == String(validatingCString: real))
        #expect(request.hasValidArchive)
        #expect(standardOutput == "\nCopy is imported.\nRun maw -d Copy to open a shell as ayse.\n")
    }

    /// The archive is recorded by an absolute path: the kernel's, or a relative name made
    /// absolute against the current directory.
    @Test func recordsTheArchiveByAnAbsolutePath() throws {
        let file = path("relative.tar")
        try Data("x".utf8).write(to: URL(filePath: file))
        let current = FileManager.default.currentDirectoryPath
        let source = try ArchiveSource.open(file)
        defer { source.close() }
        #expect(source.description.hasPrefix("/"))
        #expect(source.description.hasSuffix("/relative.tar"))
        #expect(ArchiveSource.path(of: -1, opened: "/a/b/../c.tar") == "/a/b/../c.tar")
        #expect(
            ArchiveSource.path(of: -1, opened: "x/../y.tar")
                == URL(filePath: current, directoryHint: .isDirectory).appending(path: "y.tar")
                .standardized.path(percentEncoded: false))
    }

    @Test func readsStandardInputForADash() throws {
        let source = try ArchiveSource.open("-")
        #expect(source.descriptor == STDIN_FILENO)
        #expect(source.description == "standard input")
        source.close()
        #expect(fcntl(STDIN_FILENO, F_GETFD) != -1, "Standard input was closed.")
    }

    /// A non-blocking pipe, as some parent processes give their children, becomes blocking, so
    /// that the daemon's decompressor waits for input instead of failing with EAGAIN.
    @Test func makesANonBlockingInputBlocking() throws {
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
        ArchiveSource.makeBlocking(fds[0])
        #expect(fcntl(fds[0], F_GETFL) & O_NONBLOCK == 0)
    }

    /// Each refusal comes before the daemon is asked.
    @Test func refusesBeforeItConnects() async throws {
        let daemon = FakeDaemon()
        await #expect(throws: MawError.importFromTerminal) {
            try await command(daemon, file: "-", inputIsTerminal: true).run(signals: noSignals)
        }
        await #expect(throws: MawError.importInputNotReadable) {
            try await command(daemon, file: "-", inputIsReadable: false).run(signals: noSignals)
        }
        await #expect(
            throws: MawError.importArchiveNotReadable(
                path: path("missing.tar"), reason: "No such file or directory")
        ) {
            try await command(daemon, file: path("missing.tar")).run(signals: noSignals)
        }
        await #expect(
            throws: MawError.importArchiveNotReadable(
                path: directory.path, reason: "it is a directory")
        ) {
            try await command(daemon, file: directory.path).run(signals: noSignals)
        }
        let file = path("u.tar")
        try Data("x".utf8).write(to: URL(filePath: file))
        await #expect(throws: MawError.self) {
            try await command(daemon, file: file, user: "Bad").run(signals: noSignals)
        }
        #expect(daemon.requests.isEmpty)
    }

    @Test func passesTheDaemonsErrorOn() async throws {
        let file = path("u.tar")
        try Data("x".utf8).write(to: URL(filePath: file))
        let daemon = FakeDaemon()
        daemon.importError = .importInitNotSystemd(
            try DistroName("Copy"), reason: "/sbin/init leads to /bin/busybox")
        await #expect(throws: daemon.importError!) {
            try await command(daemon, file: file).run(signals: noSignals)
        }
    }

    /// A failed first start prints the start's error, which names the console log before
    /// maw --unregister, and fails, although the distribution is installed.
    @Test func reportsAFailedFirstStart() async throws {
        let file = path("u.tar")
        try Data("x".utf8).write(to: URL(filePath: file))
        let daemon = FakeDaemon()
        daemon.summary.firstStartFailure = .importStartFailed(
            try DistroName("Copy"), consoleLog: "/Users/ayse/Library/Logs/maw/Copy.log",
            reason: "the guest agent did not answer")
        let status = try await command(daemon, file: file).run(signals: noSignals)
        #expect(status == 1)
        #expect(standardOutput.contains("Copy is imported."))
        let text = standardError
        let log = try #require(text.range(of: "/Users/ayse/Library/Logs/maw/Copy.log"))
        let removal = try #require(text.range(of: "maw --unregister Copy"))
        #expect(log.upperBound < removal.lowerBound)
        #expect(text.contains("maw: Copy was imported, but its first start failed:"))
    }

    @Test func cancelsOnASignal() async throws {
        let file = path("u.tar")
        try Data("x".utf8).write(to: URL(filePath: file))
        let daemon = FakeDaemon()
        daemon.holdsUntilCancelled = true
        let (signals, sender) = AsyncStream.makeStream(of: Int32.self)
        let running = Task { try await command(daemon, file: file).run(signals: signals) }
        try await waitUntil { daemon.requests.contains("import Copy") }
        sender.yield(SIGINT)
        #expect(try await running.value == 128 + SIGINT)
        #expect(daemon.requests == ["import Copy", "cancel"])
        #expect(standardError.contains("Cancelling the import..."))
        #expect(standardError.contains("maw: The import of Copy was cancelled."))
    }

    /// An import that registered its distribution before the cancellation reached it finishes.
    @Test func reportsAnImportThatFinishedDespiteTheCancellation() async throws {
        let file = path("u.tar")
        try Data("x".utf8).write(to: URL(filePath: file))
        let daemon = FakeDaemon()
        daemon.holdsUntilCancelled = true
        daemon.succeedsWhenCancelled = true
        let (signals, sender) = AsyncStream.makeStream(of: Int32.self)
        let running = Task { try await command(daemon, file: file).run(signals: signals) }
        try await waitUntil { daemon.requests.contains("import Copy") }
        sender.yield(SIGINT)
        #expect(try await running.value == 0)
        #expect(standardOutput.contains("Copy is imported."))
    }

    /// An import that failed on its own before the cancellation reached it reports its own
    /// error, not the cancellation.
    @Test func reportsAFailureThatCameBeforeTheCancellation() async throws {
        let file = path("u.tar")
        try Data("x".utf8).write(to: URL(filePath: file))
        let daemon = FakeDaemon()
        daemon.holdsUntilCancelled = true
        daemon.failsWhenCancelled = .importInitNotSystemd(
            try DistroName("Copy"), reason: "/sbin/init leads to /bin/busybox")
        let (signals, sender) = AsyncStream.makeStream(of: Int32.self)
        let running = Task { try await command(daemon, file: file).run(signals: signals) }
        try await waitUntil { daemon.requests.contains("import Copy") }
        sender.yield(SIGINT)
        #expect(try await running.value == 1)
        #expect(standardError.contains("cannot be imported, because its /sbin/init is not systemd"))
        #expect(!standardError.contains("was cancelled"))
    }

    // MARK: The last lines

    @Test func namesTheDefaultAndTheUser() throws {
        var summary = ImportSummary(
            name: try DistroName("Copy"), defaultUser: "ayse", defaultUserSource: .option,
            isDefault: true, extractedBytes: 1, milliseconds: 1, firstStartFailure: nil)
        #expect(
            ImportCommand.summary(summary)
                == "Copy is imported, and is the default distribution.\n"
                + "Run maw to open a shell as ayse.")
        summary.isDefault = false
        summary.defaultUser = "root"
        summary.defaultUserSource = .option
        #expect(
            ImportCommand.summary(summary)
                == "Copy is imported.\nRun maw -d Copy to open a shell as root.")
    }

    /// When nothing named a user, the lines say how to choose one, within 80 columns for a
    /// name of 12 characters.
    @Test func suggestsChoosingAUserInsteadOfRoot() throws {
        let summary = ImportSummary(
            name: try DistroName("Ubuntu-24.04"), defaultUser: "root",
            defaultUserSource: .fallback, isDefault: false, extractedBytes: 1, milliseconds: 1,
            firstStartFailure: nil)
        let text = ImportCommand.summary(summary)
        #expect(
            text
                == "Ubuntu-24.04 is imported.\nRun maw -d Ubuntu-24.04 to open a shell as root.\n"
                + "The archive names no other default user. To choose one, run\n"
                + "maw --unregister Ubuntu-24.04, then maw --import Ubuntu-24.04 <file> -u <user>.")
        for line in text.split(separator: "\n") {
            #expect(line.count <= 80, "\(line.count): \(line)")
        }
    }

    @Test func labelsTheImportsSteps() throws {
        let text = InstallProgressText(
            name: try DistroName("Copy"), displayName: "", operation: .import)
        #expect(text.steps == InstallStep.import)
        #expect(
            text.steps.map(text.label(for:)) == [
                "Creating the virtual disk", "Formatting the disk", "Extracting the archive",
                "Checking the root file system", "Configuring Copy", "Writing the disk",
                "Starting Copy",
            ])
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "The condition did not become true.")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

extension ImportCommandTests {
    /// Tests that wait for the cancellation's time limit (decision record 0018).
    @Suite struct Latency {
        /// When the daemon does not answer the cancellation, as while the first start of a
        /// registered import runs, maw says that the outcome is not known.
        @Test func reportsAnUnconfirmedCancellation() async throws {
            let tests = try ImportCommandTests()
            let file = tests.path("u.tar")
            try Data("x".utf8).write(to: URL(filePath: file))
            let daemon = FakeDaemon()
            daemon.holdsUntilCancelled = true
            daemon.cancelHangs = true
            var command = tests.command(daemon, file: file)
            command.cancelTimeout = .milliseconds(200)
            let (signals, sender) = AsyncStream.makeStream(of: Int32.self)
            let running = Task { try await command.run(signals: signals) }
            let deadline = ContinuousClock.now + .seconds(5)
            while !daemon.requests.contains("import Copy") {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
            sender.yield(SIGINT)
            #expect(try await running.value == 128 + SIGINT)
            #expect(
                tests.standardError.contains(
                    "maw: The import of Copy may have registered it before the cancellation"),
                "\(tests.standardError)")
        }
    }
}
