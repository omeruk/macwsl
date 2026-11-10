import Darwin
import Foundation
import MawClient
import MawCore
import MawProtocol
import Observation
import Testing
import os

@testable import MawTerminalKit

/// `LinuxSession` against a scripted core. The core itself is tested in the root package.
@MainActor
@Suite struct LinuxSessionTests {
    /// A core whose output, opening, ending, and foreground answer the test controls.
    final class FakeCore: LinuxSessionCore, @unchecked Sendable {
        struct Record {
            var input: [UInt8] = []
            var sizes: [MawProtocol.TerminalSize] = []
            var hangUps = 0
        }

        let terminal: MawProtocol.TerminalSize
        let output: GuestAgentClient.OutputHandler
        let record = OSAllocatedUnfairLock(initialState: Record())
        let name: String?
        let foreground: ForegroundAnswer
        private let ending = AsyncStream<DistributionSession.Ending>.makeStream()

        init(
            terminal: MawProtocol.TerminalSize, output: @escaping GuestAgentClient.OutputHandler,
            name: String?, foreground: ForegroundAnswer
        ) {
            self.terminal = terminal
            self.output = output
            self.name = name
            self.foreground = foreground
        }

        func openShell() async -> String? { name }

        func send(_ bytes: some Collection<UInt8>) {
            let bytes = Array(bytes)
            record.withLock { $0.input += bytes }
        }

        func resize(_ size: MawProtocol.TerminalSize) {
            record.withLock { $0.sizes.append(size) }
        }

        func foregroundProgram(within timeout: Duration) async -> ForegroundAnswer { foreground }

        func hangUp() {
            record.withLock { $0.hangUps += 1 }
            end(.hungUp)
        }

        func waitForEnding() async -> DistributionSession.Ending {
            for await ending in ending.stream { return ending }
            return .hungUp
        }

        /// Writes output as the core's reading thread does, from a thread of its own, then
        /// ends the session with `ending` if given.
        func emit(_ chunks: [[UInt8]], then ending: DistributionSession.Ending? = nil) {
            Thread.detachNewThread { [self] in
                for chunk in chunks {
                    chunk.withUnsafeBytes { output(.stdout, $0) }
                }
                if let ending { end(ending) }
            }
        }

        func end(_ value: DistributionSession.Ending) {
            ending.continuation.yield(value)
            ending.continuation.finish()
        }
    }

    @MainActor
    final class Recorder: TerminalSessionDelegate {
        var output: [UInt8] = []
        var largestSlice = 0
        var titles: [String] = []
        var directories: [String] = []
        var status: TerminationStatus?
        var failure: TerminalSessionError?
        var fallback: (replacement: any TerminalSession, notice: String?)?
        var notices: [String] = []
        /// What arrived, in order: `notice` or `output`.
        var events: [String] = []
        /// Called with the bytes received so far, before each slice is added.
        var onSlice: ((Int) -> Void)?

        func session(_ session: any TerminalSession, didReceive bytes: ArraySlice<UInt8>) {
            onSlice?(output.count)
            if events.last != "output" { events.append("output") }
            largestSlice = max(largestSlice, bytes.count)
            output += bytes
        }

        func session(_ session: any TerminalSession, didChangeTitle title: String) {
            titles.append(title)
        }

        func session(_ session: any TerminalSession, didChangeWorkingDirectory directory: String) {
            directories.append(directory)
        }

        func session(_ session: any TerminalSession, didTerminateWith status: TerminationStatus) {
            self.status = status
        }

        func session(_ session: any TerminalSession, didFailWith error: TerminalSessionError) {
            failure = error
        }

        func session(
            _ session: any TerminalSession, didFallBackTo replacement: any TerminalSession,
            notice: String?
        ) {
            fallback = (replacement, notice)
        }

        func session(_ session: any TerminalSession, didNotice notice: String) {
            notices.append(notice)
            events.append("notice")
        }
    }

    /// Starts a session on a fake core and returns both.
    func start(
        _ recorder: Recorder, name: String? = "Ubuntu-24.04", opens: String? = "Ubuntu-24.04",
        foreground: ForegroundAnswer = .none, size: MawTerminalKit.TerminalSize = .default,
        fallback: LinuxSession.FallBack? = nil
    ) throws -> (LinuxSession, FakeCore) {
        var core: FakeCore?
        let session = LinuxSession(name: name, fallback: fallback) { terminal, output in
            let made = FakeCore(
                terminal: terminal, output: output, name: opens, foreground: foreground)
            core = made
            return made
        }
        session.delegate = recorder
        try session.start(size: size)
        return (session, try #require(core))
    }

    @Test func outputArrivesInOrderThenTheExitStatus() async throws {
        let recorder = Recorder()
        let (session, core) = try start(
            recorder, size: MawTerminalKit.TerminalSize(columns: 101, rows: 33))
        #expect(core.terminal == MawProtocol.TerminalSize(rows: 33, columns: 101))
        let chunks = (0..<64).map { [UInt8](repeating: UInt8($0), count: 4096) }
        core.emit(chunks, then: .exited(.exited(code: 3)))
        #expect(await waitUntil(seconds: 5) { recorder.status != nil })
        #expect(recorder.output == chunks.flatMap { $0 })
        #expect(recorder.status == .exited(3))
        #expect(recorder.failure == nil)
        #expect(!session.isRunning)
    }

    @Test func aFloodIsDeliveredInBoundedSlicesWithBoundedMemory() async throws {
        let recorder = Recorder()
        let (session, core) = try start(recorder)
        let chunk = 64 << 10
        let written = OSAllocatedUnfairLock(initialState: 0)
        var largestBacklog = 0
        recorder.onSlice = { received in
            largestBacklog = max(largestBacklog, written.withLock { $0 } - received)
        }
        let total = 16 << 20
        Thread.detachNewThread {
            let bytes = [UInt8](repeating: 0x61, count: chunk)
            for _ in 0..<(total / chunk) {
                bytes.withUnsafeBytes { core.output(.stdout, $0) }
                written.withLock { $0 += chunk }
            }
            core.end(.exited(.exited(code: 0)))
        }
        #expect(await waitUntil(seconds: 20) { recorder.status != nil })
        #expect(recorder.output.count == total)
        #expect(recorder.largestSlice <= OutputPump<Int>.sliceLimit)
        // At most a full pump of 1 MiB, plus the slice being delivered, which the writer
        // refilled the pump behind.
        #expect(largestBacklog <= OutputPump<Int>.capacity + OutputPump<Int>.sliceLimit)
        #expect(!session.isRunning)
    }

    @Test func aFailureReachesTheDelegateWithMawsMessageAndSuggestion() async throws {
        let recorder = Recorder()
        let (session, core) = try start(recorder)
        let error = MawError.machineStopped(machine: "Ubuntu-24.04", reason: "it was stopped")
        core.emit([Array("last words\r\n".utf8)], then: .failed(error))
        #expect(await waitUntil(seconds: 5) { recorder.failure != nil })
        #expect(
            recorder.failure
                == .failed(
                    message: "The session ended because the virtual machine Ubuntu-24.04 "
                        + "stopped:\nit was stopped.",
                    suggestion: "Press Enter to start a new session, which starts the virtual "
                        + "machine again."))
        #expect(recorder.text == "last words\r\n")
        #expect(recorder.status == nil)
        #expect(!session.isRunning)
    }

    @Test func closingHangsUpAndReportsNothing() async throws {
        let recorder = Recorder()
        let (session, core) = try start(recorder)
        session.terminate()
        #expect(core.record.withLock { $0.hangUps } == 1)
        #expect(!session.isRunning)
        core.emit([Array("late".utf8)])
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.output.isEmpty)
        #expect(recorder.status == nil && recorder.failure == nil)
        #expect(await session.foregroundProgram(within: .milliseconds(100)) == .none)
        session.terminate()
        #expect(core.record.withLock { $0.hangUps } == 1)
    }

    @Test func theNameIsTheStoredOneOnceTheSessionOpens() async throws {
        let recorder = Recorder()
        let (session, _) = try start(recorder, name: nil, opens: "Debian-13")
        #expect(await waitUntil(seconds: 5) { session.displayName == "Debian-13" })
        let (unopened, _) = try start(recorder, name: nil, opens: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(unopened.displayName == "linux")
    }

    /// Views read the name through the pane, and follow it from `linux` to the stored name.
    @Test func viewsFollowTheNameOnceTheSessionOpens() async throws {
        let session = LinuxSession(name: nil) { terminal, output in
            FakeCore(terminal: terminal, output: output, name: "Debian-13", foreground: .none)
        }
        let pane = PaneController(profile: .defaultDistribution, session: session)
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = pane.displayName
        } onChange: {
            changed.withLock { $0 = true }
        }
        try session.start(size: .default)
        #expect(await waitUntil(seconds: 5) { changed.withLock { $0 } })
        #expect(pane.displayName == "Debian-13")
        session.terminate()
    }

    @Test func inputAndResizesReachTheCore() throws {
        let recorder = Recorder()
        let (session, core) = try start(recorder)
        session.send(ArraySlice("ğüşıöç\u{3}".utf8))
        session.resize(to: .default)
        session.resize(to: MawTerminalKit.TerminalSize(columns: 120, rows: 40))
        #expect(core.record.withLock { $0.input } == Array("ğüşıöç\u{3}".utf8))
        #expect(
            core.record.withLock { $0.sizes } == [MawProtocol.TerminalSize(rows: 40, columns: 120)])
    }

    @Test(arguments: [
        (ForegroundAnswer.none, ForegroundReport.none),
        (.program(processGroup: 812, name: "sleep"), .program(name: "sleep")),
        (.program(processGroup: 812, name: nil), .program(name: nil)),
        (.noAnswer, .noAnswer),
    ])
    func theForegroundAnswerBecomesAReport(answer: ForegroundAnswer, report: ForegroundReport)
        async throws
    {
        let recorder = Recorder()
        let (session, _) = try start(recorder, foreground: answer)
        #expect(await session.foregroundProgram(within: .milliseconds(500)) == report)
    }

    /// Ends a session of the default distribution, with the local shell as its fallback,
    /// with `error` before it opens.
    func failBeforeOpening(with error: MawError) async throws -> (LinuxSession, Recorder) {
        let recorder = Recorder()
        let (session, core) = try start(recorder, name: nil, opens: nil) { error in
            LinuxSession.fallbackNotice(for: error).map {
                LinuxSession.Fallback(replacement: LocalShellSession(shell: "/bin/sh"), notice: $0)
            }
        }
        core.end(.failed(error))
        #expect(await waitUntil(seconds: 5) { recorder.failure != nil || recorder.fallback != nil })
        #expect(!session.isRunning)
        return (session, recorder)
    }

    @Test func withNothingInstalledTheTabOpensTheLocalShellAndSaysSo() async throws {
        let (_, recorder) = try await failBeforeOpening(with: .noDistributionInstalled)
        #expect(recorder.failure == nil)
        #expect(recorder.fallback?.replacement is LocalShellSession)
        #expect(
            recorder.fallback?.notice
                == "No Linux distribution is installed, so this tab opened the local shell.\n")
    }

    @Test func withoutTheDaemonTheTabOpensTheLocalShellWithMawsMessage() async throws {
        let (_, recorder) = try await failBeforeOpening(
            with: .daemonNotInstalled(label: "dev.maw.mawd"))
        #expect(recorder.failure == nil)
        #expect(recorder.fallback?.replacement is LocalShellSession)
        #expect(
            recorder.fallback?.notice
                == "maw: The maw daemon is not installed: launchd has no LaunchAgent named "
                + "dev.maw.mawd.\nRegister the daemon with mawd install.\n")
    }

    /// A user who expects Linux must never get a shell on the Mac by mistake (Q3).
    @Test(arguments: [
        MawError.daemonUnreachable(reason: "the connection was invalidated"),
        .daemonConnectionLost(during: "openSession"),
        .daemonProtocolError(reason: "a field is missing"),
        .daemonVersionMismatch(client: 3, daemon: 2),
        .clientSignatureRejected(identifier: "dev.maw.app"),
        .launchctlTimedOut(command: "launchctl print", seconds: 10),
    ])
    func everyOtherFailureShowsTheErrorAndNeverTheLocalShell(error: MawError) async throws {
        let (session, recorder) = try await failBeforeOpening(with: error)
        #expect(recorder.fallback == nil)
        #expect(session.displayName == "linux")
        #expect(
            recorder.failure
                == .failed(
                    message: error.description, suggestion: LinuxSession.suggestion(for: error)))
    }

    /// The suggestions that name a step of `maw` that does not apply in a pane, which the app
    /// words for itself (the plan's "Suggestions that do not hold in the app").
    @Test(arguments: [
        MawError.clientSignatureRejected(identifier: "dev.maw.app"),
        .daemonVersionMismatch(client: 3, daemon: 2),
        .virtualizationEntitlementMissing,
        .machineStopped(machine: "Ubuntu-24.04", reason: "maw --terminate was run"),
        .launchctlTimedOut(command: "launchctl print", seconds: 10),
        .diskImageInUse(path: "/disk.img"),
        .sessionDialBackFailed(reason: "refused"),
        .sessionDialBackMissing(milliseconds: 2000),
        .sessionDialBackBusy(limit: 8),
        .userNotFound("ayse", distribution: "Ubuntu-24.04"),
        .guestCommandNotFound(command: "the login shell", reason: "no such file"),
        .diskImageNotFound(path: "/disk.img"),
    ])
    func suggestionsNameOnlyStepsThatWorkFromTheApp(error: MawError) throws {
        let suggestion = try #require(LinuxSession.suggestion(for: error))
        #expect(suggestion != error.recoverySuggestion)
        for step in ["the command again", "run it again", "--create-disk", "Check the name"] {
            #expect(!suggestion.contains(step), "\(suggestion)")
        }
    }

    @Test func otherSuggestionsAreMaws() {
        for error in [
            MawError.daemonNotInstalled(label: "dev.maw.mawd"), .noDistributionInstalled,
            .sessionConnectionEnded(distribution: "Ubuntu-24.04"),
            .daemonUnreachable(reason: "gone"), .launchAgentFailed(reason: "failed"),
        ] {
            #expect(LinuxSession.suggestion(for: error) == error.recoverySuggestion)
        }
    }

    @Test func titlesAndOSC7AreTheOnlySources() throws {
        let recorder = Recorder()
        let (session, _) = try start(recorder)
        session.terminalReportedTitle("user@ubuntu: ~")
        #expect(recorder.titles == ["user@ubuntu: ~"])
        session.refresh(isVisible: true)
        #expect(session.workingDirectory == nil)
        // The guest's host name is not this Mac's; the path is the guest's.
        session.terminalReportedWorkingDirectory("file://ubuntu/home/user/project")
        #expect(session.workingDirectory == "/home/user/project")
        #expect(recorder.directories == ["/home/user/project"])
    }

    @Test func theGuestLocaleFollowsTheLocalShellsRules() {
        let tr = Locale(identifier: "tr_TR")
        #expect(LinuxSession.guestLocale(environment: [:], locale: tr) == "tr_TR.UTF-8")
        #expect(
            LinuxSession.guestLocale(environment: ["LANG": "de_DE.UTF-8"], locale: tr)
                == "de_DE.UTF-8")
        #expect(
            LinuxSession.guestLocale(
                environment: ["LC_ALL": "xx_YY.UTF-8", "LANG": "de_DE.UTF-8"], locale: tr)
                == "de_DE.UTF-8")
        #expect(
            LinuxSession.guestLocale(environment: ["LANG": "xx_YY.UTF-8"], locale: tr)
                == "tr_TR.UTF-8")
    }

    @Test func aSignalIsRenumberedFromLinux() {
        // SIGUSR1 is 10 on Linux and 30 on macOS; SIGKILL is 9 on both.
        #expect(LinuxSession.terminationStatus(.signaled(signal: 10)) == .signaled(SIGUSR1))
        #expect(LinuxSession.terminationStatus(.signaled(signal: 9)) == .signaled(SIGKILL))
        #expect(LinuxSession.terminationStatus(.signaled(signal: 64)) == .unknown)
        #expect(LinuxSession.terminationStatus(.exited(code: 2)) == .exited(2))
    }
}

/// The cores of the session layer's Linux sessions on a fake daemon: the default distribution
/// opens `defaultName`, a named one the installed spelling of its name, and every opening fails
/// with `failure` if it is set. A core that opens writes `output` at once.
@MainActor
final class FakeCores {
    var installed: [String] = []
    var defaultName: String?
    var failure: MawError?
    var output = Array("prompt$ ".utf8)
    /// The distributions asked for, `nil` for the default one.
    private(set) var opened: [String?] = []

    var cores: Profile.LinuxCores {
        { [self] distribution in
            opened.append(distribution?.rawValue)
            let result: Result<String, MawError>
            if let failure {
                result = .failure(failure)
            } else if let distribution {
                let stored = installed.first {
                    $0.lowercased() == distribution.rawValue.lowercased()
                }
                result =
                    stored.map { .success($0) } ?? .failure(.distributionNotInstalled(distribution))
            } else {
                result = defaultName.map { .success($0) } ?? .failure(.noDistributionInstalled)
            }
            let output = self.output
            return { terminal, handler in
                let core = LinuxSessionTests.FakeCore(
                    terminal: terminal, output: handler, name: try? result.get(), foreground: .none)
                switch result {
                case .success: core.emit([output])
                case .failure(let error): core.end(.failed(error))
                }
                return core
            }
        }
    }
}

extension LinuxSessionTests {
    // MARK: Profiles through the session layer

    /// Starts a session of `profile` from the session layer on `cores`.
    func open(_ profile: Profile, on cores: FakeCores) throws -> (any TerminalSession, Recorder) {
        let recorder = Recorder()
        let session = profile.makeSession(localShell: .localShell("/bin/sh"), cores: cores.cores)
        session.delegate = recorder
        try session.start(size: .default)
        return (session, recorder)
    }

    /// Waits for `recorder`'s fallback and starts it, as the pane does.
    func startFallback(of recorder: Recorder) async throws -> (any TerminalSession, Recorder) {
        #expect(await waitUntil(seconds: 5) { recorder.fallback != nil })
        let replacement = try #require(recorder.fallback?.replacement)
        let next = Recorder()
        replacement.delegate = next
        try replacement.start(size: .default)
        return (replacement, next)
    }

    @Test(arguments: ["Debian-13", "debian-13"])
    func aNamedDistributionOpensByItsStoredName(name: String) async throws {
        let cores = FakeCores()
        cores.installed = ["Debian-13", "Ubuntu-24.04"]
        cores.defaultName = "Ubuntu-24.04"
        let (session, recorder) = try open(.distribution(name), on: cores)
        #expect(session.displayName == name)
        #expect(await waitUntil(seconds: 5) { recorder.text == "prompt$ " })
        #expect(session.displayName == "Debian-13")
        #expect(session.splitProfile == .distribution("Debian-13"))
        #expect(recorder.notices.isEmpty && recorder.fallback == nil)
        #expect(cores.opened == [name])
        session.terminate()
    }

    /// Q2: the default distribution opens instead, and says so before its output.
    @Test func aDistributionThatIsNotInstalledOpensTheDefaultAndSaysSo() async throws {
        let cores = FakeCores()
        cores.installed = ["Ubuntu-24.04"]
        cores.defaultName = "Ubuntu-24.04"
        let (session, recorder) = try open(.distribution("Debian-13"), on: cores)
        let (replacement, next) = try await startFallback(of: recorder)
        #expect(recorder.fallback?.notice == nil && recorder.failure == nil)
        #expect(!session.isRunning)
        #expect(replacement is LinuxSession)
        #expect(await waitUntil(seconds: 5) { next.text == "prompt$ " })
        #expect(
            next.notices == [
                "Debian-13 is not installed. This tab opened Ubuntu-24.04, the default "
                    + "distribution.\n"
            ])
        #expect(next.events == ["notice", "output"])
        #expect(replacement.displayName == "Ubuntu-24.04")
        #expect(replacement.splitProfile == .distribution("Ubuntu-24.04"))
        #expect(cores.opened == ["Debian-13", nil])
        replacement.terminate()
    }

    /// Then as for the default distribution: with nothing installed, the local shell.
    @Test func withNothingInstalledANamedTabEndsInTheLocalShell() async throws {
        let cores = FakeCores()
        // The sessions' tasks hold them weakly, as a pane does not.
        let (session, recorder) = try open(.distribution("Debian-13"), on: cores)
        let (replacement, next) = try await startFallback(of: recorder)
        #expect(await waitUntil(seconds: 5) { next.fallback != nil })
        withExtendedLifetime((session, replacement)) {}
        #expect(next.fallback?.replacement is LocalShellSession)
        #expect(
            next.fallback?.notice
                == "No Linux distribution is installed, so this tab opened the local shell.\n")
        #expect(next.notices.isEmpty)
        #expect(cores.opened == ["Debian-13", nil])
    }

    @Test func withoutTheDaemonANamedTabOpensTheLocalShellWithMawsMessage() async throws {
        let cores = FakeCores()
        cores.failure = .daemonNotInstalled(label: "dev.maw.mawd")
        let (session, recorder) = try open(.distribution("Debian-13"), on: cores)
        #expect(await waitUntil(seconds: 5) { recorder.fallback != nil })
        withExtendedLifetime(session) {}
        #expect(recorder.fallback?.replacement is LocalShellSession)
        #expect(
            recorder.fallback?.notice?.hasPrefix("maw: The maw daemon is not installed") == true)
        #expect(cores.opened == ["Debian-13"])
    }

    /// Every other failure shows the error in a pane named for the distribution, never the
    /// local shell and never the default distribution.
    @Test(arguments: [
        MawError.daemonUnreachable(reason: "the connection was invalidated"),
        .daemonConnectionLost(during: "openSession"),
        .clientSignatureRejected(identifier: "dev.maw.app"),
        .vmStartFailed(reason: "the configuration is invalid"),
    ])
    func everyOtherFailureOfANamedTabShowsTheError(error: MawError) async throws {
        let cores = FakeCores()
        cores.failure = error
        let (session, recorder) = try open(.distribution("Debian-13"), on: cores)
        #expect(await waitUntil(seconds: 5) { recorder.failure != nil })
        #expect(recorder.fallback == nil)
        #expect(session.displayName == "Debian-13")
        #expect(session.splitProfile == nil)
        #expect(
            recorder.failure
                == .failed(
                    message: error.description, suggestion: LinuxSession.suggestion(for: error)))
        #expect(cores.opened == ["Debian-13"])
    }

    /// A name that is not valid cannot be installed, so it opens the default distribution with
    /// the same notice rather than falling back without a word.
    @Test func anInvalidNameOpensTheDefaultAndSaysSo() async throws {
        let cores = FakeCores()
        cores.defaultName = "Ubuntu-24.04"
        let (session, recorder) = try open(.distribution("Debian 13"), on: cores)
        #expect(await waitUntil(seconds: 5) { recorder.text == "prompt$ " })
        #expect(
            recorder.notices == [
                "Debian 13 is not installed. This tab opened Ubuntu-24.04, the default "
                    + "distribution.\n"
            ])
        #expect(cores.opened == [nil])
        session.terminate()
    }
}

extension LinuxSessionTests.Recorder {
    var text: String { String(decoding: output, as: UTF8.self) }
}
