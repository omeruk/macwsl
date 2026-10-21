import Darwin
import Foundation
import Testing

/// `debug-boot --exec` and `--shell` against a real virtual machine, through the guest agent.
/// Part of `IntegrationTests`, so that they share its conditions and run one at a time.
extension IntegrationTests {
    // MARK: --exec

    @Test func execPrintsTheGuestsUname() async throws {
        let result = try await exec(["uname", "-a"])

        #expect(result.status == 0, "\(result.standardError)")
        let uname = DebugBootProcess.lines(of: result.output).filter { !$0.isEmpty }
        #expect(uname.count == 1, "\(result.output)")
        #expect(uname.first?.hasPrefix("Linux ") == true, "\(result.output)")
        #expect(uname.first?.contains(" 6.18") == true, "\(result.output)")
        #expect(
            DebugBootProcess.lines(of: result.standardError).contains {
                $0.hasPrefix("boot: agent ready after ") && $0.hasSuffix(" ms")
            }, "\(result.standardError)")
        try expectCleanShutdown(result)
    }

    @Test func execExitsWithTheCommandsStatus() async throws {
        let result = try await exec(["sh", "-c", "exit 3"])
        #expect(result.status == 3, "\(result.standardError)")
        try expectCleanShutdown(result)
    }

    @Test func execForwardsStandardInput() async throws {
        let result = try await exec(["cat"], standardInput: Data("hello\n".utf8))
        #expect(result.status == 0, "\(result.standardError)")
        #expect(result.output == "hello\n")
        try expectCleanShutdown(result)
    }

    @Test func execKeepsStandardOutputAndErrorSeparate() async throws {
        let result = try await exec(["sh", "-c", "echo to-stdout; echo to-stderr >&2"])
        #expect(result.status == 0, "\(result.standardError)")
        #expect(result.output == "to-stdout\n")
        let errorLines = DebugBootProcess.lines(of: result.standardError)
        #expect(errorLines.contains("to-stderr"), "\(result.standardError)")
        #expect(!errorLines.contains("to-stdout"))
    }

    @Test func execWorksWithoutAnyEnvironmentFromTheHost() async throws {
        let result = try await exec(["ls", "/"], environment: [:])
        #expect(result.status == 0, "\(result.standardError)")
        let entries = DebugBootProcess.lines(of: result.output)
        #expect(entries.contains("sbin") && entries.contains("proc"), "\(result.output)")
    }

    @Test func execReportsAMissingCommandAsAShellWould() async throws {
        let result = try await exec(["no-such-command"])
        #expect(result.status == 127, "\(result.standardError)")
        #expect(
            result.standardError.contains(
                "macwsl: no-such-command: command not found in the guest"),
            "\(result.standardError)")
        try expectCleanShutdown(result)
    }

    @Test func execForwardsSIGINTToTheCommand() async throws {
        let run = try DebugBootProcess(
            macwsld, ["--exec", "--", "sleep", "100"], separateStandardError: true)
        let ready = await run.waitForLine(
            in: \.standardError, where: { $0.hasPrefix("boot: agent ready after ") },
            timeout: .seconds(60))
        try #require(ready, "The agent did not become ready: \(run.standardError)")
        try await Task.sleep(for: .milliseconds(500))

        run.signal(SIGINT)
        let result = await run.waitForExit(timeout: .seconds(60))
        #expect(result.status == 128 + SIGINT, "\(result.standardError)")
        try expectCleanShutdown(result)
    }

    @Test func shutsDownCleanlyWithinTwoSeconds() async throws {
        let result = try await exec(["true"])
        #expect(result.status == 0, "\(result.standardError)")
        let prefix = "debug-boot: shutdown: clean after "
        let line = try #require(
            DebugBootProcess.lines(of: result.standardError).first { $0.hasPrefix(prefix) },
            "\(result.standardError)")
        #expect(line.hasSuffix(" ms via the guest agent"), "\(line)")
        let milliseconds = try #require(Int(line.dropFirst(prefix.count).prefix { $0 != " " }))
        #expect(milliseconds < 2_000, "\(line)")
        print("measurement: clean shutdown after \(milliseconds) ms")
        try expectCleanShutdown(result)
    }

    // MARK: Measurements

    @Test func measuresBootToAgentReady() async throws {
        var readyTimes: [Int] = []
        for _ in 0..<5 {
            let result = try await exec(["true"])
            #expect(result.status == 0, "\(result.standardError)")
            let prefix = "boot: agent ready after "
            let line = try #require(
                DebugBootProcess.lines(of: result.standardError).first { $0.hasPrefix(prefix) })
            readyTimes.append(try #require(Int(line.dropFirst(prefix.count).prefix { $0 != " " })))
        }
        let median = readyTimes.sorted()[readyTimes.count / 2]
        print("measurement: boot to agent ready \(readyTimes) ms, median \(median) ms")
        #expect(median < 5_000)
    }

    @Test func measuresExecLatency() async throws {
        let result = try await exec(["--repeat", "100", "--", "true"], rawArguments: true)
        #expect(result.status == 0, "\(result.standardError)")
        let line = try #require(
            DebugBootProcess.lines(of: result.standardError).first {
                $0.hasPrefix("debug-boot: exec: 100 runs of true: median ")
            }, "\(result.standardError)")
        print("measurement: \(line.dropFirst("debug-boot: ".count))")
    }

    // MARK: --shell

    @Test func shellRunsOnATerminalThatFollowsTheWindowSize() async throws {
        let session = try InteractiveSession(macwsld, [], mode: "--shell", rows: 24, columns: 80)
        #expect(await session.waitForOutput(containing: "boot: agent ready after "))
        #expect(
            await session.waitForOutput(
                containing: "type ~. at the start of a line or press Ctrl-]. Type ~? for help."))
        try #require(await session.waitForOutput(containing: "/ # "), "\(session.output)")

        session.type("stty size\r")
        #expect(await session.waitForOutput(containing: "24 80"), "\(session.output)")
        #expect(await session.waitForOutput(containing: "/ # ", count: 2))

        session.resize(rows: 30, columns: 100)
        try await Task.sleep(for: .milliseconds(300))
        session.type("stty size\r")
        #expect(await session.waitForOutput(containing: "30 100"), "\(session.output)")
        #expect(await session.waitForOutput(containing: "/ # ", count: 3))

        // Ctrl-C reaches the guest's shell, not debug-boot.
        session.type([0x03])
        #expect(await session.waitForOutput(containing: "/ # ", count: 4))
        #expect(session.isRunning)

        // As in ssh, an escape sequence needs the start of a line; Ctrl-C did not start one.
        session.type("\r")
        #expect(await session.waitForOutput(containing: "/ # ", count: 5))
        session.type("~.")
        let status = await session.waitForExit(timeout: .seconds(30))
        #expect(status == 0, "\(session.output)")
        #expect(session.output.contains("debug-boot: shutdown: clean after "), "\(session.output)")
        #expect(session.terminalIsRestored, "The terminal attributes differ after the session.")
    }

    @Test func refusesShellModeWithoutATerminal() async throws {
        let run = try DebugBootProcess(macwsld, ["--shell"])
        let result = await run.waitForExit(timeout: .seconds(30))
        #expect(result.status == 1)
        #expect(
            result.lines.first
                == "macwsl: --shell needs a terminal, but standard input is not a terminal.")
    }

    // MARK: Helpers

    /// Runs `debug-boot --exec -- <command>` and waits for it to exit, with standard error
    /// collected separately. With `rawArguments`, `command` is passed after `--exec` as is.
    func exec(
        _ command: [String], standardInput: Data? = nil, environment: [String: String]? = nil,
        rawArguments: Bool = false
    ) async throws -> DebugBootProcess.Result {
        let arguments = rawArguments ? ["--exec"] + command : ["--exec", "--"] + command
        let run = try DebugBootProcess(
            macwsld, arguments, standardInput: standardInput, separateStandardError: true,
            environment: environment)
        return await run.waitForExit(timeout: .seconds(120))
    }

    /// Checks that the console log's last shutdown line records a clean shutdown.
    func expectCleanShutdown(
        _ result: DebugBootProcess.Result, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let prefix = "debug-boot: console log: "
        let logPath = try #require(
            DebugBootProcess.lines(of: result.standardError).first { $0.hasPrefix(prefix) }?
                .dropFirst(prefix.count), sourceLocation: sourceLocation)
        let log = try String(contentsOfFile: String(logPath), encoding: .utf8)
        let lastShutdown = try #require(
            DebugBootProcess.lines(of: log).last {
                $0.hasPrefix("[macwsld] ") && $0.contains(" shutdown: ")
            }, sourceLocation: sourceLocation)
        #expect(
            lastShutdown.contains("shutdown: clean after "), "\(lastShutdown)",
            sourceLocation: sourceLocation)
    }
}
