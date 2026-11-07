import Foundation
import MawClient
import MawCore
import MawXPC
import Testing
import os

@testable import maw

/// The download's progress line on a terminal of 80, 60, and 40 columns.
@Suite struct InstallProgressWidthTests {
    let text = InstallProgressText(
        name: try! DistroName("Ubuntu-24.04"), displayName: "Ubuntu 24.04 LTS")
    static let progress = DownloadProgress(
        receivedBytes: 134_200_000, totalBytes: 388_300_496, bytesPerSecond: 5_400_000,
        resumedFromBytes: 18_600_000)
    static var done: DownloadProgress {
        var done = progress
        done.receivedBytes = done.totalBytes
        return done
    }

    @Test(arguments: [
        (80, "Downloading Ubuntu 24.04 LTS     134.2 MB of 388.3 MB, 5.4 MB/s, 47 s left"),
        (60, "Downloading 134.2 MB of 388.3 MB, 47 s left"),
        (40, "Downloading 34%, 47 s left"),
    ])
    func fitsTheDownloadsLine(columns: Int, expected: String) {
        let line = text.downloadingLine(
            Self.progress, columns: InstallProgressView.usable(columns))
        #expect(line == expected)
        #expect(line.count < columns)
    }

    @Test(arguments: [
        (80, "Downloading Ubuntu 24.04 LTS     388.3 MB in 1 min 9 s, resumed at 18.6 MB"),
        (60, "Downloading 388.3 MB in 1 min 9 s, resumed at 18.6 MB"),
        (40, "Downloading 388.3 MB in 1 min 9 s"),
    ])
    func fitsTheDownloadsLastLine(columns: Int, expected: String) {
        let line = text.downloadedLine(
            Self.done, milliseconds: 69_000, columns: InstallProgressView.usable(columns))
        #expect(line == expected)
        #expect(line.count < columns)
    }

    @Test func keepsTheWholeLineWhenItFits() {
        var fresh = Self.progress
        fresh.resumedFromBytes = 0
        #expect(
            text.downloadingLine(fresh, columns: 120)
                == "Downloading Ubuntu 24.04 LTS     134.2 MB of 388.3 MB, 5.4 MB/s, 47 s left")
        #expect(
            text.downloadingLine(Self.progress, columns: nil)
                == text.padded(.download) + InstallProgressText.downloading(Self.progress))
    }

    @Test func showsNoRateOrTimeLeftBeforeTheRateIsKnown() {
        var first = Self.progress
        first.bytesPerSecond = 0
        #expect(
            text.downloadingLine(first, columns: 79)
                == "Downloading Ubuntu 24.04 LTS     134.2 MB of 388.3 MB (resumed at 18.6 MB)")
    }

    @Test func truncatesAsALastResort() {
        #expect(text.downloadingLine(Self.progress, columns: 9) == "Downloadi")
        #expect(text.downloadingLine(nil, columns: 20) == "Downloading")
    }
}

/// What the progress view writes to a terminal and elsewhere.
@Suite struct InstallProgressViewTests {
    let text = InstallProgressText(
        name: try! DistroName("Ubuntu-24.04"), displayName: "Ubuntu 24.04 LTS")
    let columns = OSAllocatedUnfairLock(initialState: 80)
    let written = OSAllocatedUnfairLock(initialState: [String]())

    func view(isTerminal: Bool) -> InstallProgressView {
        let columns = self.columns
        let written = self.written
        return InstallProgressView(
            text: text, isTerminal: isTerminal, columns: { columns.withLock { $0 } },
            output: { string in written.withLock { $0.append(string) } })
    }

    func takeWritten() -> [String] {
        written.withLock { output in
            defer { output = [] }
            return output
        }
    }

    @Test func redrawsTheLineInPlaceAfterTheWindowNarrows() {
        let view = view(isTerminal: true)
        view.show(.started(.download))
        view.show(.download(InstallProgressWidthTests.progress))
        #expect(
            takeWritten() == [
                "\r\u{1B}[JDownloading Ubuntu 24.04 LTS     ",
                "\r\u{1B}[JDownloading Ubuntu 24.04 LTS     134.2 MB of 388.3 MB, 5.4 MB/s, "
                    + "47 s left",
            ])

        // At 40 columns, the terminal wraps the 74 characters drawn onto two rows: the redraw
        // moves up one row before it erases.
        columns.withLock { $0 = 40 }
        view.resized()
        #expect(takeWritten() == ["\r\u{1B}[1A\u{1B}[JDownloading 34%, 47 s left"])

        columns.withLock { $0 = 60 }
        view.show(.download(InstallProgressWidthTests.progress))
        #expect(takeWritten() == ["\r\u{1B}[JDownloading 134.2 MB of 388.3 MB, 47 s left"])

        view.show(.download(InstallProgressWidthTests.done))
        view.show(.finished(.download, milliseconds: 69_000))
        #expect(
            takeWritten().suffix(2) == [
                "\r\u{1B}[JDownloading 388.3 MB in 1 min 9 s, resumed at 18.6 MB", "\n",
            ])
        // Nothing is redrawn once the step has finished.
        view.resized()
        #expect(takeWritten().isEmpty)
    }

    @Test func writesOnlyEachStepsLastLineElsewhere() {
        let view = view(isTerminal: false)
        view.show(.started(.download))
        view.show(.download(InstallProgressWidthTests.progress))
        view.resized()
        view.show(.download(InstallProgressWidthTests.done))
        view.show(.finished(.download, milliseconds: 69_000))
        view.show(.started(.verify))
        view.show(.finished(.verify, milliseconds: 300))
        #expect(
            takeWritten().joined()
                == "Downloading Ubuntu 24.04 LTS     388.3 MB in 1 min 9 s (5.4 MB/s), "
                + "resumed at 18.6 MB\nVerifying the image              0.3 s\n")
    }
}

/// `maw --install` asks for nothing before every error that is knowable without the account.
@Suite struct InstallCommandOrderTests {
    let calls = OSAllocatedUnfairLock(initialState: [String]())

    final class FakeDaemon: InstallDaemon, @unchecked Sendable {
        let calls: OSAllocatedUnfairLock<[String]>
        let checkError: MawError?
        let events = AsyncStream<DaemonClient.Event> { $0.finish() }

        init(calls: OSAllocatedUnfairLock<[String]>, checkError: MawError?) {
            self.calls = calls
            self.checkError = checkError
        }

        func checkInstall(distribution: String?, name: DistroName?) async throws(MawError) {
            calls.withLock { $0.append("check \(distribution ?? "-") \(name?.rawValue ?? "-")") }
            if let checkError {
                throw checkError
            }
        }

        func install(_ request: InstallRequest) async throws(MawError) -> InstallSummary {
            throw .notImplemented(feature: "install", phase: "test")
        }

        func cancelInstall() async throws(MawError) -> Bool { false }

        func close() {
            calls.withLock { $0.append("close") }
        }
    }

    func command(
        distro: String? = nil, name: String? = nil, connectError: MawError? = nil,
        checkError: MawError? = nil
    ) -> InstallCommand {
        let calls = self.calls
        var command = InstallCommand(
            options: InstallOptions(
                distro: distro.map { try! DistroName($0) }, name: name.map { try! DistroName($0) },
                user: "ayse"))
        command.connect = { () async throws(MawError) -> any InstallDaemon in
            calls.withLock { $0.append("connect") }
            if let connectError {
                throw connectError
            }
            return FakeDaemon(calls: calls, checkError: checkError)
        }
        command.askForAccount = { _ in
            calls.withLock { $0.append("ask") }
            return (try UserName("ayse", reservedNames: []), Secret("secret"))
        }
        return command
    }

    @Test func checksEverythingBeforeItAsksForTheAccount() async throws {
        let (preparation, _, user, _) = try await command(name: "Work").prepare()
        #expect(preparation.name.rawValue == "Work")
        #expect(user.rawValue == "ayse")
        #expect(calls.withLock { $0 } == ["connect", "check Ubuntu-24.04 Work", "ask"])
    }

    @Test func asksForNothingWhenTheSignatureIsRejected() async {
        await #expect(throws: MawError.clientSignatureRejected(identifier: "maw")) {
            try await command(connectError: .clientSignatureRejected(identifier: "maw")).prepare()
        }
        #expect(calls.withLock { $0 } == ["connect"])
    }

    @Test(arguments: [
        MawError.distributionAlreadyInstalled(try! DistroName("Ubuntu-24.04")),
        .insufficientDiskSpace(required: 5 << 30, available: 1 << 30, volume: "Macintosh HD"),
        .installationInProgress(try! DistroName("Ubuntu-24.04")),
    ])
    func asksForNothingWhenTheDaemonsCheckFails(_ error: MawError) async {
        await #expect(throws: error) {
            try await command(checkError: error).prepare()
        }
        #expect(calls.withLock { $0 } == ["connect", "check Ubuntu-24.04 -", "close"])
    }

    @Test func refusesAnUnknownDistributionBeforeConnecting() async {
        await #expect(throws: MawError.unknownDistribution("Debian")) {
            try await command(distro: "Debian").prepare()
        }
        #expect(calls.withLock { $0 }.isEmpty)
    }
}

/// Ctrl-C ends `maw --install` while nothing reads its output, as after Ctrl-S on a terminal.
@Suite struct InstallCancellationTests {
    /// Installs until it is cancelled.
    final class StalledDaemon: InstallDaemon, @unchecked Sendable {
        let events: AsyncStream<DaemonClient.Event>
        private let continuation: AsyncStream<DaemonClient.Event>.Continuation
        let cancelled = OSAllocatedUnfairLock(initialState: false)

        init() {
            (events, continuation) = AsyncStream.makeStream(of: DaemonClient.Event.self)
        }

        func report(_ progress: InstallProgress) {
            continuation.yield(.installProgress(progress))
        }

        func checkInstall(distribution: String?, name: DistroName?) async throws(MawError) {}

        func install(_ request: InstallRequest) async throws(MawError) -> InstallSummary {
            while !cancelled.withLock({ $0 }) {
                try? await Task.sleep(for: .milliseconds(10))
            }
            throw .installationCancelled(try! DistroName("Ubuntu-24.04"))
        }

        func cancelInstall() async throws(MawError) -> Bool {
            cancelled.withLock { $0 = true }
            return true
        }

        func close() {}
    }
}

extension InstallCancellationTests {
    /// Tests that assert latency. A suite named `Latency` puts them in the latency group, which
    /// runs one test at a time and never beside a load generator (scripts/test-groups.sh).
    @Suite struct Latency {
        @Test(.timeLimit(.minutes(1)))
        func endsOnCtrlCWhileStandardOutputIsNotRead() async throws {
            var descriptors: [Int32] = [-1, -1]
            try #require(pipe(&descriptors) == 0)
            let (reader, writer) = (descriptors[0], descriptors[1])
            let output = OutputQueue(standardOutput: writer, standardError: writer)
            // More than a pipe holds: the queue's thread blocks in write(2) until the pipe is read.
            output.write(String(repeating: "x", count: 1 << 20))

            let view = InstallProgressView(
                text: InstallProgressText(
                    name: try DistroName("Ubuntu-24.04"), displayName: "Ubuntu 24.04 LTS"),
                isTerminal: true, columns: { 80 }, output: output.write)
            let daemon = StalledDaemon()
            let (signals, signal) = AsyncStream.makeStream(of: Int32.self)
            let (resizes, _) = AsyncStream.makeStream(of: Int32.self)
            let request = InstallRequest(
                distribution: "Ubuntu-24.04", name: nil, user: "ayse", password: Secret("secret"),
                locale: nil)
            let ended = OSAllocatedUnfairLock<InstallCommand.Ending?>(initialState: nil)
            Task.detached {
                let ending = try? await InstallCommand.perform(
                    request, name: try DistroName("Ubuntu-24.04"), on: daemon, view: view,
                    output: output, signals: signals, resizes: resizes)
                ended.withLock { $0 = ending }
            }
            daemon.report(.started(.download))
            for _ in 0..<20 {
                daemon.report(.download(InstallProgressWidthTests.progress))
                try await Task.sleep(for: .milliseconds(10))
            }

            let sent = ContinuousClock.now
            signal.yield(SIGINT)
            while ended.withLock({ $0 }) == nil, ContinuousClock.now - sent < .seconds(5) {
                try await Task.sleep(for: .milliseconds(5))
            }
            let delay = ContinuousClock.now - sent
            guard case .status(let status) = ended.withLock({ $0 }) else {
                Issue.record("maw --install did not end within 5 seconds of Ctrl-C")
                return
            }
            #expect(status == 130)
            #expect(delay < .seconds(1), "Ctrl-C took \(delay)")
            #expect(daemon.cancelled.withLock { $0 })

            // The pipe is read at last: everything queued is written, in order, and the pipe can
            // be closed.
            let text = OSAllocatedUnfairLock(initialState: [UInt8]())
            let drained = Thread {
                var buffer = [UInt8](repeating: 0, count: 64 << 10)
                while true {
                    let count = buffer.withUnsafeMutableBytes {
                        read(reader, $0.baseAddress, $0.count)
                    }
                    guard count > 0 else { break }
                    let bytes = buffer[..<count]
                    text.withLock { $0 += bytes }
                }
            }
            drained.start()
            #expect(await output.waitUntilWritten(timeout: .seconds(5)))
            close(writer)
            try await Task.sleep(for: .milliseconds(100))
            close(reader)
            let written = String(decoding: text.withLock { $0 }, as: UTF8.self)
            #expect(
                written.hasSuffix(
                    "Cancelling the installation...\n"
                        + "maw: The installation of Ubuntu-24.04 was cancelled.\n"
                        + "Nothing was installed. Run maw --install to start again; an interrupted\n"
                        + "download resumes where it stopped.\n"))
        }
    }
}

/// Ctrl-C as the installation ends: the daemon answers `cancelInstall` that nothing was running
/// any more, and maw reports how the installation ended, as the installation's own reply says.
@Suite struct InstallEndedBeforeTheCancellationTests {
    /// When the installation's reply arrives, compared with the answer to `cancelInstall`.
    enum ReplyOrder: Sendable {
        case beforeTheAnswer
        case afterTheAnswer
        case never
    }

    /// An installation that ends when maw asks to cancel it, before the daemon receives the
    /// request, so that the daemon answers that nothing was running.
    final class EndedDaemon: InstallDaemon, @unchecked Sendable {
        struct State {
            var cancelRequested = false
            var replied = false
            var released = false
        }

        let events = AsyncStream<DaemonClient.Event> { $0.finish() }
        let order: ReplyOrder
        let failure: MawError?
        private let state = OSAllocatedUnfairLock(initialState: State())

        init(order: ReplyOrder, failure: MawError?) {
            self.order = order
            self.failure = failure
        }

        func checkInstall(distribution: String?, name: DistroName?) async throws(MawError) {}

        func install(_ request: InstallRequest) async throws(MawError) -> InstallSummary {
            await wait { $0.cancelRequested }
            switch order {
            case .beforeTheAnswer:
                break
            case .afterTheAnswer:
                // The answer to cancelInstall is on its way; this reply follows it.
                try? await Task.sleep(for: .milliseconds(100))
            case .never:
                await wait { $0.released }
            }
            state.withLock { $0.replied = true }
            if let failure {
                throw failure
            }
            return InstallSummary(
                name: try! DistroName("Ubuntu-24.04"), displayName: "Ubuntu 24.04 LTS",
                defaultUser: "ayse", isDefault: true, milliseconds: 1)
        }

        func cancelInstall() async throws(MawError) -> Bool {
            state.withLock { $0.cancelRequested = true }
            if order == .beforeTheAnswer {
                // The installation's reply is on its way first.
                await wait { $0.replied }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }

        func close() {}

        /// Lets an installation whose reply was held back end, once the test is over.
        func release() {
            state.withLock { $0.released = true }
        }

        private func wait(until condition: @escaping @Sendable (State) -> Bool) async {
            while !state.withLock({ condition($0) }) {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    static let failure = MawError.provisioningFailed(step: "extracting", reason: "the fake failed")

    /// Runs `perform` against `daemon` after a SIGINT, and returns how it ended and what it
    /// wrote to standard output and standard error.
    static func interrupt(
        _ daemon: EndedDaemon
    ) async throws -> (ending: InstallCommand.Ending, output: String, error: String) {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "maw-install-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputFile = directory.appending(path: "output")
        let errorFile = directory.appending(path: "error")
        let standardOutput = open(
            outputFile.path(percentEncoded: false), O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        let standardError = open(
            errorFile.path(percentEncoded: false), O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        defer {
            close(standardOutput)
            close(standardError)
        }
        try #require(standardOutput >= 0 && standardError >= 0)
        let output = OutputQueue(standardOutput: standardOutput, standardError: standardError)
        let name = try DistroName("Ubuntu-24.04")
        let view = InstallProgressView(
            text: InstallProgressText(name: name, displayName: "Ubuntu 24.04 LTS"),
            isTerminal: false, columns: { 80 }, output: output.write)
        let (signals, signal) = AsyncStream.makeStream(of: Int32.self)
        let (resizes, _) = AsyncStream.makeStream(of: Int32.self)
        let request = InstallRequest(
            distribution: "Ubuntu-24.04", name: nil, user: "ayse", password: Secret("secret"),
            locale: nil)
        signal.yield(SIGINT)
        let ending = try await InstallCommand.perform(
            request, name: name, on: daemon, view: view, output: output, signals: signals,
            resizes: resizes)
        #expect(await output.waitUntilWritten(timeout: .seconds(5)))
        return (
            ending, try String(contentsOf: outputFile, encoding: .utf8),
            try String(contentsOf: errorFile, encoding: .utf8)
        )
    }

    /// The daemon has sent the installation's reply, but it does not arrive: maw says that
    /// it does not know how the installation ended, and neither claims that it finished nor
    /// that the daemon went away.
    @Test(.timeLimit(.minutes(1)))
    func reportsAnUnknownOutcomeWithoutTheInstallationsReply() async throws {
        let daemon = EndedDaemon(order: .never, failure: Self.failure)
        defer { daemon.release() }
        let result = try await Self.interrupt(daemon)
        guard case .status(let status) = result.ending else {
            Issue.record("maw --install reported \(result.ending)")
            return
        }
        #expect(status == 130)
        #expect(
            result.error
                == "Cancelling the installation...\n"
                + "maw: The installation of Ubuntu-24.04 had already ended when maw asked the "
                + "daemon to cancel it, but its result did not reach maw, so it is not known "
                + "whether Ubuntu-24.04 was installed.\n"
                + "maw -d Ubuntu-24.04 -e true succeeds if it is installed, and otherwise says "
                + "that it is not; then run maw --install again.\n")
        #expect(!(result.output + result.error).contains("already finished"))
    }
}

extension InstallEndedBeforeTheCancellationTests {
    /// Tests that assert latency. A suite named `Latency` puts them in the latency group, which
    /// runs one test at a time and never beside a load generator (scripts/test-groups.sh).
    /// These depend on the installation's reply arriving within
    /// `InstallCommand.installReplyTimeout`.
    @Suite struct Latency {
        /// The installation failed: maw reports its failure and exits as it would have without
        /// Ctrl-C, whichever reply reaches it first.
        @Test(.timeLimit(.minutes(1)), arguments: [ReplyOrder.beforeTheAnswer, .afterTheAnswer])
        func reportsTheInstallationsFailure(order: ReplyOrder) async throws {
            let failure = InstallEndedBeforeTheCancellationTests.failure
            let result = try await InstallEndedBeforeTheCancellationTests.interrupt(
                EndedDaemon(order: order, failure: failure))
            guard case .status(let status) = result.ending else {
                Issue.record("maw --install reported \(result.ending)")
                return
            }
            #expect(status == 1)
            #expect(
                result.error
                    == "Cancelling the installation...\n"
                    + (Maw.failure(for: failure)?.output ?? "")
            )
            #expect(!(result.output + result.error).contains("already finished"))
        }

        /// The installation finished: maw says so, whichever reply reaches it first.
        @Test(.timeLimit(.minutes(1)), arguments: [ReplyOrder.beforeTheAnswer, .afterTheAnswer])
        func reportsAFinishedInstallation(order: ReplyOrder) async throws {
            let result = try await InstallEndedBeforeTheCancellationTests.interrupt(
                EndedDaemon(order: order, failure: nil))
            guard case .status(let status) = result.ending else {
                Issue.record("maw --install reported \(result.ending)")
                return
            }
            #expect(status == 0)
            #expect(
                result.output
                    == "The installation had already finished. Run maw -d Ubuntu-24.04 to use it.\n"
            )
            #expect(result.error == "Cancelling the installation...\n")
        }
    }
}

/// Where `maw --install` asks for the account: on the controlling terminal, so that standard
/// output and standard error can go to a pipe, as in `maw --install 2>&1 | tee install.log`.
///
/// Each test runs `InstallCommand` in a child process (an exit test), whose standard output and
/// standard error are pipes that swift-testing reads, and whose standard input and controlling
/// terminal are a pseudo-terminal that the child creates.
@Suite struct InstallPromptTests {
    /// Installs at once, after reporting two steps.
    final class InstalledDaemon: InstallDaemon, @unchecked Sendable {
        let events: AsyncStream<DaemonClient.Event>

        init() {
            let (events, continuation) = AsyncStream.makeStream(of: DaemonClient.Event.self)
            self.events = events
            continuation.yield(.installProgress(.started(.download)))
            continuation.yield(
                .installProgress(
                    .download(
                        DownloadProgress(
                            receivedBytes: 1 << 20, totalBytes: 2 << 20, bytesPerSecond: 1 << 20,
                            resumedFromBytes: 0))))
            continuation.yield(.installProgress(.finished(.download, milliseconds: 2_000)))
            continuation.yield(.installProgress(.started(.verify)))
            continuation.yield(.installProgress(.finished(.verify, milliseconds: 230)))
            continuation.finish()
        }

        func checkInstall(distribution: String?, name: DistroName?) async throws(MawError) {}

        func install(_ request: InstallRequest) async throws(MawError) -> InstallSummary {
            guard request.user == "ayse", request.password == Secret("a secret word") else {
                throw .invalidPassword(reason: "the test daemon got another account")
            }
            // Gives the events above time to be shown before the reply.
            try? await Task.sleep(for: .milliseconds(100))
            return InstallSummary(
                name: try! DistroName("Ubuntu-24.04"), displayName: "Ubuntu 24.04 LTS",
                defaultUser: "ayse", isDefault: true, milliseconds: 2_500)
        }

        func cancelInstall() async throws(MawError) -> Bool { false }
        func close() {}
    }

    static let password = "a secret word"

    /// In the child: makes a new pseudo-terminal the controlling terminal and standard input,
    /// answers the prompts on it as a user would, runs `maw --install`, and checks what the
    /// terminal showed. Exits with 0 if everything held, otherwise with a status that names the
    /// check that failed.
    static func installOnAPseudoTerminal() async {
        var primary: Int32 = -1
        var secondary: Int32 = -1
        guard openpty(&primary, &secondary, nil, nil, nil) == 0 else { exit(10) }
        guard setsid() >= 0 else { exit(11) }
        guard ioctl(secondary, TIOCSCTTY, 0) == 0 else { exit(12) }
        guard dup2(secondary, STDIN_FILENO) >= 0 else { exit(13) }

        // The user: types each answer once its prompt has appeared, since readpassphrase
        // discards what was typed before it turned echo off.
        let screen = OSAllocatedUnfairLock(initialState: [UInt8]())
        let terminal = primary
        let user = Thread {
            // Each prompt appears once when every answer is accepted.
            let answers = [
                ("New user name: ", "ayse\n"), ("New password: ", password + "\n"),
                ("Retype the new password: ", password + "\n"),
            ]
            var next = 0
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    read(terminal, $0.baseAddress, $0.count)
                }
                guard count > 0 else { return }
                let received = Array(buffer[..<count])
                let shown = screen.withLock {
                    $0 += received
                    return String(decoding: $0, as: UTF8.self)
                }
                while next < answers.count, shown.contains(answers[next].0) {
                    _ = answers[next].1.withCString { write(terminal, $0, strlen($0)) }
                    next += 1
                }
            }
        }
        user.start()

        var command = InstallCommand(options: InstallOptions(distro: nil, name: nil, user: nil))
        command.connect = { () async throws(MawError) -> any InstallDaemon in InstalledDaemon() }
        // No shell opens when standard output is not a terminal.
        command.openShell = { _ in exit(14) }
        guard (try? await command.run()) == 0 else { exit(15) }

        let shown = screen.withLock { String(decoding: $0, as: UTF8.self) }
        for prompt in [
            "Create the default Linux user account.", "New user name: ", "New password: ",
            "Retype the new password: ",
        ] where !shown.contains(prompt) {
            exit(16)
        }
        // The name is echoed as it is typed; the password never is.
        guard shown.contains("ayse"), !shown.contains(password) else { exit(17) }
        exit(0)
    }

    /// Without a terminal on standard input, and without `--user`, there is nothing to ask on.
    @Test(.timeLimit(.minutes(1)))
    func refusesWithoutATerminalOnStandardInput() async throws {
        await #expect(processExitsWith: .success) {
            let empty = open("/dev/null", O_RDONLY)
            guard empty >= 0, dup2(empty, STDIN_FILENO) >= 0 else { exit(10) }
            var command = InstallCommand(options: InstallOptions(distro: nil, name: nil, user: nil))
            command.connect = { () async throws(MawError) -> any InstallDaemon in
                exit(11)
            }
            do {
                _ = try await command.prepare()
                exit(12)
            } catch let error as MawError {
                guard error == .installNeedsTerminal,
                    error.errorDescription
                        == "maw --install asks for a user name and a password, but standard input "
                        + "is not a terminal."
                else { exit(13) }
                exit(0)
            } catch {
                exit(14)
            }
        }
    }
}

extension InstallPromptTests {
    /// Tests that assert latency. A suite named `Latency` puts them in the latency group, which
    /// runs one test at a time and never beside a load generator (scripts/test-groups.sh).
    /// This one expects the progress that the fake daemon reports 100 ms before its reply.
    @Suite struct Latency {
        @Test(.timeLimit(.minutes(1)))
        func asksOnTheControllingTerminalWhileTheOutputGoesToAPipe() async throws {
            let result = await #expect(
                processExitsWith: .success,
                observing: [\.standardOutputContent, \.standardErrorContent]
            ) {
                await InstallPromptTests.installOnAPseudoTerminal()
            }
            let output = String(decoding: result?.standardOutputContent ?? [], as: UTF8.self)
            let error = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
            let both = output + error
            #expect(
                output.hasPrefix("Installing Ubuntu 24.04 LTS.\n")
                    && output.contains(
                        "Ubuntu-24.04 is installed, and is the default distribution."),
                "\(output)")
            // The progress, as plain lines.
            #expect(output.contains("Downloading"), "\(output)")
            for prompt in ["Create the default", "user name", "password", "Retype"] {
                #expect(!both.contains(prompt), "\(prompt) in \(both)")
            }
            #expect(!both.contains(InstallPromptTests.password))
            #expect(!both.contains("\u{1B}"), "An escape sequence in \(both.debugDescription)")
            #expect(!both.contains("\r"), "A carriage return in \(both.debugDescription)")
        }
    }
}

/// After Ctrl-C, a cancellation that the daemon cannot be asked for, and one that it has not
/// answered in time, are told apart.
@Suite struct InstallCancellationOutcomeTests {
    /// Answers `cancelInstall` as `behavior` says.
    final class CancellingDaemon: InstallDaemon, @unchecked Sendable {
        enum Behavior {
            /// The request fails, as when the connection is lost.
            case fails
            /// No answer, while the connection stays open.
            case neverAnswers
        }

        let behavior: Behavior
        let events: AsyncStream<DaemonClient.Event>
        private let released = OSAllocatedUnfairLock(initialState: false)

        init(_ behavior: Behavior) {
            self.behavior = behavior
            (events, _) = AsyncStream.makeStream(of: DaemonClient.Event.self)
        }

        func checkInstall(distribution: String?, name: DistroName?) async throws(MawError) {}

        func install(_ request: InstallRequest) async throws(MawError) -> InstallSummary {
            throw .installationCancelled(try! DistroName("Ubuntu-24.04"))
        }

        func cancelInstall() async throws(MawError) -> Bool {
            switch behavior {
            case .fails:
                throw .daemonConnectionLost(during: "cancelInstall")
            case .neverAnswers:
                while !released.withLock({ $0 }) {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return true
            }
        }

        func close() {}

        func release() {
            released.withLock { $0 = true }
        }
    }

    @Test func reportsALostConnectionWhenTheRequestFails() async {
        let daemon = CancellingDaemon(.fails)
        #expect(await InstallCommand.cancel(on: daemon, timeout: .seconds(30)) == .requestFailed)
    }

    @Test func reportsAnUnansweredCancellationWhileTheConnectionStaysOpen() async {
        let daemon = CancellingDaemon(.neverAnswers)
        defer { daemon.release() }
        #expect(
            await InstallCommand.cancel(on: daemon, timeout: .milliseconds(50)) == .unanswered)
    }

    @Test func saysThatTheConnectionWasLost() throws {
        let failure = try #require(
            Maw.failure(for: MawError.daemonConnectionLost(during: "cancelling the installation")))
        #expect(
            failure.output
                == "maw: The maw daemon exited or closed the connection during cancelling the "
                + "installation.\nThe daemon's log, ~/Library/Logs/maw/mawd.log, may say why.\n")
    }

    @Test func saysThatTheCancellationIsNotConfirmedYet() throws {
        let failure = try #require(
            Maw.failure(
                for: MawError.installationCancellationUnconfirmed(try DistroName("Ubuntu-24.04"))))
        #expect(
            failure.output
                == """
                maw: The daemon has not yet confirmed the cancellation of the installation of
                Ubuntu-24.04. The installation may still be ending.
                Wait a moment, then run maw -d Ubuntu-24.04 -e true. It succeeds if
                Ubuntu-24.04 was installed after all, and otherwise says that it is not.

                """)
        for line in failure.output.split(separator: "\n") {
            #expect(line.count <= 80, "\(line)")
        }
    }
}

/// The summary at the end of an installation, on a terminal of 60 columns.
@Suite struct InstallSummaryWidthTests {
    @Test(arguments: [
        (
            "Ubuntu-24.04", "ayse", true,
            "Ubuntu-24.04 is installed, and is the default distribution.\n"
                + "Run maw to open a shell as ayse."
        ),
        (
            "CapC-resize", "capture", false,
            "CapC-resize is installed.\nRun maw -d CapC-resize to open a shell as capture."
        ),
    ])
    func fitsSixtyColumns(name: String, user: String, isDefault: Bool, expected: String) throws {
        let text = InstallCommand.summary(
            InstallSummary(
                name: try DistroName(name), displayName: "Ubuntu 24.04 LTS", defaultUser: user,
                isDefault: isDefault, milliseconds: 1))
        #expect(text == expected)
        // The columns that maw's install output uses on a terminal of 60: all but the last.
        for line in text.split(separator: "\n") {
            #expect(line.count <= InstallProgressView.usable(60), "\(line)")
        }
    }
}
