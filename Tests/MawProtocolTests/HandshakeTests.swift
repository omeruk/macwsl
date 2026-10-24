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
        #expect(
            try hostConnection.exchangeVersions(until: .now + .seconds(5))
                == ProtocolVersion.current)
        #expect(await peerVersion == ProtocolVersion.current)
    }

    @Test func clientReportsAGuestWithAnotherVersion() async throws {
        let (host, peer) = try Self.socketPair()
        let client = GuestAgentClient { () throws(MawError) in host }
        // A guest from a future build: it sends the next version and closes after the mismatch.
        let future = ProtocolVersion.current + 1
        startDetachedThread {
            guard let connection = try? FrameConnection(peer) else { return }
            connection.enqueue(.version(future))
            try? connection.flush(until: .now + .seconds(5))
            _ = try? connection.receiveFrame(until: .now + .seconds(5))
            peer.close()
        }
        await #expect(
            throws: MawError.guestAgentVersionMismatch(host: ProtocolVersion.current, guest: future)
        ) {
            try await client.info()
        }
    }

    /// An agent from a build before version 3, as it answers a newer host: its version, then
    /// an error naming both versions.
    @Test func clientReportsAnAgentFromAnEarlierBuild() async throws {
        let (host, peer) = try Self.socketPair()
        let client = GuestAgentClient { () throws(MawError) in host }
        let earlier = ProtocolVersion.current - 1
        startDetachedThread {
            guard let connection = try? FrameConnection(peer) else { return }
            connection.enqueue(.version(earlier))
            connection.enqueue(
                .control(
                    .error(
                        AgentError(
                            .versionMismatch, "mismatch", hostVersion: ProtocolVersion.current,
                            guestVersion: earlier))))
            try? connection.flush(until: .now + .seconds(5))
            _ = try? connection.receiveFrame(until: .now + .seconds(5))
            peer.close()
        }
        await #expect(
            throws: MawError.guestAgentVersionMismatch(
                host: ProtocolVersion.current, guest: earlier)
        ) {
            _ = try await client.exec(ExecRequest(argv: ["true"])) { _, _ in }
        }
    }

    /// `dialBack` against the agent's server: the agent dials, sends the nonce first on the
    /// dialed connection, and replies `dialedBack`.
    @Test func asksTheAgentToDialBack() async throws {
        let (request, agentSide) = try Self.socketPair()
        let (dialedHost, dialedAgent) = try Self.socketPair()
        let server = AgentServer(
            configuration: AgentConfiguration(
                dialBack: { () throws(DialBackError) -> OwnedDescriptor in dialedAgent },
                powerOff: {}))
        server.serveOnNewThread(agentSide)
        let client = GuestAgentClient { () throws(MawError) in request }
        let nonce = DialBackNonce.random()
        try await client.dialBack(nonce)

        let connection = try FrameConnection(dialedHost)
        let first = try await runOnDedicatedThread { () throws(ConnectionError) -> Frame in
            try connection.receiveFrame(until: .now + .seconds(5))
        }
        #expect(try first.dialBackNonce() == nonce)
    }

    @Test func reportsADialBackThatTheAgentCouldNotMake() async throws {
        let (request, agentSide) = try Self.socketPair()
        let server = AgentServer(
            configuration: AgentConfiguration(
                dialBack: { () throws(DialBackError) -> OwnedDescriptor in throw .noFreePort },
                powerOff: {}))
        server.serveOnNewThread(agentSide)
        let client = GuestAgentClient { () throws(MawError) in request }
        await #expect(
            throws: MawError.sessionDialBackFailed(reason: "no source port below 1024 is free")
        ) {
            try await client.dialBack(.random())
        }
    }

    @Test func mapsAFailedDialBack() {
        #expect(
            GuestAgentClient.map(
                .remote(AgentError(.dialBackFailed, "no source port below 1024 is free")),
                during: "dialBack")
                == .sessionDialBackFailed(reason: "no source port below 1024 is free"))
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
        let current = ProtocolVersion.current
        let error = AgentError(
            .versionMismatch, "the host speaks protocol version 9, the agent version \(current)",
            hostVersion: 9, guestVersion: current)
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
                == .guestAgentVersionMismatch(host: 9, guest: current))
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
