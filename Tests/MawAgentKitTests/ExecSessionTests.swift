import MawCore
import MawProtocol
import Testing

@testable import MawAgentKit

/// `GuestAgentClient` against the agent's session code over socket pairs.
@Suite struct ExecSessionTests {
    let agent = TestAgent()

    // MARK: Pipe mode

    @Test func relaysStandardInputOutputAndErrorSeparately() async throws {
        let output = Output()
        let process = try await agent.client.exec(
            ExecRequest(argv: ["/bin/sh", "-c", "cat; echo to-stderr >&2; exit 3"]),
            output: output.handler)
        #expect(process.pid > 0)
        process.write(Array("hello\n".utf8))
        process.closeInput()

        #expect(try await process.waitForExit() == .exited(code: 3))
        #expect(output.standardOutput == "hello\n")
        #expect(output.standardError == "to-stderr\n")
    }

    @Test func relaysLargeVolumesInBothDirections() async throws {
        let output = Output()
        let process = try await agent.client.exec(
            ExecRequest(argv: ["cat"]), output: output.handler)
        // 4 MiB: far more than every buffer on the way, so that back-pressure must work.
        let input = (0..<(4 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let writer = Task.detached {
            var offset = 0
            while offset < input.count {
                let end = min(offset + 50_000, input.count)
                process.write(input[offset..<end])
                offset = end
            }
            process.closeInput()
        }
        #expect(try await process.waitForExit() == .exited(code: 0))
        await writer.value
        #expect(output.standardOutputBytes == input)
    }

    /// A reader slower than the connection, such as a decompressor, keeps the agent's input
    /// backlog full, so that the agent must stop reading the connection and resume as the
    /// process drains its pipe.
    @Test(.timeLimit(.minutes(1)))
    func relaysLargeInputToASlowReader() async throws {
        let output = Output()
        let script = """
            total=0
            while :; do
                n=$(dd bs=65536 count=1 2>/dev/null | wc -c)
                [ "$n" -eq 0 ] && break
                total=$((total + n))
                sleep 0.005
            done
            echo "$total"
            """
        let process = try await agent.client.exec(
            ExecRequest(argv: ["/bin/sh", "-c", script]), output: output.handler)
        // 8 MiB: 32 times the agent's input limit.
        let size = 8 << 20
        // A thread of its own: `write` blocks, which must not hold a cooperative thread.
        startDetachedThread {
            let chunk = [UInt8](repeating: 0x5A, count: 32 << 10)
            var written = 0
            while written < size {
                process.write(chunk)
                written += chunk.count
            }
            process.closeInput()
        }
        #expect(try await process.waitForExit() == .exited(code: 0))
        #expect(output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "\(size)")
    }

    @Test func runsWithoutAnyEnvironmentFromTheHost() async throws {
        let output = Output()
        let process = try await agent.client.exec(
            ExecRequest(argv: ["ls", "/"]), output: output.handler)
        #expect(try await process.waitForExit() == .exited(code: 0))
        #expect(output.standardOutput.split(separator: "\n").contains("usr"))
    }

    @Test func appliesTheRequestEnvironmentOnTopOfTheDefaults() async throws {
        let output = Output()
        let process = try await agent.client.exec(
            ExecRequest(argv: ["env"], environment: ["HOME": "/home/test", "LANG": "C.UTF-8"]),
            output: output.handler)
        #expect(try await process.waitForExit() == .exited(code: 0))
        let variables = Set(output.standardOutput.split(separator: "\n").map(String.init))
        #expect(variables.contains("PATH=\(AgentEnvironment.defaults["PATH"]!)"))
        #expect(variables.contains("SHELL=/bin/sh"))
        #expect(variables.contains("HOME=/home/test"))
        #expect(variables.contains("LANG=C.UTF-8"))
        // Nothing from the agent's own environment leaks in.
        #expect(variables.count == 4)
    }

    @Test func runsInTheRequestedWorkingDirectory() async throws {
        let output = Output()
        let process = try await agent.client.exec(
            ExecRequest(argv: ["/bin/pwd"], workingDirectory: "/usr"), output: output.handler)
        #expect(try await process.waitForExit() == .exited(code: 0))
        #expect(output.standardOutput == "/usr\n")
    }

    @Test func forwardsASignalToTheProcessGroup() async throws {
        let process = try await agent.client.exec(
            ExecRequest(argv: ["sleep", "100"]), output: Output().handler)
        try await Task.sleep(for: .milliseconds(100))
        process.send(.int)
        let status = try await process.waitForExit()
        #expect(status == .signaled(signal: Signal.int.linuxNumber))
        #expect(status.shellStatus == 130)
    }

    @Test func endsTheSessionWhenAProcessExitsWithoutClosingItsOutput() async throws {
        // The background sleep keeps the pipes open; the session ends after its grace period.
        let started = ContinuousClock.now
        let process = try await agent.client.exec(
            ExecRequest(argv: ["/bin/sh", "-c", "sleep 30 & exit 4"]), output: Output().handler)
        #expect(try await process.waitForExit() == .exited(code: 4))
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    // MARK: Failures to start

    @Test func reportsACommandThatDoesNotExist() async throws {
        await #expect(
            throws: MawError.guestCommandNotFound(
                command: "no-such-command",
                reason: "no-such-command: not found in PATH \(AgentEnvironment.defaults["PATH"]!)")
        ) {
            _ = try await agent.client.exec(
                ExecRequest(argv: ["no-such-command"]), output: Output().handler)
        }
        await #expect(
            throws: MawError.guestCommandNotFound(
                command: "/no/such/path", reason: "/no/such/path: No such file or directory")
        ) {
            _ = try await agent.client.exec(
                ExecRequest(argv: ["/no/such/path"]), output: Output().handler)
        }
    }

    @Test func reportsAMissingWorkingDirectory() async throws {
        await #expect(
            throws: MawError.guestCommandNotStarted(
                command: "true",
                reason: "cannot change to the working directory /no/such/directory: "
                    + "No such file or directory")
        ) {
            _ = try await agent.client.exec(
                ExecRequest(argv: ["true"], workingDirectory: "/no/such/directory"),
                output: Output().handler)
        }
    }

    @Test func reportsAnEmptyCommand() async throws {
        await #expect(
            throws: MawError.guestCommandNotStarted(command: "", reason: "argv is empty")
        ) {
            _ = try await agent.client.exec(ExecRequest(argv: []), output: Output().handler)
        }
    }

    // MARK: Terminal mode

    @Test func runsOnATerminalAndResizesIt() async throws {
        let output = Output()
        let process = try await agent.client.exec(
            ExecRequest(
                argv: ["/bin/sh", "-c", "tty; stty size; read line; stty size"],
                terminal: TerminalSize(rows: 24, columns: 80)),
            output: output.handler)
        #expect(await output.waitForOutput(containing: "24 80"))
        process.resize(TerminalSize(rows: 30, columns: 100))
        process.write(Array("go\n".utf8))
        #expect(try await process.waitForExit() == .exited(code: 0))

        let lines = output.standardOutput.split(separator: "\r\n").map(String.init)
        #expect(lines.first?.hasPrefix("/dev/") == true)
        #expect(lines.contains("24 80"))
        #expect(lines.contains("30 100"))
        #expect(output.standardError.isEmpty)
    }

    @Test func sendsTheTerminalsEndOfFileCharacterForStdinEOF() async throws {
        let output = Output()
        let process = try await agent.client.exec(
            ExecRequest(argv: ["cat"], terminal: TerminalSize(rows: 24, columns: 80)),
            output: output.handler)
        process.write(Array("typed\n".utf8))
        #expect(await output.waitForOutput(containing: "typed\r\ntyped\r\n"))
        process.closeInput()
        #expect(try await process.waitForExit() == .exited(code: 0))
    }

    @Test func signalsTheForegroundProcessGroupOfATerminal() async throws {
        let output = Output()
        let process = try await agent.client.exec(
            ExecRequest(argv: ["sleep", "100"], terminal: TerminalSize(rows: 24, columns: 80)),
            output: output.handler)
        try await Task.sleep(for: .milliseconds(100))
        process.send(.term)
        #expect(try await process.waitForExit() == .signaled(signal: Signal.term.linuxNumber))
    }

    // MARK: Control requests

    @Test func answersInfo() async throws {
        let info = try await agent.client.info()
        #expect(info.agentVersion == MawVersion.current)
        #expect(info.protocolVersion == ProtocolVersion.current)
        #expect(!info.kernelRelease.isEmpty)
        #expect(info.uptimeMilliseconds > 0)
    }

    @Test func powersOffOnShutdown() async throws {
        try await agent.client.shutdown()
        #expect(agent.powerOffRequests.value == 1)
    }

    @Test func refusesConnectionsBeyondTheLimit() async throws {
        let agent = TestAgent(maximumConnections: 1)
        let process = try await agent.client.exec(
            ExecRequest(argv: ["sleep", "100"]), output: Output().handler)
        await #expect {
            try await agent.client.info()
        } throws: { error in
            guard case .guestAgentFailed(let reason) = error as? MawError else { return false }
            return reason.contains("connections")
        }
        process.send(.kill)
        _ = try await process.waitForExit()
    }

    @Test func passesTheSelfTest() async {
        let failures = await SelfTest.run()
        #expect(failures.isEmpty, "\(failures)")
    }
}

@Suite struct CommandResolutionTests {
    @Test func searchesPathInOrder() throws {
        #expect(
            try ChildProcess.resolve("sh", searchPath: "/nonexistent:/bin:/usr/bin") == "/bin/sh")
        #expect(try ChildProcess.resolve("./x", searchPath: "") == "./x")
    }

    @Test func reportsANameNotInPath() {
        #expect(
            throws: SpawnFailure(code: .commandNotFound, message: "nope: not found in PATH /bin")
        ) {
            try ChildProcess.resolve("nope", searchPath: "/bin")
        }
    }

    @Test func mergesTheEnvironment() {
        let merged = AgentEnvironment.merged(["HOME": "/x", "TERM": "vt100"])
        #expect(merged["HOME"] == "/x")
        #expect(merged["TERM"] == "vt100")
        #expect(merged["SHELL"] == "/bin/sh")
        #expect(merged["PATH"] == "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
    }

    @Test func decodesWaitStatuses() {
        #expect(ChildProcess.decode(3 << 8) == .exited(code: 3))
        #expect(ChildProcess.decode(0) == .exited(code: 0))
        #expect(ChildProcess.decode(9) == .signaled(signal: 9))
        // A core dump sets bit 7; the signal is still in the low 7 bits.
        #expect(ChildProcess.decode(0x80 | 11) == .signaled(signal: 11))
    }
}
