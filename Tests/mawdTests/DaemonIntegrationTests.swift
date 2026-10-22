import CryptoKit
import Darwin
import Foundation
import Testing

private let environment = ProcessInfo.processInfo.environment
private let integrationEnabled = environment["MAW_INTEGRATION"] == "1"

/// `maw` against a real daemon, which boots real virtual machines.
///
/// scripts/integration-test.sh registers a daemon of its own under the label in
/// `MAW_DAEMON_LABEL`, with its logs in `MAW_TEST_LOG_DIRECTORY` and a machine idle timeout of
/// `MAW_TEST_MACHINE_IDLE_TIMEOUT` seconds, and removes it afterwards. The owner's installed
/// daemon, `dev.maw.mawd`, is never touched.
@Suite(
    .tags(.integration),
    .enabled(
        if: integrationEnabled,
        "Integration tests boot a real virtual machine; run scripts/integration-test.sh."),
    .serialized
)
struct DaemonIntegrationTests {
    let maw: URL
    let label: String
    let logDirectory: URL
    let machineIdleTimeout: Int

    init() throws {
        let path = try #require(
            environment["MAW_PATH"], "MAW_PATH must point to the signed maw.")
        maw = URL(filePath: path)
        label = try #require(environment["MAW_DAEMON_LABEL"])
        try #require(
            label != "dev.maw.mawd", "The integration tests must not use the installed daemon.")
        logDirectory = URL(
            filePath: try #require(environment["MAW_TEST_LOG_DIRECTORY"]),
            directoryHint: .isDirectory)
        machineIdleTimeout = Int(environment["MAW_TEST_MACHINE_IDLE_TIMEOUT"] ?? "") ?? 3
    }

    // MARK: Commands

    @Test func runsUnameAndExitsZero() async throws {
        let result = try await run(["--", "uname", "-a"])
        #expect(result.status == 0, "\(result.standardError)")
        #expect(
            result.output.hasPrefix("Linux ") && result.output.contains(" 6.18"),
            "\(result.output)")
    }

    @Test func exitsWithTheCommandsStatus() async throws {
        let result = try await run(["-e", "sh", "-c", "exit 3"])
        #expect(result.status == 3, "\(result.standardError)")
    }

    @Test func runsABareCommandThroughTheShell() async throws {
        let result = try await run(["echo", "a", "$((1 + 2))"])
        #expect(result.output == "a 3\n", "\(result.standardError)")
    }

    @Test func passesStandardInputToTheCommand() async throws {
        let result = try await run(["-e", "cat"], standardInput: Data("hello\n".utf8))
        #expect(result.status == 0)
        #expect(result.output == "hello\n")
    }

    /// 256 MiB into a reader slower than the connection, so that vsock's flow control throttles
    /// the client and then grants it credit in large steps. `GuestProcessTests` covers the
    /// stall this guards against deterministically; this test covers the real transport.
    @Test func streamsLargeInputIntoASlowReader() async throws {
        // busybox sha256sum, built without hardware acceleration, reads slower than vsock
        // delivers.
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
            executable: maw, arguments: ["-e", "sha256sum"], standardInputFile: input,
            separateStandardError: true, environment: mawEnvironment
        ).waitForExit(timeout: .seconds(120))
        #expect(result.status == 0, "\(result.standardError)")
        #expect(result.output.hasPrefix(expected), "\(result.output)")
    }

    @Test func keepsStandardOutputAndErrorSeparate() async throws {
        let result = try await run(["-e", "sh", "-c", "echo out; echo err >&2"])
        #expect(result.output == "out\n")
        #expect(result.standardError == "err\n")
    }

    @Test func reportsAMissingCommandAsAShellWould() async throws {
        let result = try await run(["-e", "no-such-command"])
        #expect(result.status == 127)
        #expect(result.standardError.contains("no-such-command: command not found in the guest"))
    }

    @Test func passesSIGINTToTheCommandAndKeepsTheMachine() async throws {
        let session = try start(["-e", "sleep", "100"])
        try await waitForSessions(1)
        session.signal(SIGINT)
        let result = await session.waitForExit(timeout: .seconds(30))
        #expect(result.status == 130, "\(result.output)")

        let status = try await run(["--status"])
        #expect(status.output.contains("initramfs  Running"), "\(status.output)")
    }

    // MARK: Machines and sessions

    @Test func twoSessionsShareOneMachine() async throws {
        let first = try start(["-e", "sleep", "2"])
        let second = try start(["-e", "sleep", "2"])
        try await waitForSessions(2)
        let status = try await run(["--status"])
        let rows = status.lines.filter { $0.hasPrefix("  initramfs ") }
        #expect(rows.count == 1, "\(status.output)")
        #expect(rows.first?.hasSuffix(" 2") == true, "\(status.output)")

        #expect(await first.waitForExit(timeout: .seconds(30)).status == 0)
        #expect(await second.waitForExit(timeout: .seconds(30)).status == 0)
    }

    @Test func stopsTheMachineAfterTheIdleTimeout() async throws {
        #expect(try await run(["-e", "true"]).status == 0)
        let stopped = await eventually(within: .seconds(machineIdleTimeout + 15)) {
            (try? await run(["--status"]))?.output.contains("No virtual machine is running.")
                == true
        }
        #expect(stopped, "The machine did not stop within the idle timeout.")
        try expectCleanShutdownInConsoleLog()
    }

    @Test func shutdownEndsAnActiveSession() async throws {
        let session = try start(["-e", "sleep", "100"])
        try await waitForSessions(1)
        let shutdown = try await run(["--shutdown"])
        #expect(shutdown.status == 0, "\(shutdown.standardError)")

        let result = await session.waitForExit(timeout: .seconds(30))
        #expect(result.status == 1)
        #expect(
            result.standardError.contains(
                "maw: The session ended because the virtual machine initramfs stopped: "
                    + "maw --shutdown was run."),
            "\(result.standardError)")
        try expectCleanShutdownInConsoleLog()
    }

    @Test func runsAShellOnATerminal() async throws {
        let session = try InteractiveSession(
            executable: maw, arguments: [], environment: mawEnvironment, rows: 24, columns: 80)
        try #require(await session.waitForOutput(containing: "/ # "), "\(session.output)")

        session.type("stty size\r")
        #expect(await session.waitForOutput(containing: "24 80"), "\(session.output)")
        #expect(await session.waitForOutput(containing: "/ # ", count: 2))

        session.resize(rows: 30, columns: 100)
        try await Task.sleep(for: .milliseconds(300))
        session.type("stty size\r")
        #expect(await session.waitForOutput(containing: "30 100"), "\(session.output)")
        #expect(await session.waitForOutput(containing: "/ # ", count: 3))

        // Ctrl-C reaches the guest's shell, which prints a new prompt.
        session.type([0x03])
        #expect(await session.waitForOutput(containing: "/ # ", count: 4))
        #expect(session.isRunning)

        // `exit` alone would exit with the status of the interrupted prompt, 130.
        session.type("exit 0\r")
        let status = await session.waitForExit(timeout: .seconds(30))
        #expect(status == 0, "\(session.output)")
        #expect(session.terminalIsRestored, "The terminal attributes differ after the session.")
    }

    @Test func survivesTheDaemonBeingKilled() async throws {
        let session = try start(["-e", "sleep", "100"])
        try await waitForSessions(1)
        let daemon = try await daemonProcessID()
        kill(daemon, SIGKILL)

        let result = await session.waitForExit(timeout: .seconds(30))
        #expect(result.status == 1)
        #expect(
            result.standardError.contains("maw: The maw daemon exited or closed the connection"),
            "\(result.standardError)")

        // launchd starts a new daemon, which boots a new machine.
        let next = try await run(["-e", "uname", "-r"])
        #expect(next.status == 0, "\(next.standardError)")
        #expect(next.output.hasPrefix("6.18"))
        #expect(try await daemonProcessID() != daemon)
    }

    // MARK: Measurements

    @Test func measuresColdStart() async throws {
        var times: [Double] = []
        for _ in 0..<5 {
            try await stopDaemon()
            // launchd starts a job at most once every 10 seconds (its default ThrottleInterval),
            // and the daemon was started moments ago. A daemon that exits after its idle
            // timeout is never throttled; waiting measures that case.
            try await Task.sleep(for: .seconds(10))
            let (status, elapsed) = try timed(["-e", "true"])
            times.append(elapsed)
            #expect(status == 0)
        }
        print(
            "measurement: cold start of maw -e true, 5 runs: "
                + times.map { String(format: "%.0f", $0) }.joined(separator: ", ")
                + String(format: " ms; median %.0f ms", times.sorted()[2]))
        #expect(times.sorted()[2] < 1_500)
    }

    @Test func measuresWarmLatency() async throws {
        #expect(try await run(["-e", "true"]).status == 0)
        var times: [Double] = []
        for _ in 0..<100 {
            let (status, elapsed) = try timed(["-e", "true"])
            times.append(elapsed)
            #expect(status == 0)
        }
        let sorted = times.sorted()
        let median = (sorted[49] + sorted[50]) / 2
        let p95 = sorted[94]
        print(
            String(
                format: "measurement: warm maw -e true, 100 runs: median %.1f ms, p95 %.1f ms, "
                    + "min %.1f ms, max %.1f ms", median, p95, sorted[0], sorted[99]))
        #expect(median < 50)
    }

    // MARK: Helpers

    /// The test runner's environment without its `DYLD_*` variables. `swift test` points them
    /// at Xcode's frameworks, and dyld would search those for every maw process, which slows
    /// each launch by over a hundred milliseconds and is not what users run.
    var mawEnvironment: [String: String] {
        environment.filter { !$0.key.hasPrefix("DYLD_") }
    }

    func start(_ arguments: [String], standardInput: Data? = nil) throws -> DebugBootProcess {
        try DebugBootProcess(
            executable: maw, arguments: arguments, standardInput: standardInput,
            separateStandardError: true, environment: mawEnvironment)
    }

    /// Runs maw with standard error collected separately and waits for it to exit.
    func run(_ arguments: [String], standardInput: Data? = nil) async throws
        -> DebugBootProcess.Result
    {
        try await start(arguments, standardInput: standardInput).waitForExit(timeout: .seconds(60))
    }

    /// Waits until `--status` shows `count` sessions on the initramfs machine.
    func waitForSessions(_ count: Int) async throws {
        let reached = await eventually(within: .seconds(30)) {
            let status = try? await run(["--status"])
            return status?.lines.contains {
                $0.hasPrefix("  initramfs ") && $0.hasSuffix(" \(count)")
            } == true
        }
        try #require(reached, "--status never showed \(count) sessions.")
    }

    /// The daemon's process ID, from the first line of `--status`.
    func daemonProcessID() async throws -> pid_t {
        let line = try #require(try await run(["--status"]).lines.first)
        let match = try #require(line.firstMatch(of: /process (\d+)/), "\(line)")
        return try #require(pid_t(match.1))
    }

    /// Stops every machine and the daemon, and waits until the daemon has exited.
    ///
    /// The wait watches the process, not `--status`: a `--status` that connects while the
    /// daemon exits makes launchd start a new one.
    func stopDaemon() async throws {
        let status = try await run(["--status"])
        guard !status.output.contains("not running") else { return }
        let daemon = try await daemonProcessID()
        kill(daemon, SIGTERM)
        let exited = await eventually(within: .seconds(30)) {
            kill(daemon, 0) != 0 && errno == ESRCH
        }
        try #require(exited, "The daemon did not exit after SIGTERM.")
        #expect(try await run(["--status"]).output.contains("not running"))
    }

    func expectCleanShutdownInConsoleLog(sourceLocation: SourceLocation = #_sourceLocation)
        throws
    {
        let log = try String(
            contentsOf: logDirectory.appending(path: "initramfs.log"), encoding: .utf8)
        let lastShutdown = try #require(
            DebugBootProcess.lines(of: log).last {
                $0.hasPrefix("[mawd] ") && $0.contains(" shutdown: ")
            }, sourceLocation: sourceLocation)
        #expect(
            lastShutdown.contains("shutdown: clean after "), "\(lastShutdown)",
            sourceLocation: sourceLocation)
    }

    func eventually(within timeout: Duration, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return await condition()
    }

    /// Runs maw with its output discarded and returns its status and the wall-clock time
    /// from starting it to its exit, in milliseconds.
    ///
    /// `posix_spawn` and `waitpid` rather than `Process`: `Process.waitUntilExit()` waits on a
    /// run loop and adds tens of milliseconds, more than the latency being measured.
    func timed(_ arguments: [String]) throws -> (status: Int32, milliseconds: Double) {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(
                &actions, descriptor, "/dev/null", descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY,
                0)
        }
        let argv = ([maw.path(percentEncoded: false)] + arguments).map { strdup($0) } + [nil]
        let envp = mawEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for string in argv + envp {
                free(string)
            }
        }
        var pid: pid_t = 0
        let start = ContinuousClock.now
        let error = posix_spawn(&pid, argv[0], &actions, nil, argv, envp)
        try #require(error == 0, "posix_spawn failed: \(String(cString: strerror(error)))")
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let elapsed = ContinuousClock.now - start
        let milliseconds =
            Double(elapsed.components.seconds) * 1e3 + Double(elapsed.components.attoseconds) / 1e15
        // WEXITSTATUS, which Swift does not import.
        return ((status >> 8) & 0xFF, milliseconds)
    }
}
