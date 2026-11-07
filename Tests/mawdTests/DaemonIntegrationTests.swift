import CryptoKit
import Darwin
import Foundation
import MawTestSupport
import Testing

/// `maw` against a real daemon, which boots real virtual machines, in the test distribution
/// that scripts/integration-test.sh installs (see `MawIntegration`). The owner's installed
/// daemon, `dev.maw.mawd`, is never touched.
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled,
        "Integration tests boot a real virtual machine; run scripts/integration-test.sh."),
    .serialized,
    // Bounds each test as a whole; every wait in it also has a time limit of its own.
    .timeLimit(.minutes(10))
)
struct DaemonIntegrationTests {
    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    var distribution: String { maw.distribution }

    // MARK: Commands

    @Test func runsUnameAndExitsZero() async throws {
        let result = try await maw.session(["--", "uname", "-a"])
        #expect(result.status == 0, "\(result.standardError)")
        #expect(
            result.output.hasPrefix("Linux ") && result.output.contains(" 6.18"),
            "\(result.output)")
    }

    @Test func exitsWithTheCommandsStatus() async throws {
        let result = try await maw.session(["-e", "sh", "-c", "exit 3"])
        #expect(result.status == 3, "\(result.standardError)")
    }

    @Test func runsABareCommandThroughTheShell() async throws {
        let result = try await maw.session(["echo", "a", "$((1 + 2))"])
        #expect(result.output == "a 3\n", "\(result.standardError)")
    }

    @Test func passesStandardInputToTheCommand() async throws {
        let result = try await maw.session(["-e", "cat"], standardInput: Data("hello\n".utf8))
        #expect(result.status == 0)
        #expect(result.output == "hello\n")
    }

    /// 256 MiB into a reader slower than the connection, so that vsock's flow control throttles
    /// the client and then grants it credit in large steps. `GuestProcessTests` covers the
    /// stall this guards against deterministically; this test covers the real transport.
    @Test func streamsLargeInputIntoASlowReader() async throws {
        // sha256sum reads slower than vsock delivers.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var bytes = Data(count: 256 << 20)
        bytes.withUnsafeMutableBytes { buffer in
            let words = buffer.bindMemory(to: UInt64.self)
            for index in words.indices {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                words[index] = state
            }
        }
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        // From a file, which maw reads itself: writing 256 MiB into a pipe here would block
        // without a time limit if the stream stalled.
        let input = FileManager.default.temporaryDirectory.appending(
            path: "maw-stream-\(UUID().uuidString)")
        try bytes.write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let result = try await DebugBootProcess(
            executable: maw.maw, arguments: ["-d", distribution, "-e", "sha256sum"],
            standardInputFile: input, separateStandardError: true,
            environment: maw.mawEnvironment
        ).waitForExit(timeout: .seconds(120))
        #expect(result.status == 0, "\(result.standardError)")
        #expect(result.output.hasPrefix(expected), "\(result.output)")
    }

    @Test func keepsStandardOutputAndErrorSeparate() async throws {
        let result = try await maw.session(["-e", "sh", "-c", "echo out; echo err >&2"])
        #expect(result.output == "out\n")
        #expect(result.standardError == "err\n")
    }

    @Test func reportsAMissingCommandAsAShellWould() async throws {
        let result = try await maw.session(["-e", "no-such-command"])
        #expect(result.status == 127)
        #expect(result.standardError.contains("no-such-command: command not found in the guest"))
    }

    @Test func passesSIGINTToTheCommandAndKeepsTheMachine() async throws {
        let session = try maw.start(["-d", distribution, "-e", "sleep", "100"])
        try await maw.waitForSessions(1)
        session.signal(SIGINT)
        let result = await session.waitForExit(timeout: .seconds(30))
        #expect(result.status == 130, "\(result.output)")
        #expect(try await maw.machineRow().contains("Running"))
    }

    /// Ctrl-C reaches a command that reads none of its endless input, `yes | maw -e sleep 1000`:
    /// the signal overtakes the queued input, and the input window keeps the agent reading the
    /// connection. Before, the signal stayed behind the input for good.
    @Test func passesSIGINTAheadOfUnreadInput() async throws {
        var delays: [Double] = []
        for _ in 0..<5 {
            let yes = Process()
            yes.executableURL = URL(filePath: "/usr/bin/yes")
            let pipe = Pipe()
            yes.standardOutput = pipe
            try yes.run()
            let delay: Result<Double?, any Error>
            do {
                delay = .success(try await sigintDelay(standardInput: pipe))
            } catch {
                delay = .failure(error)
            }
            yes.terminate()
            #expect(await yes.waitForExit(within: .seconds(10)), "yes did not exit.")
            if let delay = try delay.get() {
                delays.append(delay)
            }
        }
        let median = MawIntegration.report(
            "SIGINT to the exit of yes | maw -e sleep 1000", delays)
        #expect(delays.count == 5)
        #expect(median < 100)
    }

    /// `maw -e sleep 1000` with `standardInput` as its input: the time from SIGINT to maw's
    /// exit, in milliseconds.
    func sigintDelay(standardInput: Pipe) async throws -> Double? {
        let session = try DebugBootProcess(
            executable: maw.maw, arguments: ["-d", distribution, "-e", "sleep", "1000"],
            standardInputPipe: standardInput, separateStandardError: true,
            environment: maw.mawEnvironment)
        try await maw.waitForSessions(1)
        // Long enough for every buffer on the way to fill.
        try await Task.sleep(for: .seconds(1))

        let sent = ContinuousClock.now
        session.signal(SIGINT)
        let result = await session.waitForExit(timeout: .seconds(10))
        #expect(result.status == 130, "\(result.standardError)")
        try await maw.waitForSessions(0)
        return session.exitedAt.map { ($0 - sent).fractionalMilliseconds }
    }

    /// Ctrl-C reaches a command whose output nobody reads. The command's trap creates a file in
    /// the guest, and a second session, which waits for that file, ends at once; the time to
    /// its exit bounds the delay from above.
    ///
    /// maw's I/O thread does not wait for the write to its standard output, and sends the
    /// signal at once (ExecSessionTests covers this over a socket pair). Over vsock this needs
    /// the session to run on a connection that the agent dialed: on one that the host opened,
    /// Virtualization.framework's vsock device blocked once the host side was full, and carried
    /// neither the signal nor the second session.
    @Test func passesSIGINTWhileTheOutputIsNotRead() async throws {
        var delays: [Double] = []
        var markers: [String] = []
        for run in 0..<5 {
            let marker = "/tmp/maw-test-sigint-\(run)-\(UInt32.random(in: 0...UInt32.max))"
            markers.append(marker)
            let watcher = try maw.start([
                "-d", distribution, "-e", "sh", "-c",
                "while [ ! -e \"$0\" ]; do sleep 0.002; done", marker,
            ])
            let session = try DebugBootProcess(
                executable: maw.maw,
                arguments: [
                    "-d", distribution, "-e", "sh", "-c", "trap 'touch \"$0\"; exit 130' INT; yes",
                    marker,
                ],
                standardOutputPipe: Pipe(), separateStandardError: true,
                environment: maw.mawEnvironment)
            try await maw.waitForSessions(2)
            // Long enough for every buffer on the way to fill.
            try await Task.sleep(for: .seconds(1))

            let sent = ContinuousClock.now
            session.signal(SIGINT)
            let watched = await watcher.waitForExit(timeout: .seconds(10))
            #expect(watched.status == 0, "The signal did not arrive: \(watched.standardError)")
            if watched.status == 0, let exitedAt = watcher.exitedAt {
                delays.append((exitedAt - sent).fractionalMilliseconds)
            }
            // The command has ended, but maw still waits to write its output.
            #expect(session.isRunning)
            session.signal(SIGKILL)
            _ = await session.waitForExit(timeout: .seconds(10))
            try await maw.waitForSessions(0)
        }
        _ = try await maw.session(["-e", "rm", "-f"] + markers)
        let median = MawIntegration.report(
            "SIGINT to the guest with an unread standard output, through a second session",
            delays)
        #expect(delays.count == 5)
        #expect(median < 100)
    }

    @Test func reportsADistributionThatIsNotInstalled() async throws {
        let missing = "\(maw.prefix)-missing"
        let result = try await maw.session(["-e", "true"], in: missing)
        #expect(result.status == 1)
        #expect(
            result.standardError.hasPrefix("maw: No distribution named '\(missing)' is installed."),
            "\(result.standardError)")
    }

    // MARK: Machines and sessions

    @Test func twoSessionsShareOneMachine() async throws {
        let first = try maw.start(["-d", distribution, "-e", "sleep", "2"])
        let second = try maw.start(["-d", distribution, "-e", "sleep", "2"])
        try await maw.waitForSessions(2)
        let status = try await maw.run(["--status"])
        let rows = status.lines.filter { $0.hasPrefix("  \(distribution) ") }
        #expect(rows.count == 1, "\(status.output)")
        #expect(rows.first?.hasSuffix(" 2") == true, "\(status.output)")

        #expect(await first.waitForExit(timeout: .seconds(30)).status == 0)
        #expect(await second.waitForExit(timeout: .seconds(30)).status == 0)
    }

    @Test func stopsTheMachineAfterTheIdleTimeout() async throws {
        #expect(try await maw.session(["-e", "true"]).status == 0)
        let stopped = await maw.eventually(within: .seconds(maw.machineIdleTimeout + 15)) {
            (try? await maw.run(["--status"]))?.output.contains("No virtual machine is running.")
                == true
        }
        #expect(stopped, "The machine did not stop within the idle timeout.")
        try expectCleanShutdownInConsoleLog()
    }

    @Test func shutdownEndsAnActiveSession() async throws {
        let session = try maw.start(["-d", distribution, "-e", "sleep", "100"])
        try await maw.waitForSessions(1)
        let shutdown = try await maw.run(["--shutdown"])
        #expect(shutdown.status == 0, "\(shutdown.standardError)")

        let result = await session.waitForExit(timeout: .seconds(30))
        #expect(result.status == 1)
        #expect(
            result.standardError.contains(
                "maw: The session ended because the virtual machine \(distribution) stopped: "
                    + "maw --shutdown was run."),
            "\(result.standardError)")
        try expectCleanShutdownInConsoleLog()
    }

    @Test func runsALoginShellOnATerminal() async throws {
        let session = try maw.interactive(["-d", distribution])
        let host = maw.hostname(of: distribution)
        try #require(
            await session.waitForPrompt(user: maw.user, host: host), "\(session.plainOutput)")

        // Each step waits for one prompt more than the output held before it, because readline
        // draws the prompt again after the resize. Typing on before the shell has answered
        // Ctrl-C loses input to its interrupt handling.
        var prompts = session.promptCount(user: maw.user, host: host)
        session.type("stty size\r")
        #expect(await session.waitForOutput(containing: "24 80"), "\(session.plainOutput)")
        #expect(await session.waitForPrompt(user: maw.user, host: host, count: prompts + 1))

        session.resize(rows: 30, columns: 100)
        try await Task.sleep(for: .milliseconds(300))
        prompts = session.promptCount(user: maw.user, host: host)
        session.type("stty size\r")
        #expect(await session.waitForOutput(containing: "30 100"), "\(session.plainOutput)")
        #expect(await session.waitForPrompt(user: maw.user, host: host, count: prompts + 1))

        // Ctrl-C reaches the guest's shell, which echoes ^C and prints a new prompt.
        session.type([0x03])
        let answered = await maw.eventually(within: .seconds(30)) {
            session.plainOutput.components(separatedBy: "^C").dropFirst().last?
                .contains("\(maw.user)@\(host):") == true
        }
        #expect(answered, "\(session.plainOutput)")
        #expect(session.isRunning)

        // `exit` alone would exit with the status of the interrupted prompt, 130.
        session.type("exit 0\r")
        let status = await session.waitForExit(timeout: .seconds(30))
        #expect(status == 0, "\(session.plainOutput)")
        #expect(session.terminalIsRestored, "The terminal attributes differ after the session.")
    }

    /// The session ends with an error, the machine's process exits, and launchd starts a new
    /// daemon on the next request.
    @Test func survivesTheDaemonBeingKilled() async throws {
        // Start from a stopped machine, so that its process is the only new one.
        #expect(try await maw.run(["--shutdown"]).status == 0)
        let before = IntegrationTests.virtualMachineProcesses()
        let session = try maw.start(["-d", distribution, "-e", "sleep", "100"])
        try await maw.waitForSessions(1)
        let machines = IntegrationTests.virtualMachineProcesses().subtracting(before)
        #expect(!machines.isEmpty, "No virtual machine process appeared.")
        let daemon = try await daemonProcessID()
        let killed = ContinuousClock.now
        kill(daemon, SIGKILL)
        let remaining = await IntegrationTests.virtualMachineProcesses(
            machines, exitWithin: .seconds(5))
        #expect(remaining.isEmpty, "Still running 5 s after mawd was killed: \(remaining)")
        MawIntegration.report(
            "machine process gone after SIGKILL to the daemon, polled every 100 ms",
            [(ContinuousClock.now - killed).fractionalMilliseconds])

        let result = await session.waitForExit(timeout: .seconds(30))
        #expect(result.status == 1)
        #expect(
            result.standardError.contains("maw: The maw daemon exited or closed the connection"),
            "\(result.standardError)")

        // launchd starts a new daemon, which boots a new machine.
        let next = try await maw.session(["-e", "uname", "-r"])
        #expect(next.status == 0, "\(next.standardError)")
        #expect(next.output.hasPrefix("6.18"))
        #expect(try await daemonProcessID() != daemon)
    }

    // MARK: Helpers

    /// The daemon's process ID, from the first line of `--status`.
    func daemonProcessID() async throws -> pid_t {
        let line = try #require(try await maw.run(["--status"]).lines.first)
        let match = try #require(line.firstMatch(of: /process (\d+)/), "\(line)")
        return try #require(pid_t(match.1))
    }

    func expectCleanShutdownInConsoleLog(sourceLocation: SourceLocation = #_sourceLocation)
        throws
    {
        let log = try String(
            contentsOf: maw.logDirectory.appending(path: "\(distribution).log"), encoding: .utf8)
        let lastShutdown = try #require(
            DebugBootProcess.lines(of: log).last {
                $0.hasPrefix("[mawd] ") && $0.contains(" shutdown: ")
            }, sourceLocation: sourceLocation)
        #expect(
            lastShutdown.contains("shutdown: clean after "), "\(lastShutdown)",
            sourceLocation: sourceLocation)
    }
}
