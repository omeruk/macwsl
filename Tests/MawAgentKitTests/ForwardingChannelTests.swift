import CMawSystem
import Foundation
import Logging
import MawAgentKit
import MawCore
import MawProtocol
import Testing

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The agent's forwarding channel (docs/protocol.md, "Forwarding"), reached as the host
/// reaches it: a `dialBack` on a host-opened connection, then `forwarding` on the connection
/// the agent dialed. Socket pairs stand in for vsock; the guest's listeners are real loopback
/// TCP sockets of the test process.
@Suite(.serialized) struct ForwardingChannelTests {
    /// The listeners the fake scan reports, and the connections the agent dialed to the host.
    final class Guest: @unchecked Sendable {
        let lock = ConditionLock()
        var listeners: Set<GuestListener> = []
        var dialed: [OwnedDescriptor] = []
        var scanFails = false

        func takeDialed(within timeout: Duration = peerDeadline) -> OwnedDescriptor? {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if let descriptor = lock.withLock({ dialed.isEmpty ? nil : dialed.removeFirst() }) {
                    return descriptor
                }
                usleep(2_000)
            }
            return nil
        }
    }

    static func pair() throws -> (OwnedDescriptor, OwnedDescriptor) {
        var fds: [Int32] = [-1, -1]
        try #require(maw_socketpair(&fds) == 0)
        return (OwnedDescriptor(fds[0]), OwnedDescriptor(fds[1]))
    }

    /// An agent whose `dialBack` and forwarding dials hand their far ends to `guest`.
    static func agent(
        _ guest: Guest, maximumConnections: Int = 64, maximumForwarded: Int = 256,
        forwards: Bool = true
    ) -> AgentServer {
        let dial: @Sendable () throws(DialBackError) -> OwnedDescriptor = {
            () throws(DialBackError) -> OwnedDescriptor in
            var fds: [Int32] = [-1, -1]
            guard maw_socketpair(&fds) == 0 else {
                throw .connectFailed(SystemError("socketpair", code: EMFILE))
            }
            guest.lock.withLock { guest.dialed.append(OwnedDescriptor(fds[1])) }
            return OwnedDescriptor(fds[0])
        }
        let environment = ForwardingEnvironment(
            scanListeners: { () throws(ListenerScanner.ScanError) -> Set<GuestListener> in
                let (listeners, fails) = guest.lock.withLock { (guest.listeners, guest.scanFails) }
                if fails { throw .kernel(-2) }
                return listeners
            }, dialHost: dial, scanInterval: .milliseconds(20),
            maximumConnections: maximumForwarded)
        return AgentServer(
            configuration: AgentConfiguration(
                maximumConnections: maximumConnections, requestTimeout: peerDeadline,
                system: .testing(), dialBack: dial, processDirectory: "/nonexistent/proc",
                forwarding: forwards ? environment : nil
            ) {})
    }

    /// Opens the forwarding channel as the daemon does, and returns the host's side of it.
    static func openChannel(_ server: AgentServer, _ guest: Guest) throws -> FrameConnection {
        let (host, agent) = try pair()
        server.serveOnNewThread(agent)
        let request = try FrameConnection(host)
        let nonce = DialBackNonce.random()
        _ = try request.exchangeVersions(
            until: .now + peerDeadline, thenSending: [.control(.dialBack(nonce))])
        #expect(
            try request.receiveControl(until: .now + peerDeadline, expecting: "") == .dialedBack)
        let dialed = try FrameConnection(try #require(guest.takeDialed()))
        #expect(
            try dialed.receiveFrame(until: .now + peerDeadline).dialBackNonce() == nonce)
        let version = try dialed.exchangeVersions(
            until: .now + peerDeadline, thenSending: [.control(.forwarding)])
        #expect(version == ProtocolVersion.current)
        return dialed
    }

    static func nextMessage(_ channel: FrameConnection) throws -> ControlMessage {
        try channel.receiveControl(until: .now + peerDeadline, expecting: "a message")
    }

    /// A TCP listener of the test process on 127.0.0.1, and its port.
    static func listen() throws -> (OwnedDescriptor, UInt16) {
        var descriptor: Int32 = -1
        try #require(maw_tcp_listen_loopback(0, 0, 16, 0, &descriptor) == 0)
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        return (OwnedDescriptor(descriptor), UInt16(bigEndian: address.sin_port))
    }

    static func accept(_ listener: OwnedDescriptor) throws -> OwnedDescriptor {
        let deadline = ContinuousClock.now + peerDeadline
        while ContinuousClock.now < deadline {
            var descriptor: Int32 = -1
            let code = maw_tcp_accept(listener.rawValue, &descriptor)
            if code == 0 { return OwnedDescriptor(descriptor) }
            try #require(code == EAGAIN || code == EWOULDBLOCK)
            usleep(2_000)
        }
        throw SystemError("accept", code: ETIMEDOUT)
    }

    static func send(_ text: String, to descriptor: OwnedDescriptor) throws {
        try writeAll(Array(text.utf8), to: descriptor.rawValue)
    }

    /// Reads until the end of the stream.
    static func readToEnd(_ descriptor: OwnedDescriptor) -> String {
        _ = maw_set_blocking(descriptor.rawValue)
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor.rawValue, &buffer, buffer.count)
            guard count > 0 else { break }
            bytes += buffer[..<count]
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test func reportsTheListenersAndEachChange() throws {
        let guest = Guest()
        guest.listeners = [GuestListener(port: 8000, address: .anyIPv4)]
        let channel = try Self.openChannel(Self.agent(guest), guest)
        #expect(
            try Self.nextMessage(channel)
                == .listeners([GuestListener(port: 8000, address: .anyIPv4)]))
        guest.lock.withLock {
            guest.listeners = [
                GuestListener(port: 9000, address: .loopbackIPv6),
                GuestListener(port: 3000, address: .anyIPv4),
            ]
        }
        #expect(
            try Self.nextMessage(channel)
                == .listeners([
                    GuestListener(port: 3000, address: .anyIPv4),
                    GuestListener(port: 9000, address: .loopbackIPv6),
                ]))
        guest.lock.withLock { guest.listeners = [] }
        #expect(try Self.nextMessage(channel) == .listeners([]))
    }

    @Test func reportsNoListenersWhenTheFirstScanFails() throws {
        let guest = Guest()
        guest.scanFails = true
        let channel = try Self.openChannel(Self.agent(guest), guest)
        #expect(try Self.nextMessage(channel) == .listeners([]))
    }

    /// Scans that keep failing withdraw the listeners reported before, and a scan that
    /// succeeds again reports them anew.
    @Test func withdrawsTheListenersWhenScansKeepFailing() throws {
        let guest = Guest()
        let listener = GuestListener(port: 8000, address: .anyIPv4)
        guest.listeners = [listener]
        let channel = try Self.openChannel(Self.agent(guest), guest)
        #expect(try Self.nextMessage(channel) == .listeners([listener]))
        let failed = ContinuousClock.now
        guest.lock.withLock { guest.scanFails = true }
        #expect(try Self.nextMessage(channel) == .listeners([]))
        #expect(ContinuousClock.now - failed >= .seconds(1))
        guest.lock.withLock { guest.scanFails = false }
        #expect(try Self.nextMessage(channel) == .listeners([listener]))
    }

    /// The host accepts at most `AgentProtocol.maximumListeners` listeners in a message: the
    /// lowest ports are reported.
    @Test func reportsAtMostTheHostsLimitOfListeners() throws {
        let guest = Guest()
        let all = (1...(AgentProtocol.maximumListeners + 10)).map {
            GuestListener(port: UInt16(1_000 + $0), address: .anyIPv4)
        }
        guest.listeners = Set(all)
        let channel = try Self.openChannel(Self.agent(guest), guest)
        #expect(
            try Self.nextMessage(channel)
                == .listeners(Array(all.prefix(AgentProtocol.maximumListeners))))
    }

    @Test func relaysAConnectionWithItsHalfClose() throws {
        let guest = Guest()
        let (listener, port) = try Self.listen()
        let channel = try Self.openChannel(Self.agent(guest), guest)
        _ = try Self.nextMessage(channel)
        let nonce = DialBackNonce.random()
        channel.enqueue(
            .control(.connect(ForwardingConnect(id: 7, port: port, family: .ipv4, nonce: nonce))))
        try channel.flush(until: .now + peerDeadline)

        let server = try Self.accept(listener)
        let host = try #require(guest.takeDialed())
        // The dialed connection starts with the nonce frame, and carries raw bytes after it.
        var header = [UInt8](repeating: 0, count: 37)
        _ = maw_set_blocking(host.rawValue)
        #expect(read(host.rawValue, &header, 37) == 37)
        #expect(Array(header[0..<5]) == [0, 0, 0, 32, FrameType.dialBackNonce.rawValue])
        #expect(DialBackNonce(bytes: Array(header[5...])) == nonce)

        // The Mac's side sends a request and half-closes; the guest's server sees the end,
        // answers, and closes.
        try Self.send("GET /", to: host)
        _ = shutdown(host.rawValue, Int32(SHUT_WR))
        #expect(Self.readToEnd(server) == "GET /")
        try Self.send("200 OK", to: server)
        server.close()
        #expect(Self.readToEnd(host) == "200 OK")
    }

    @Test func connectsOverIPv6() throws {
        let guest = Guest()
        var descriptor: Int32 = -1
        try #require(maw_tcp_listen_loopback(1, 0, 16, 0, &descriptor) == 0)
        let listener = OwnedDescriptor(descriptor)
        var address = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        let channel = try Self.openChannel(Self.agent(guest), guest)
        _ = try Self.nextMessage(channel)
        channel.enqueue(
            .control(
                .connect(
                    ForwardingConnect(
                        id: 1, port: UInt16(bigEndian: address.sin6_port), family: .ipv6,
                        nonce: .random()))))
        try channel.flush(until: .now + peerDeadline)
        _ = try Self.accept(listener)
        #expect(guest.takeDialed() != nil)
    }

    @Test func reportsAConnectionTheGuestRefuses() throws {
        let guest = Guest()
        let (listener, port) = try Self.listen()
        listener.close()
        let channel = try Self.openChannel(Self.agent(guest), guest)
        _ = try Self.nextMessage(channel)
        channel.enqueue(
            .control(
                .connect(ForwardingConnect(id: 3, port: port, family: .ipv4, nonce: .random()))))
        try channel.flush(until: .now + peerDeadline)
        guard case .connectFailed(let id, let reason) = try Self.nextMessage(channel) else {
            Issue.record("expected connectFailed")
            return
        }
        #expect(id == 3)
        #expect(reason.contains("connect"))
        // Nothing was dialed for it.
        #expect(guest.takeDialed(within: .milliseconds(100)) == nil)
    }

    @Test func refusesAConnectionBeyondItsLimit() throws {
        let guest = Guest()
        let (listener, port) = try Self.listen()
        let channel = try Self.openChannel(Self.agent(guest, maximumForwarded: 1), guest)
        _ = try Self.nextMessage(channel)
        for id in UInt32(1)...2 {
            channel.enqueue(
                .control(
                    .connect(ForwardingConnect(id: id, port: port, family: .ipv4, nonce: .random()))
                ))
        }
        try channel.flush(until: .now + peerDeadline)
        #expect(
            try Self.nextMessage(channel)
                == .connectFailed(id: 2, reason: "the agent forwards 1 connections already"))
        let server = try Self.accept(listener)
        let host = try #require(guest.takeDialed())
        // Once the first ends, a new one is admitted.
        server.close()
        host.close()
        let deadline = ContinuousClock.now + peerDeadline
        var admitted = false
        while !admitted && ContinuousClock.now < deadline {
            channel.enqueue(
                .control(
                    .connect(ForwardingConnect(id: 9, port: port, family: .ipv4, nonce: .random())))
            )
            try channel.flush(until: .now + peerDeadline)
            if guest.takeDialed(within: .milliseconds(200)) != nil {
                admitted = true
            } else {
                _ = try Self.nextMessage(channel)
            }
        }
        #expect(admitted)
    }

    /// The channel does not hold one of the agent's session slots, and a second channel is
    /// refused.
    @Test func leavesItsSlotToSessionsAndAllowsOneChannel() async throws {
        let guest = Guest()
        let server = Self.agent(guest, maximumConnections: 1)
        let channel = try Self.openChannel(server, guest)
        _ = try Self.nextMessage(channel)
        let client = GuestAgentClient(replyTimeout: peerDeadline) { () throws(MawError) in
            var fds: [Int32] = [-1, -1]
            _ = maw_socketpair(&fds)
            server.serveOnNewThread(OwnedDescriptor(fds[1]))
            return OwnedDescriptor(fds[0])
        }
        #expect(try await client.info().protocolVersion == ProtocolVersion.current)

        let second = try Self.openChannel(server, guest)
        guard case .error(let error) = try Self.nextMessage(second) else {
            Issue.record("expected the second channel to be refused")
            return
        }
        #expect(error.code == .busy)
    }

    @Test func refusesForwardingOnAConnectionTheHostOpened() throws {
        let guest = Guest()
        let (host, agent) = try Self.pair()
        Self.agent(guest).serveOnNewThread(agent)
        let connection = try FrameConnection(host)
        _ = try connection.exchangeVersions(
            until: .now + peerDeadline, thenSending: [.control(.forwarding)])
        guard case .error(let error) = try Self.nextMessage(connection) else {
            Issue.record("expected an error")
            return
        }
        #expect(error.code == .protocolViolation)
    }

    @Test func refusesForwardingWhereTheAgentCannotForward() throws {
        let guest = Guest()
        let channel = try Self.openChannel(Self.agent(guest, forwards: false), guest)
        guard case .error(let error) = try Self.nextMessage(channel) else {
            Issue.record("expected an error")
            return
        }
        #expect(error.code == .busy)
    }

    @Test func closesTheChannelOnAnotherMessage() throws {
        let guest = Guest()
        let channel = try Self.openChannel(Self.agent(guest), guest)
        _ = try Self.nextMessage(channel)
        channel.enqueue(.control(.info))
        try channel.flush(until: .now + peerDeadline)
        guard case .error(let error) = try Self.nextMessage(channel) else {
            Issue.record("expected an error")
            return
        }
        #expect(error.code == .protocolViolation)
    }
}
