import Darwin
import Foundation
import Testing

/// `maw` against a real daemon, which boots real virtual machines, in the test distribution
/// that scripts/integration-test.sh installs (see `MawIntegration`). The owner's installed
/// daemon, `dev.maw.mawd`, is never touched.
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled,
        "Integration tests boot a real virtual machine; run scripts/integration-test.sh."),
    .serialized
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
        try await waitForSessions(1)
        session.signal(SIGINT)
        let result = await session.waitForExit(timeout: .seconds(30))
        #expect(result.status == 130, "\(result.output)")
        #expect(try await machineRow().contains("Running"))
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
        try await waitForSessions(2)
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
        try await waitForSessions(1)
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

        session.type("stty size\r")
        #expect(await session.waitForOutput(containing: "24 80"), "\(session.plainOutput)")
        #expect(await session.waitForPrompt(user: maw.user, host: host, count: 2))

        session.resize(rows: 30, columns: 100)
        try await Task.sleep(for: .milliseconds(300))
        session.type("stty size\r")
        #expect(await session.waitForOutput(containing: "30 100"), "\(session.plainOutput)")
        #expect(await session.waitForPrompt(user: maw.user, host: host, count: 3))

        // Ctrl-C reaches the guest's shell, which prints a new prompt.
        session.type([0x03])
        #expect(await session.waitForPrompt(user: maw.user, host: host, count: 4))
        #expect(session.isRunning)

        // `exit` alone would exit with the status of the interrupted prompt, 130.
        session.type("exit 0\r")
        let status = await session.waitForExit(timeout: .seconds(30))
        #expect(status == 0, "\(session.plainOutput)")
        #expect(session.terminalIsRestored, "The terminal attributes differ after the session.")
    }

    @Test func survivesTheDaemonBeingKilled() async throws {
        let session = try maw.start(["-d", distribution, "-e", "sleep", "100"])
        try await waitForSessions(1)
        let daemon = try await daemonProcessID()
        kill(daemon, SIGKILL)

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

    /// The test distribution's row in `--status`, or an empty string.
    func machineRow() async throws -> String {
        let status = try await maw.run(["--status"])
        return status.lines.first { $0.hasPrefix("  \(distribution) ") } ?? ""
    }

    /// Waits until `--status` shows `count` sessions on the test distribution's machine.
    func waitForSessions(_ count: Int) async throws {
        let reached = await maw.eventually(within: .seconds(30)) {
            (try? await machineRow())?.hasSuffix(" \(count)") == true
        }
        try #require(reached, "--status never showed \(count) sessions.")
    }

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
