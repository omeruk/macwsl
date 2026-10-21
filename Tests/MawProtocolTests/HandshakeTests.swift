import CMawSystem
import MawAgentKit
import MawCore
import Testing

@testable import MawProtocol

@Suite struct HandshakeTests {
    /// A connected socket pair: `host` for the side under test, `peer` for the scripted side.
    static func socketPair() throws -> (host: OwnedDescriptor, peer: OwnedDescriptor) {
        var fds: [Int32] = [-1, -1]
        try #require(maw_socketpair(&fds) == 0)
        return (OwnedDescriptor(fds[0]), OwnedDescriptor(fds[1]))
    }

    @Test func exchangesMatchingVersions() async throws {
        let (host, peer) = try Self.socketPair()
        // Both sides send before they read, so neither waits for the other.
        async let peerVersion = runOnDedicatedThread { () -> UInt32? in
            let connection = try? FrameConnection(peer)
            return try? connection?.exchangeVersions(until: .now + .seconds(5))
        }
        let hostConnection = try FrameConnection(host)
        #expect(try hostConnection.exchangeVersions(until: .now + .seconds(5)) == 1)
        #expect(await peerVersion == ProtocolVersion.current)
    }

    @Test func clientReportsAGuestWithAnotherVersion() async throws {
        let (host, peer) = try Self.socketPair()
        let client = GuestAgentClient { () throws(MawError) in host }
        // A guest from a future build: it sends version 2 and closes after the mismatch.
        startDetachedThread {
            guard let connection = try? FrameConnection(peer) else { return }
            connection.enqueue(.version(2))
            try? connection.flush(until: .now + .seconds(5))
            _ = try? connection.receiveFrame(until: .now + .seconds(5))
            peer.close()
        }
        await #expect(throws: MawError.guestAgentVersionMismatch(host: 1, guest: 2)) {
            try await client.info()
        }
    }

    @Test func agentRejectsAHostWithAnotherVersion() async throws {
        let (host, peer) = try Self.socketPair()
        let server = AgentServer(configuration: AgentConfiguration(powerOff: {}))
        server.serveOnNewThread(peer)

        let connection = try FrameConnection(host)
        connection.enqueue(.version(9))
        try connection.flush(until: .now + .seconds(5))
        let reply = try await runOnDedicatedThread { () throws(ConnectionError) -> [Frame] in
            [
                try connection.receiveFrame(until: .now + .seconds(5)),
                try connection.receiveFrame(until: .now + .seconds(5)),
            ]
        }
        #expect(try reply[0].protocolVersion() == ProtocolVersion.current)
        let error = AgentError(
            .versionMismatch, "the host speaks protocol version 9, the agent version 1",
            hostVersion: 9, guestVersion: 1)
        #expect(try reply[1].controlMessage() == .error(error))
        // Then the agent closes the connection.
        let end = await runOnDedicatedThread { () -> Bool in
            do {
                _ = try connection.receiveFrame(until: .now + .seconds(5))
                return false
            } catch {
                return error as? ConnectionError == .closed
            }
        }
        #expect(end)
        #expect(
            GuestAgentClient.map(.remote(error), during: "info")
                == .guestAgentVersionMismatch(host: 9, guest: 1))
    }

    @Test func clientTimesOutOnASilentPeer() async throws {
        let (host, peer) = try Self.socketPair()
        let client = GuestAgentClient(replyTimeout: .milliseconds(200)) {
            () throws(MawError) in host
        }
        await #expect {
            try await client.info()
        } throws: { error in
            guard case .guestAgentUnavailable = error as? MawError else { return false }
            return true
        }
        withExtendedLifetime(peer) {}
    }
}
