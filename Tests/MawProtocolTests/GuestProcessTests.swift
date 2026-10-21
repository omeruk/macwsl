import MawCore
import Testing

@testable import MawProtocol

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
