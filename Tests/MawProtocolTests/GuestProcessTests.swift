import MawCore
import Testing

@testable import MawProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The client side of an exec session against a scripted agent.
@Suite struct GuestProcessTests {
    /// Plays the agent: answers the handshake and the exec request with `frames`, written in
    /// one piece, then waits for the client to close the connection, or closes it at once.
    static func scriptedAgent(sending frames: [Frame], thenClose: Bool = false) throws
        -> GuestAgentClient
    {
        let (host, peer) = try HandshakeTests.socketPair()
        startDetachedThread {
            guard let connection = try? FrameConnection(peer) else { return }
            _ = try? connection.exchangeVersions(until: .now + .seconds(5))
            _ = try? connection.receiveControl(until: .now + .seconds(5), expecting: "exec")
            for frame in frames {
                connection.enqueue(frame)
            }
            try? connection.flush(until: .now + .seconds(5))
            if !thenClose {
                while (try? connection.receiveFrame(until: .now + .seconds(10))) != nil {}
            }
            peer.close()
        }
        return GuestAgentClient { () throws(MawError) in host }
    }

    @Test func deliversOutputThatArrivesWithTheStartedReply() async throws {
        let client = try Self.scriptedAgent(sending: [
            .control(.started(pid: 7)), Frame(type: .stdout, payload: Array("/ # ".utf8)),
        ])
        let received = Received()
        let process = try await client.exec(ExecRequest(argv: ["sh"])) { _, bytes in
            received.append(bytes)
        }
        #expect(process.pid == 7)
        // Nothing else arrives on the connection, so the output must come from the buffer.
        let deadline = ContinuousClock.now + .seconds(5)
        while received.text.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(received.text == "/ # ")
    }

    @Test func returnsTheExitThatArrivesWithTheStartedReply() async throws {
        let client = try Self.scriptedAgent(sending: [
            .control(.started(pid: 7)), Frame(type: .stdout, payload: Array("hi\n".utf8)),
            .control(.exited(.exited(code: 5))),
        ])
        let received = Received()
        let process = try await client.exec(ExecRequest(argv: ["true"])) { _, bytes in
            received.append(bytes)
        }
        #expect(try await process.waitForExit() == .exited(code: 5))
        #expect(received.text == "hi\n")
    }

    /// The client's writers block while the agent reads slowly, and resume as it reports
    /// consumed input.
    @Test(.timeLimit(.minutes(1)))
    func streamsLargeInputToASlowAgent() async throws {
        let (host, peer) = try HandshakeTests.socketPair()
        let received = ByteCounter()
        startDetachedThread {
            guard let connection = try? FrameConnection(peer) else { return }
            _ = try? connection.exchangeVersions(until: .now + .seconds(5))
            _ = try? connection.receiveControl(until: .now + .seconds(5), expecting: "exec")
            connection.enqueue(.control(.started(pid: 7)))
            try? connection.flush(until: .now + .seconds(5))
            var count = 0
            while let frame = try? connection.receiveFrame(until: .now + .seconds(10)) {
                if frame.type == .stdin {
                    count += frame.payload.count
                    // About 1 ms per 32 KiB frame: far slower than the client writes.
                    usleep(1000)
                    connection.enqueue(.stdinConsumed(UInt32(frame.payload.count)))
                    try? connection.flush(until: .now + .seconds(5))
                } else if case .stdinEOF = try? frame.controlMessage() {
                    break
                }
            }
            received.add(count)
            connection.enqueue(.control(.exited(.exited(code: 0))))
            try? connection.flush(until: .now + .seconds(5))
            while (try? connection.receiveFrame(until: .now + .seconds(10))) != nil {}
            peer.close()
        }
        let client = GuestAgentClient { () throws(MawError) in host }
        let process = try await client.exec(ExecRequest(argv: ["cat"])) { _, _ in }
        // 8 MiB: 32 times the client's input limit.
        let size = 8 << 20
        // A thread of its own: `write` blocks, which must not hold a cooperative thread.
        startDetachedThread {
            let chunk = [UInt8](repeating: 0x5A, count: 50_000)
            var written = 0
            while written < size {
                let count = min(chunk.count, size - written)
                process.write(chunk[..<count])
                written += count
            }
            process.closeInput()
        }
        #expect(try await process.waitForExit() == .exited(code: 0))
        #expect(received.value == size)
    }

    /// Over vsock, the guest grants send credit in large steps, so that one `send` can take the
    /// whole outbox at once. The client must then move more queued input to the connection
    /// instead of waiting for a wake-up that its blocked writer never sends.
    @Test(.timeLimit(.minutes(1)))
    func keepsSendingWhenOneSendEmptiesAFullOutbox() async throws {
        let (host, peer) = try HandshakeTests.socketPair()
        // Socket buffers far larger than the client's outbox limit, like vsock's credit window.
        var bufferSize: Int32 = 1 << 20
        let optionSize = socklen_t(MemoryLayout<Int32>.size)
        try #require(setsockopt(host.rawValue, SOL_SOCKET, SO_SNDBUF, &bufferSize, optionSize) == 0)
        try #require(setsockopt(peer.rawValue, SOL_SOCKET, SO_RCVBUF, &bufferSize, optionSize) == 0)
        let received = ByteCounter()
        startDetachedThread {
            guard let connection = try? FrameConnection(peer) else { return }
            _ = try? connection.exchangeVersions(until: .now + .seconds(5))
            _ = try? connection.receiveControl(until: .now + .seconds(5), expecting: "exec")
            connection.enqueue(.control(.started(pid: 7)))
            try? connection.flush(until: .now + .seconds(5))
            // Reads in bursts: pauses, then takes everything that has arrived in large reads,
            // and reports it consumed.
            var decoder = FrameDecoder()
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            var count = 0
            // Ends on its own if the client stalls, so that a failing run leaves no thread behind.
            let deadline = ContinuousClock.now + .seconds(25)
            reading: while ContinuousClock.now < deadline {
                usleep(20_000)
                while true {
                    let length = read(peer.rawValue, &buffer, buffer.count)
                    if length == 0 {
                        break reading
                    }
                    if length < 0 {
                        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                            break
                        }
                        break reading
                    }
                    decoder.append(buffer[..<length])
                    var consumed = 0
                    while let frame = try? decoder.nextFrame() {
                        if frame.type == .stdin {
                            consumed += frame.payload.count
                        } else if case .stdinEOF = try? frame.controlMessage() {
                            count += consumed
                            break reading
                        }
                    }
                    count += consumed
                    if consumed > 0 {
                        connection.enqueue(.stdinConsumed(UInt32(consumed)))
                        try? connection.flush(until: .now + .seconds(5))
                    }
                }
            }
            received.add(count)
            connection.enqueue(.control(.exited(.exited(code: 0))))
            try? connection.flush(until: .now + .seconds(5))
            while (try? connection.receiveFrame(until: .now + .seconds(10))) != nil {}
            peer.close()
        }
        let client = GuestAgentClient { () throws(MawError) in host }
        let process = try await client.exec(ExecRequest(argv: ["cat"])) { _, _ in }
        let size = 16 << 20
        startDetachedThread {
            let chunk = [UInt8](repeating: 0x5A, count: 32 << 10)
            var written = 0
            while written < size {
                process.write(chunk)
                written += chunk.count
            }
            process.closeInput()
        }
        // Without the fix, the client stops sending for good; a bounded wait reports that as a
        // failure instead of hanging the test run.
        let status = await Self.exitStatus(of: process, within: .seconds(20))
        #expect(status == .exited(code: 0))
        #expect(received.value == size)
    }

    /// The client never has more input outstanding than the window, and a signal and a resize
    /// overtake the input it holds back, while `stdinEOF` stays behind it.
    @Test(.timeLimit(.minutes(1)))
    func keepsInputWithinTheWindowAndSendsControlMessagesAheadOfIt() async throws {
        let (host, peer) = try HandshakeTests.socketPair()
        let agentConnection = try FrameConnection(peer)
        let client = GuestAgentClient { () throws(MawError) in host }
        startDetachedThread {
            _ = try? agentConnection.exchangeVersions(until: .now + .seconds(5))
            _ = try? agentConnection.receiveControl(until: .now + .seconds(5), expecting: "exec")
            agentConnection.enqueue(.control(.started(pid: 7)))
            try? agentConnection.flush(until: .now + .seconds(5))
        }
        let process = try await client.exec(ExecRequest(argv: ["sleep", "1000"])) { _, _ in }
        // Three windows and the end: more than the window and the client's queue together.
        let size = 3 * AgentProtocol.inputWindow
        startDetachedThread {
            process.write([UInt8](repeating: 0x79, count: size))
            process.closeInput()
        }

        // What arrives without any `stdinConsumed`: the window's worth of input, no more.
        @Sendable func receive(for duration: Duration) -> (input: Int, messages: [ControlMessage]) {
            var input = 0
            var messages: [ControlMessage] = []
            let deadline = ContinuousClock.now + duration
            while let frame = try? agentConnection.receiveFrame(until: deadline) {
                if frame.type == .stdin {
                    input += frame.payload.count
                } else if let message = try? frame.controlMessage() {
                    messages.append(message)
                }
            }
            return (input, messages)
        }
        let first = await runOnDedicatedThread { receive(for: .milliseconds(500)) }
        #expect(first.input == AgentProtocol.inputWindow)
        #expect(first.messages.isEmpty)

        process.send(.int)
        process.resize(TerminalSize(rows: 30, columns: 100))
        let second = await runOnDedicatedThread { receive(for: .milliseconds(300)) }
        #expect(second.input == 0)
        #expect(second.messages == [.signal(.int), .resize(TerminalSize(rows: 30, columns: 100))])

        // Consumed input makes room for as much again; the end follows the last of the input.
        var remaining = size - AgentProtocol.inputWindow
        var received = 0
        var messages: [ControlMessage] = []
        agentConnection.enqueue(.stdinConsumed(UInt32(AgentProtocol.inputWindow)))
        try agentConnection.flush(until: .now + .seconds(5))
        while remaining > 0 {
            let next = await runOnDedicatedThread { receive(for: .milliseconds(200)) }
            #expect(next.input <= AgentProtocol.inputWindow)
            guard next.input > 0 else { break }
            received += next.input
            remaining -= next.input
            messages += next.messages
            agentConnection.enqueue(.stdinConsumed(UInt32(next.input)))
            try agentConnection.flush(until: .now + .seconds(5))
        }
        #expect(received == size - AgentProtocol.inputWindow)
        if messages.isEmpty {
            messages = await runOnDedicatedThread { receive(for: .milliseconds(200)) }.messages
        }
        #expect(messages == [.stdinEOF])

        agentConnection.enqueue(.control(.exited(.exited(code: 0))))
        try agentConnection.flush(until: .now + .seconds(5))
        #expect(try await process.waitForExit() == .exited(code: 0))
        peer.close()
    }

    /// The process's exit status, or `nil` if it has not ended within `timeout`.
    static func exitStatus(of process: GuestProcess, within timeout: Duration) async
        -> MawProtocol.ExitStatus?
    {
        let outcome = FirstOutcome<MawProtocol.ExitStatus?>()
        return await withCheckedContinuation { continuation in
            outcome.onResult { continuation.resume(returning: $0) }
            Task.detached { outcome.settle(try? await process.waitForExit()) }
            Task.detached {
                try? await Task.sleep(for: timeout)
                outcome.settle(nil)
            }
        }
    }

    @Test func reportsAConnectionThatEndsBeforeTheExit() async throws {
        let client = try Self.scriptedAgent(sending: [.control(.started(pid: 7))], thenClose: true)
        let process = try await client.exec(ExecRequest(argv: ["true"])) { _, _ in }
        await #expect(
            throws: MawError.guestAgentFailed(
                reason: "exec: the connection was closed unexpectedly")
        ) {
            try await process.waitForExit()
        }
    }
}

final class Received: @unchecked Sendable {
    private let lock = ConditionLock()
    private var bytes: [UInt8] = []

    func append(_ buffer: UnsafeRawBufferPointer) {
        lock.withLock { bytes.append(contentsOf: buffer) }
    }

    var text: String {
        lock.withLock { String(decoding: bytes, as: UTF8.self) }
    }
}

/// Delivers the first of several results to one handler.
final class FirstOutcome<Value: Sendable>: @unchecked Sendable {
    private let lock = ConditionLock()
    private var handler: ((Value) -> Void)?
    private var settled = false

    func onResult(_ handler: @escaping (Value) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func settle(_ value: Value) {
        let handler = lock.withLock { () -> ((Value) -> Void)? in
            guard !settled else { return nil }
            settled = true
            return self.handler
        }
        handler?(value)
    }
}

/// Counts bytes that a scripted agent received.
final class ByteCounter: @unchecked Sendable {
    private let lock = ConditionLock()
    private var total = 0

    func add(_ count: Int) {
        lock.withLock { total += count }
    }

    var value: Int { lock.withLock { total } }
}
