import Darwin
import Foundation
import MawClient
import MawCore
import MawProtocol
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
        /// Called with the bytes received so far, before each slice is added.
        var onSlice: ((Int) -> Void)?

        func session(_ session: any TerminalSession, didReceive bytes: ArraySlice<UInt8>) {
            onSlice?(output.count)
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
    }

    /// Starts a session on a fake core and returns both.
    func start(
        _ recorder: Recorder, name: String? = "Ubuntu-24.04", opens: String? = "Ubuntu-24.04",
        foreground: ForegroundAnswer = .none, size: MawTerminalKit.TerminalSize = .default
    ) throws -> (LinuxSession, FakeCore) {
        var core: FakeCore?
        let session = LinuxSession(name: name) { terminal, output in
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
        #expect(recorder.failure == TerminalSessionError(error))
        #expect(recorder.failure?.recoverySuggestion == error.recoverySuggestion)
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

extension LinuxSessionTests.Recorder {
    var text: String { String(decoding: output, as: UTF8.self) }
}
