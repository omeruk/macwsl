import Darwin
import Foundation
import MawTestSupport
import Testing

/// One session that stops reading, or whose `maw` is stopped, must not stop the machine's other
/// sessions. Sessions used to run on connections that the host opened, and once one of them
/// held 8192 unread bytes on the host side, Virtualization.framework's vsock device stopped
/// carrying the whole machine's traffic. Every session now runs on a connection that the agent
/// dials (docs/protocol.md).
///
/// Each freeze test runs `seq 1 inf` in one session and freezes it; checks that new sessions on
/// the same machine still start and answer within normal latency; resumes the frozen session
/// and checks that its output continues without a line lost; and ends it. A machine whose
/// vsock device has stopped fails the checks within their time limits.
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled,
        "Integration tests boot a real virtual machine; run scripts/integration-test.sh."),
    .serialized,
    .timeLimit(.minutes(10))
)
struct FreezeIntegrationTests {
    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    var distribution: String { maw.distribution }

    /// Lines of `seq 1 inf` that a resumed session must deliver: about 7 MB, more than every
    /// buffer on the way holds.
    static let linesAfterResuming = 1_000_000

    // MARK: Freezes

    @Test func aSessionWhoseOutputIsNotReadLeavesOthersRunning() async throws {
        let output = Pipe()
        let session = try DebugBootProcess(
            executable: maw.maw, arguments: ["-d", distribution, "-e", "seq", "1", "inf"],
            standardOutputPipe: output, separateStandardError: true,
            environment: maw.mawEnvironment)
        defer { Self.kill(session) }
        let reader = SequenceReader(descriptor: output.fileHandleForReading.fileDescriptor)
        // The pipe closes its descriptor when it is released, which must not happen while
        // the reader still uses it.
        defer { withExtendedLifetime(output) { reader.stop() } }
        try await maw.waitForSessions(1)
        // Long enough for every buffer on the way to fill.
        try await Task.sleep(for: .seconds(2))

        try await expectOtherSessionsRespond(while: "a session's output is not read")
        #expect(session.isRunning)

        reader.resume()
        try await expectOutputContinues(reader)
        session.signal(SIGINT)
        let result = await session.waitForExit(timeout: .seconds(30))
        #expect(result.status == 130, "\(result.standardError)")
        try await expectSessionEnded()
    }

    /// As when a user presses Ctrl-S, or the terminal window stops responding.
    @Test func aTerminalSessionWhoseOutputIsNotReadLeavesOthersRunning() async throws {
        let session = try maw.interactive(
            ["-d", distribution, "-e", "seq", "1", "inf"], collectsOutput: false)
        let reader = SequenceReader(descriptor: session.primaryDescriptor)
        defer { withExtendedLifetime(session) { reader.stop() } }
        try await maw.waitForSessions(1)
        try await Task.sleep(for: .seconds(2))

        try await expectOtherSessionsRespond(while: "a terminal session's output is not read")
        #expect(session.isRunning)

        reader.resume()
        try await expectOutputContinues(reader)
        session.type([0x03])
        let status = await session.waitForExit(timeout: .seconds(30))
        #expect(status == 130)
        try await expectSessionEnded()
    }

    @Test func aStoppedSessionLeavesOthersRunning() async throws {
        try await freezeByStopping(with: SIGSTOP, named: "SIGSTOP")
    }

    /// Ctrl-Z at a shell sends SIGTSTP. In pipe mode maw keeps its default action, so it stops,
    /// and the session's output stays unread until `fg`.
    @Test func ctrlZOnAPipeSessionLeavesOthersRunning() async throws {
        try await freezeByStopping(with: SIGTSTP, named: "SIGTSTP")
    }

    func freezeByStopping(with signal: Int32, named name: String) async throws {
        let output = Pipe()
        let session = try DebugBootProcess(
            executable: maw.maw, arguments: ["-d", distribution, "-e", "seq", "1", "inf"],
            standardOutputPipe: output, separateStandardError: true,
            environment: maw.mawEnvironment)
        defer { Self.kill(session) }
        let reader = SequenceReader(
            descriptor: output.fileHandleForReading.fileDescriptor, reading: true)
        defer { withExtendedLifetime(output) { reader.stop() } }
        #expect(await reader.waitForLines(100_000, timeout: .seconds(30)), "\(reader.progress)")

        session.signal(signal)
        let stopped = await maw.eventually(within: .seconds(5)) {
            Self.isStopped(session.processIdentifier)
        }
        try #require(stopped, "maw did not stop on \(name).")
        #expect(await reader.waitUntilStalled(timeout: .seconds(10)), "\(reader.progress)")

        try await expectOtherSessionsRespond(while: "a session's maw is stopped by \(name)")

        session.signal(SIGCONT)
        try await expectOutputContinues(reader)
        session.signal(SIGINT)
        let result = await session.waitForExit(timeout: .seconds(30))
        #expect(result.status == 130, "\(result.standardError)")
        try await expectSessionEnded()
    }

    // MARK: Concurrency

    /// Every dial in a burst must be admitted. The gate admits one connection without a nonce
    /// for each waiting session and 4 more, and the agent's listening socket has a backlog of
    /// 64.
    @Test func opensThirtyTwoSessionsAtOnce() async throws {
        try await expectBurst(of: 32)
    }

    /// 64 sessions are also the agent's own limit of connections served at once, beyond which
    /// it replies `busy`; that limit is separate from the gate's, and is counted separately.
    @Test func opensSixtyFourSessionsAtOnce() async throws {
        try await expectBurst(of: 64)
    }

    func expectBurst(of count: Int) async throws {
        // Boot the machine first, so that the burst measures sessions rather than the boot.
        #expect(try await maw.session(["-e", "true"]).status == 0)
        let logStart = consoleLogSize()

        let started = ContinuousClock.now
        let sessions = try (0..<count).map { _ in
            try maw.start(["-d", distribution, "-e", "true"])
        }
        var failures = BurstFailures()
        for (index, session) in sessions.enumerated() {
            let result = await session.waitForExit(timeout: .seconds(60))
            if result.status != 0 {
                failures.add("session \(index): status \(result.status): \(result.standardError)")
            }
        }
        let lastExit = sessions.compactMap(\.exitedAt).max() ?? .now
        MawIntegration.report(
            "\(count) parallel maw -e true, from the first start to the last exit",
            [(lastExit - started).fractionalMilliseconds])
        failures.read(consoleLog(from: logStart))
        print("burst: \(count) parallel maw -e true: \(failures)")
        #expect(failures.isEmpty, "\(failures.details)")
    }

    @Test func opensThirtyTwoTerminalSessionsAtOnce() async throws {
        #expect(try await maw.session(["-e", "true"]).status == 0)
        let host = maw.hostname(of: distribution)
        let logStart = consoleLogSize()

        let started = ContinuousClock.now
        let shells = try (0..<32).map { _ in try maw.interactive(["-d", distribution]) }
        var failures = BurstFailures()
        for (index, shell) in shells.enumerated() {
            // A shell whose session failed has exited; the wait ends for it at once.
            _ = await maw.eventually(within: .seconds(60)) {
                shell.promptCount(user: maw.user, host: host) > 0 || !shell.isRunning
            }
            if shell.promptCount(user: maw.user, host: host) == 0 {
                failures.add(
                    "shell \(index): no prompt; running: \(shell.isRunning); output: "
                        + String(shell.plainOutput.suffix(300)))
            }
        }
        MawIntegration.report(
            "32 login shells started at once, to the last prompt",
            [(ContinuousClock.now - started).fractionalMilliseconds])
        failures.read(consoleLog(from: logStart))
        print("burst: 32 login shells: \(failures)")
        #expect(failures.isEmpty, "\(failures.details)")
        // All of them at the same time.
        let row = try await maw.machineRow()
        #expect(row.hasSuffix(" 32"), "\(row)")

        for shell in shells {
            shell.type("exit 0\r")
        }
        for (index, shell) in shells.enumerated() {
            let status = await shell.waitForExit(timeout: .seconds(30))
            #expect(status == 0, "shell \(index): \(shell.plainOutput.suffix(300))")
        }
        try await maw.waitForSessions(0)
    }

    /// The sessions of a burst that failed, by cause, and what the machine's console log
    /// recorded meanwhile: the gate's refusals by reason, and the agent's `busy` refusals.
    struct BurstFailures: CustomStringConvertible {
        /// The agent's dial was reset: the gate refused it before reading.
        var refusedByTheGate = 0
        /// The agent dialed, but no connection with the nonce reached the session.
        var dialBackMissing = 0
        /// The agent was serving its limit of connections.
        var agentBusy = 0
        var other = 0
        var details: [String] = []
        /// Gate refusals in the console log, by reason. The gate logs at most 5 per 10 s and
        /// later reports how many it left out.
        var loggedGateRefusals: [String: Int] = [:]
        var unloggedGateRefusals = 0
        /// The agent's "refusing a connection" warnings in the console log.
        var loggedAgentRefusals = 0

        var isEmpty: Bool { details.isEmpty && loggedGateRefusals.isEmpty }

        mutating func add(_ failure: String) {
            details.append(failure)
            if failure.contains("the agent is serving") {
                agentBusy += 1
            } else if failure.contains("could not connect to maw for the session"),
                failure.contains("Connection reset by peer")
            {
                refusedByTheGate += 1
            } else if failure.contains("no connection with the session's nonce arrived") {
                dialBackMissing += 1
            } else {
                other += 1
            }
        }

        mutating func read(_ log: String) {
            for line in DebugBootProcess.lines(of: log) {
                if let match = line.firstMatch(
                    of:
                        /dial-back: (?:(\d+) further refusals were not logged; )?refused a dial-back connection: (.*)$/
                ) {
                    unloggedGateRefusals += match.1.flatMap { Int($0) } ?? 0
                    loggedGateRefusals[String(match.2), default: 0] += 1
                } else if line.contains("refusing a connection:") {
                    loggedAgentRefusals += 1
                }
            }
        }

        var description: String {
            "\(details.count) failed: \(refusedByTheGate) refused by the gate, "
                + "\(dialBackMissing) dial-backs missing, \(agentBusy) agent busy, \(other) other; "
                + "console log: gate refusals \(loggedGateRefusals) and \(unloggedGateRefusals) not "
                + "logged, \(loggedAgentRefusals) agent busy refusals"
        }
    }

    func consoleLogSize() -> Int {
        (try? Data(contentsOf: maw.logDirectory.appending(path: "\(distribution).log")))?.count
            ?? 0
    }

    func consoleLog(from start: Int) -> String {
        let data =
            (try? Data(contentsOf: maw.logDirectory.appending(path: "\(distribution).log")))
            ?? Data()
        return String(decoding: data.dropFirst(start), as: UTF8.self)
    }

    // MARK: Helpers

    /// Five `maw -e true` and one interactive command on the machine, each within the latency
    /// of a machine with no frozen session, with room for a loaded Mac: a warm `maw -e true`
    /// takes about 30 ms, and a warm prompt about 100 ms.
    func expectOtherSessionsRespond(
        while situation: String, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        var times: [Double] = []
        for _ in 0..<5 {
            let run = try maw.timed(["-d", distribution, "-e", "true"], timeout: .seconds(10))
            #expect(
                run.status == 0, "maw -e true exited with \(run.status) while \(situation).",
                sourceLocation: sourceLocation)
            times.append(run.milliseconds)
        }
        let median = MawIntegration.report("maw -e true while \(situation)", times)
        #expect(median < 150, sourceLocation: sourceLocation)
        #expect(times.allSatisfy { $0 < 1000 }, "\(times)", sourceLocation: sourceLocation)

        let host = maw.hostname(of: distribution)
        let started = ContinuousClock.now
        let shell = try maw.interactive(["-d", distribution])
        try #require(
            await shell.waitForPrompt(user: maw.user, host: host, timeout: .seconds(10)),
            "No prompt while \(situation): \(shell.plainOutput)", sourceLocation: sourceLocation)
        let prompt = (ContinuousClock.now - started).fractionalMilliseconds
        let typed = ContinuousClock.now
        shell.type("echo $((6 * 7))-answered\r")
        #expect(
            await shell.waitForOutput(containing: "42-answered", timeout: .seconds(10)),
            "\(shell.plainOutput)", sourceLocation: sourceLocation)
        let answer = (ContinuousClock.now - typed).fractionalMilliseconds
        MawIntegration.report("interactive prompt while \(situation)", [prompt])
        MawIntegration.report("interactive echo while \(situation), polled every 50 ms", [answer])
        #expect(prompt < 1500, sourceLocation: sourceLocation)
        #expect(answer < 500, sourceLocation: sourceLocation)
        shell.type("exit 0\r")
        #expect(
            await shell.waitForExit(timeout: .seconds(10)) == 0, sourceLocation: sourceLocation)
    }

    /// The frozen session's output flows again, every line in order.
    func expectOutputContinues(
        _ reader: SequenceReader, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let target = reader.progress.lines + Self.linesAfterResuming
        #expect(
            await reader.waitForLines(target, timeout: .seconds(30)), "\(reader.progress)",
            sourceLocation: sourceLocation)
        // Taken before the session ends: Ctrl-C adds "^C" to a terminal's output.
        let progress = reader.progress
        #expect(progress.error == nil, "\(progress)", sourceLocation: sourceLocation)
    }

    /// The session has gone from the daemon, and its command from the guest.
    func expectSessionEnded(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await maw.waitForSessions(0, sourceLocation: sourceLocation)
        let gone = await maw.eventually(within: .seconds(10)) {
            (try? await maw.session(["-e", "pgrep", "-x", "seq"]))?.status == 1
        }
        #expect(gone, "seq is still running in the guest.", sourceLocation: sourceLocation)
    }

    /// Whether the process is stopped (`SSTOP`), as `ps` shows with `T`.
    static func isStopped(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else {
            return false
        }
        return Int32(info.kp_proc.p_stat) == SSTOP
    }

    /// Kills a session that a failed expectation left running, so that it does not hold the
    /// machine for the tests after it.
    static func kill(_ session: DebugBootProcess) {
        if session.isRunning {
            session.signal(SIGKILL)
        }
    }
}
