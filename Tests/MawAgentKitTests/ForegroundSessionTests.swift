import MawCore
import MawProtocol
import Testing

@testable import MawAgentKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// `foregroundQuery` from `GuestProcess` to the agent's session code, on real pseudo-terminals.
/// The foreground group comes from `tcgetpgrp`; the process files come from a fixture, because
/// macOS has no `/proc`, which the test fills in for the process IDs it observes.
@Suite struct ForegroundSessionTests {
    static let terminal = TerminalSize(rows: 24, columns: 80)

    @Test func reportsNoneInPipeMode() async throws {
        let agent = TestAgent()
        let process = try await agent.client.exec(
            ExecRequest(argv: ["sleep", "100"]), output: Output().handler)
        #expect(await process.foregroundProgram(within: .seconds(10)) == .none)
        process.send(.kill)
        _ = try await process.waitForExit()
    }

    /// A command's own program leads the foreground group; it is the session's program.
    @Test func reportsNoneWhileTheSessionsProgramIsInTheForeground() async throws {
        let agent = TestAgent()
        let process = try await agent.client.exec(
            ExecRequest(argv: ["sleep", "100"], terminal: Self.terminal), output: Output().handler)
        #expect(await process.foregroundProgram(within: .seconds(10)) == .none)
        process.send(.kill)
        _ = try await process.waitForExit()
    }

    /// A shell with job control runs `cat` in a foreground group of its own. Without its
    /// process files, the leader counts as exited; with them, it is named; as a zombie, it is
    /// nameless again. Once `cat` has ended, the shell is in the foreground again.
    @Test(.timeLimit(.minutes(1)))
    func reportsAForegroundJobUntilItEnds() async throws {
        let proc = try ProcessFixture()
        let agent = TestAgent(processDirectory: proc.directory)
        let output = Output()
        let process = try await agent.client.exec(
            ExecRequest(
                argv: ["/bin/sh", "-c", "set -m; cat > /dev/null; echo back; read line"],
                terminal: Self.terminal),
            output: output.handler)

        var answer = ForegroundAnswer.none
        let deadline = ContinuousClock.now + .seconds(10)
        while answer == .none && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            answer = await process.foregroundProgram(within: .seconds(10))
        }
        guard case .program(let group, nil) = answer else {
            Issue.record("expected a program without a name, received \(answer)")
            process.send(.kill)
            _ = try await process.waitForExit()
            return
        }
        #expect(group != process.pid)

        proc.add(group, parent: process.pid, name: "cat")
        #expect(
            await process.foregroundProgram(within: .seconds(10))
                == .program(processGroup: group, name: "cat"))
        proc.add(group, parent: process.pid, name: "cat", state: "Z")
        #expect(
            await process.foregroundProgram(within: .seconds(10))
                == .program(processGroup: group, name: nil))

        // The end of input ends cat; the shell takes the terminal back and waits in `read`.
        process.closeInput()
        #expect(await output.waitForOutput(containing: "back"))
        #expect(await process.foregroundProgram(within: .seconds(10)) == .none)
        process.send(.kill)
        _ = try await process.waitForExit()
    }

    /// A login shell that has run `exec` is reported by its new command name.
    @Test func reportsAProgramThatTheLoginShellExeced() async throws {
        let proc = try ProcessFixture()
        let agent = TestAgent(processDirectory: proc.directory)
        let process = try await agent.client.exec(
            ExecRequest(program: .loginShell, terminal: Self.terminal), output: Output().handler)
        // The test guest's shell is /bin/sh, started directly.
        proc.add(process.pid, parent: 1, name: "sh")
        #expect(await process.foregroundProgram(within: .seconds(10)) == .none)
        proc.add(process.pid, parent: 1, name: "vim")
        #expect(
            await process.foregroundProgram(within: .seconds(10))
                == .program(processGroup: process.pid, name: "vim"))
        process.send(.kill)
        _ = try await process.waitForExit()
    }

    @Test func reportsNoneAfterTheProcessHasExited() async throws {
        let agent = TestAgent()
        let process = try await agent.client.exec(
            ExecRequest(argv: ["true"], terminal: Self.terminal), output: Output().handler)
        #expect(try await process.waitForExit() == .exited(code: 0))
        #expect(await process.foregroundProgram(within: .seconds(10)) == .none)
    }

    /// Closing the connection from the host ends the session as a closed ssh connection does:
    /// the agent sends SIGHUP to the terminal's foreground group.
    @Test(.timeLimit(.minutes(1)))
    func hangsUpOnTheProcessWhenTheHostHangsUp() async throws {
        let marker = "/tmp/maw-hangup-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        defer { unlink(marker) }
        let agent = TestAgent()
        let output = Output()
        let process = try await agent.client.exec(
            ExecRequest(
                argv: [
                    "/bin/sh", "-c",
                    "trap 'echo hup > \"$0\"; exit 0' HUP; echo ready; while :; do sleep 0.1; done",
                    marker,
                ],
                terminal: Self.terminal),
            output: output.handler)
        #expect(await output.waitForOutput(containing: "ready"))
        process.hangUp()
        await #expect(throws: MawError.guestAgentFailed(reason: "exec: the host hung up")) {
            try await process.waitForExit()
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while access(marker, F_OK) != 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(access(marker, F_OK) == 0)
    }
}
