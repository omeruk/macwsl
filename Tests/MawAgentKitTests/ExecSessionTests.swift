import MawCore
import MawProtocol
import Testing

@testable import MawAgentKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

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
        // A thread of its own, not a task: `write` blocks while the input queue is full.
        async let written: Void = runOnDedicatedThread {
            var offset = 0
            while offset < input.count {
                let end = min(offset + 50_000, input.count)
                process.write(input[offset..<end])
                offset = end
            }
            process.closeInput()
        }
        #expect(try await process.waitForExit() == .exited(code: 0))
        await written
        #expect(output.standardOutputBytes == input)
    }

    /// A reader slower than the connection, such as a decompressor, keeps the agent's input
    /// backlog full, so that the client must wait for the input window and resume as the
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

    @Test func startsFromALoginEnvironmentWithTheRequestsVariablesOnTop() async throws {
        let output = Output()
        let process = try await agent.client.exec(
            ExecRequest(argv: ["env"], environment: ["HOME": "/home/test", "TERM": "vt100"]),
            output: output.handler)
        #expect(try await process.waitForExit() == .exited(code: 0))
        let variables = Set(output.standardOutput.split(separator: "\n").map(String.init))
        // The test guest's root is the account running the tests, not user ID 0, so it gets the
        // PATH of other users.
        #expect(
            variables == [
                "PATH=\(LoginDefinitions.defaultUserPath)", "SHELL=/bin/sh", "HOME=/home/test",
                "USER=root", "LOGNAME=root", "LANG=C.UTF-8", "TERM=vt100",
            ])
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

    // MARK: Control messages ahead of unread input

    /// Ctrl-C reaches a process that never reads its standard input, however much input waits
    /// for it. Before the input window, the agent stopped reading the connection once 256 KiB
    /// waited, and the signal stayed behind the rest for good.
    @Test(.timeLimit(.minutes(1)), arguments: [nil, TerminalSize(rows: 24, columns: 80)])
    func deliversASignalAheadOfUnreadInput(terminal: TerminalSize?) async throws {
        let process = try await agent.client.exec(
            ExecRequest(argv: ["sleep", "1000"], terminal: terminal), output: Output().handler)
        let flood = InputFlood(process)
        let queued = await flood.waitUntilBlocked()
        #expect(queued >= AgentProtocol.inputWindow)

        let sent = ContinuousClock.now
        process.send(.int)
        let status = await exitStatus(of: process, within: .seconds(5))
        let delay = ContinuousClock.now - sent
        #expect(status == .signaled(signal: Signal.int.linuxNumber))
        #expect(delay < .seconds(1), "the signal took \(delay)")
    }

    /// Ctrl-C reaches a process whose output nobody reads within 100 ms. The output handler
    /// blocks, as `maw`'s write to a standard output that nobody reads does; before, it blocked
    /// the client's I/O thread, and the signal was never sent. The process's trap creates a
    /// file, so that the test sees the signal arrive without reading any output.
    @Test(.timeLimit(.minutes(1)), arguments: [nil, TerminalSize(rows: 24, columns: 80)])
    func deliversASignalWhileTheOutputIsNotRead(terminal: TerminalSize?) async throws {
        let marker = "/tmp/maw-test-signal-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        defer { unlink(marker) }
        let output = UnreadOutput()
        let process = try await agent.client.exec(
            ExecRequest(
                argv: ["/bin/sh", "-c", "trap 'touch \"$0\"; exit 130' INT; yes", marker],
                terminal: terminal),
            output: output.handler)
        #expect(await output.waitUntilBlocked())
        // Long enough for every buffer on the way to fill.
        try await Task.sleep(for: .milliseconds(300))

        let sent = ContinuousClock.now
        process.send(.int)
        while access(marker, F_OK) != 0 && ContinuousClock.now - sent < .seconds(5) {
            try await Task.sleep(for: .milliseconds(1))
        }
        let delay = ContinuousClock.now - sent
        #expect(access(marker, F_OK) == 0, "the signal did not arrive")
        #expect(delay < .milliseconds(100), "the signal took \(delay)")

        output.release()
        #expect(await exitStatus(of: process, within: .seconds(5)) == .exited(code: 130))
    }

    /// A resize reaches a terminal whose process reads none of a large paste.
    @Test(.timeLimit(.minutes(1)))
    func resizesATerminalAheadOfUnreadInput() async throws {
        let output = Output()
        let process = try await agent.client.exec(
            ExecRequest(
                argv: [
                    "/bin/sh", "-c",
                    "trap 'stty size' WINCH; echo ready; while :; do sleep 0.02; done",
                ],
                terminal: TerminalSize(rows: 24, columns: 80)),
            output: output.handler)
        #expect(await output.waitForOutput(containing: "ready"))
        let flood = InputFlood(process)
        #expect(await flood.waitUntilBlocked() >= AgentProtocol.inputWindow)

        process.resize(TerminalSize(rows: 30, columns: 100))
        #expect(await output.waitForOutput(containing: "30 100", timeout: .seconds(1)))
        process.send(.kill)
        _ = await exitStatus(of: process, within: .seconds(5))
    }

    /// A host that sends more input than the window allows is closed with a protocol error.
    @Test func closesAConnectionThatExceedsTheInputWindow() async throws {
        let connection = try FrameConnection(try agent.connect())
        // On a thread of its own: each step waits for the agent.
        let (version, started, reply) = try await runOnDedicatedThread {
            () throws -> (UInt32, ControlMessage, ControlMessage?) in
            let deadline = ContinuousClock.now + .seconds(10)
            let version = try connection.exchangeVersions(until: deadline)
            connection.enqueue(.control(.exec(ExecRequest(argv: ["sleep", "1000"]))))
            try connection.flush(until: deadline)
            let started = try connection.receiveControl(until: deadline, expecting: "started")
            guard case .started = started else { return (version, started, nil) }
            // Twice the window, without waiting for `stdinConsumed`: the process's pipe takes
            // at most 64 KiB of it.
            let chunk = [UInt8](repeating: 0x79, count: AgentProtocol.maximumDataChunkSize)
            for _ in 0..<(2 * AgentProtocol.inputWindow / chunk.count) {
                connection.enqueue(Frame(type: .stdin, payload: chunk))
            }
            try connection.flush(until: deadline)
            var frame = try connection.receiveFrame(until: deadline, expecting: "an error")
            while frame.type == .stdinConsumed {
                frame = try connection.receiveFrame(until: deadline, expecting: "an error")
            }
            return (version, started, try frame.controlMessage())
        }
        #expect(version == ProtocolVersion.current)
        guard case .started = started, let reply else {
            Issue.record("the process did not start")
            return
        }
        guard case .error(let error) = reply else {
            Issue.record("expected an error, received \(reply.name)")
            return
        }
        #expect(error.code == .protocolViolation)
        #expect(error.message.contains("window"))
    }

    // MARK: Failures to start

    @Test func reportsACommandThatDoesNotExist() async throws {
        await #expect(
            throws: MawError.guestCommandNotFound(
                command: "no-such-command",
                reason: "no-such-command: not found in PATH \(LoginDefinitions.defaultUserPath)")
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
        let failures = await SelfTest.run(system: .testing())
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

    @Test func decodesWaitStatuses() {
        #expect(ChildProcess.decode(3 << 8) == .exited(code: 3))
        #expect(ChildProcess.decode(0) == .exited(code: 0))
        #expect(ChildProcess.decode(9) == .signaled(signal: 9))
        // A core dump sets bit 7; the signal is still in the low 7 bits.
        #expect(ChildProcess.decode(0x80 | 11) == .signaled(signal: 11))
    }
}
