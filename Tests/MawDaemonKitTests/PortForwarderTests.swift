import CMawSystem
import Darwin
import Foundation
import MawCore
import MawProtocol
import MawVirtualization
import MawXPC
import Testing
import os

@testable import MawDaemonKit

/// The daemon's `localhost` forwarding with real loopback sockets and a real `DialBackGate`;
/// the test plays the guest agent on the other end of socket pairs.
@Suite(.serialized, .timeLimit(.minutes(2))) struct PortForwarderTests {
    /// How long a test waits for something that normally takes milliseconds.
    static let patience = Duration.seconds(20)

    /// The guest agent's side of one forwarder: it answers the channel, reports listeners, and
    /// connects each `connect` through the gate as the agent would.
    final class FakeAgent: @unchecked Sendable {
        let gate = DialBackGate { _ in }
        let lock = ConditionLock()
        var channel: FrameConnection?
        var channelsOpened = 0
        /// The guest's side of each forwarded connection, by request.
        var connections: [(request: ForwardingConnect, guest: OwnedDescriptor)] = []
        var connects: [ForwardingConnect] = []
        /// Ports whose `connect` the guest refuses.
        var refusedPorts: Set<UInt16> = []

        var openChannel: @Sendable () async throws(MawError) -> OwnedDescriptor {
            { () throws(MawError) -> OwnedDescriptor in
                var fds: [Int32] = [-1, -1]
                guard maw_socketpair(&fds) == 0 else {
                    throw .guestAgentUnavailable(reason: "socketpair")
                }
                let agentSide = OwnedDescriptor(fds[1])
                _ = startDetachedThread { self.serve(agentSide) }
                return OwnedDescriptor(fds[0])
            }
        }

        private func serve(_ descriptor: OwnedDescriptor) {
            guard let connection = try? FrameConnection(descriptor),
                (try? connection.exchangeVersions(until: .now + PortForwarderTests.patience))
                    != nil,
                (try? connection.receiveControl(
                    until: .now + PortForwarderTests.patience, expecting: ""))
                    == .forwarding
            else { return }
            lock.withLock {
                channel = connection
                channelsOpened += 1
            }
            while true {
                guard
                    let message = try? connection.receiveControl(
                        until: nil, expecting: "connect")
                else { return }
                guard case .connect(let request) = message else { continue }
                lock.withLock { connects.append(request) }
                if lock.withLock({ refusedPorts.contains(request.port) }) {
                    send(.connectFailed(id: request.id, reason: "refused"))
                    continue
                }
                dial(request)
            }
        }

        /// Dials the gate as the agent does: a source port below 1024 and the nonce first.
        private func dial(_ request: ForwardingConnect) {
            var fds: [Int32] = [-1, -1]
            guard maw_socketpair(&fds) == 0 else { return }
            let host = OwnedDescriptor(fds[0])
            let guest = OwnedDescriptor(fds[1])
            try? writeAll(Frame.dialBackNonce(request.nonce).encoded, to: guest.rawValue)
            guard gate.admit(sourcePort: 1023) == nil else { return }
            _ = startDetachedThread { [gate] in _ = gate.authenticate(host) }
            lock.withLock { connections.append((request, guest)) }
        }

        func send(_ message: ControlMessage) {
            lock.withLock {
                channel?.enqueue(.control(message))
                try? channel?.flush(until: .now + PortForwarderTests.patience)
            }
        }

        func report(_ listeners: [GuestListener]) {
            send(.listeners(listeners))
        }

        func waitForChannel() async -> Bool {
            await PortForwarderTests.eventually { self.lock.withLock { self.channel != nil } }
        }

        func takeConnection() async -> (request: ForwardingConnect, guest: OwnedDescriptor)? {
            var taken: (ForwardingConnect, OwnedDescriptor)?
            _ = await PortForwarderTests.eventually {
                taken = self.lock.withLock {
                    self.connections.isEmpty ? nil : self.connections.removeFirst()
                }
                return taken != nil
            }
            return taken
        }

        /// Ends the channel, as an agent that exits does.
        func closeChannel() {
            lock.withLock {
                channel?.descriptor.close()
                channel = nil
            }
        }
    }

    final class Changes: Sendable {
        let count = OSAllocatedUnfairLock(initialState: 0)
    }

    static func eventually(within timeout: Duration = patience, _ condition: () async -> Bool)
        async -> Bool
    {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// A port that is free on 127.0.0.1 and ::1 now, without SO_REUSEADDR: no socket of any
    /// state holds it.
    static func freePort() throws -> UInt16 {
        for _ in 0..<200 {
            let port = UInt16.random(in: 20_000...60_000)
            if case .success(let ipv4) = LoopbackListeners.listen(ipv6: false, port: port) {
                defer { ipv4.close() }
                if case .success(let ipv6) = LoopbackListeners.listen(ipv6: true, port: port) {
                    ipv6.close()
                    return port
                }
            }
        }
        throw SystemError("bind", code: EADDRINUSE)
    }

    static func forwarder(
        _ agent: FakeAgent, machine: String = "test", registry: ForwardedPortRegistry = .init(),
        changes: Changes = Changes(), maximumConnections: Int = 256, maximumPorts: Int = 128,
        bind: (@Sendable (UInt16) -> Result<LoopbackListeners, LoopbackListeners.Failure>)? = nil
    ) async throws -> PortForwarder {
        var environment = PortForwarder.Environment(
            openChannel: agent.openChannel, gate: agent.gate, reopenDelay: .milliseconds(20),
            maximumConnections: maximumConnections, maximumPorts: maximumPorts)
        if let bind { environment.bind = bind }
        let forwarder = PortForwarder(
            machine: .distribution(try DistroName(machine)), environment: environment,
            registry: registry, log: DaemonLog(),
            changed: { changes.count.withLock { $0 += 1 } })
        await forwarder.start()
        #expect(await agent.waitForChannel())
        return forwarder
    }

    static func connect(_ ipv6: Bool, _ port: UInt16) -> Result<OwnedDescriptor, SystemError> {
        var descriptor: Int32 = -1
        let code = maw_tcp_connect_loopback(ipv6 ? 1 : 0, port, 2_000, &descriptor)
        return code == 0
            ? .success(OwnedDescriptor(descriptor)) : .failure(SystemError("connect", code: code))
    }

    static func isListening(_ port: UInt16) -> Bool {
        if case .success(let connection) = connect(false, port) {
            connection.close()
            return true
        }
        return false
    }

    static func send(_ text: String, _ descriptor: OwnedDescriptor) throws {
        try writeAll(Array(text.utf8), to: descriptor.rawValue)
    }

    /// Reads until the end of the stream, or the error that ended it.
    static func readToEnd(_ descriptor: OwnedDescriptor) -> (text: String, error: Int32) {
        _ = maw_set_blocking(descriptor.rawValue)
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor.rawValue, &buffer, buffer.count)
            if count > 0 {
                bytes += buffer[..<count]
                continue
            }
            return (String(decoding: bytes, as: UTF8.self), count == 0 ? 0 : errno)
        }
    }

    // MARK: Ports

    @Test func forwardsAPortAndReleasesIt() async throws {
        let agent = FakeAgent()
        let changes = Changes()
        let forwarder = try await Self.forwarder(agent, changes: changes)
        let port = try Self.freePort()
        agent.report([GuestListener(port: port, address: .anyIPv4)])
        #expect(await Self.eventually { forwarder.forwarding.forwarded == [port] })
        #expect(Self.isListening(port))
        #expect(changes.count.withLock { $0 } > 0)

        agent.report([])
        #expect(await Self.eventually { forwarder.forwarding == PortForwarding() })
        #expect(!Self.isListening(port))
        await forwarder.stop()
    }

    @Test func neverBindsAPortBelow1024() async throws {
        let agent = FakeAgent()
        let bound = OSAllocatedUnfairLock(initialState: [UInt16]())
        let forwarder = try await Self.forwarder(
            agent,
            bind: { port in
                bound.withLock { $0.append(port) }
                return .failure(.inUse)
            })
        agent.report([
            GuestListener(port: 80, address: .anyIPv4),
            GuestListener(port: 1023, address: .loopbackIPv6),
        ])
        #expect(
            await Self.eventually {
                forwarder.forwarding
                    == PortForwarding(notForwarded: [
                        .init(port: 80, reason: .privilegedOnMac),
                        .init(port: 1023, reason: .privilegedOnMac),
                    ])
            })
        #expect(bound.withLock { $0 }.isEmpty)
        await forwarder.stop()
    }

    /// A Mac program on 127.0.0.1, or on ::1 only: the port is forwarded on neither address.
    @Test(arguments: [false, true])
    func leavesAPortThatAMacProgramHolds(onIPv6: Bool) async throws {
        let agent = FakeAgent()
        let forwarder = try await Self.forwarder(agent)
        let port = try Self.freePort()
        let program = try LoopbackListeners.listen(ipv6: onIPv6, port: port).get()
        agent.report([GuestListener(port: port, address: .anyIPv4)])
        #expect(
            await Self.eventually {
                forwarder.forwarding
                    == PortForwarding(notForwarded: [.init(port: port, reason: .inUseOnMac)])
            })
        // The other address was not left bound.
        if case .success(let other) = LoopbackListeners.listen(ipv6: !onIPv6, port: port) {
            other.close()
        } else {
            Issue.record("the forwarder kept the free address of a port in use")
        }
        program.close()
        await forwarder.stop()
    }

    @Test func leavesAPortThatAnotherDistributionForwards() async throws {
        let registry = ForwardedPortRegistry()
        let first = FakeAgent()
        let second = FakeAgent()
        let one = try await Self.forwarder(first, machine: "one", registry: registry)
        let two = try await Self.forwarder(second, machine: "two", registry: registry)
        let port = try Self.freePort()
        first.report([GuestListener(port: port, address: .anyIPv4)])
        #expect(await Self.eventually { one.forwarding.forwarded == [port] })
        second.report([GuestListener(port: port, address: .anyIPv6)])
        #expect(
            await Self.eventually {
                two.forwarding
                    == PortForwarding(notForwarded: [
                        .init(port: port, reason: .forwardedForAnotherDistribution)
                    ])
            })
        await one.stop()
        #expect(registry.owner(of: port) == nil)
        await two.stop()
    }

    /// A port that was not forwarded is tried again only when the guest reports it anew.
    @Test func retriesOnlyAPortReportedAnew() async throws {
        let agent = FakeAgent()
        let forwarder = try await Self.forwarder(agent)
        let port = try Self.freePort()
        let other = try Self.freePort()
        let program = try LoopbackListeners.listen(ipv6: false, port: port).get()
        agent.report([GuestListener(port: port, address: .anyIPv4)])
        #expect(await Self.eventually { forwarder.forwarding.notForwarded.count == 1 })
        program.close()

        // The Mac's port is free, but the guest's listener did not change, and another port's
        // change does not retry it.
        agent.report([
            GuestListener(port: port, address: .anyIPv4),
            GuestListener(port: other, address: .anyIPv4),
        ])
        #expect(await Self.eventually { forwarder.forwarding.forwarded == [other] })
        try await Task.sleep(for: .milliseconds(100))
        #expect(forwarder.forwarding.notForwarded == [.init(port: port, reason: .inUseOnMac)])

        // Gone and back: tried again.
        agent.report([GuestListener(port: other, address: .anyIPv4)])
        #expect(await Self.eventually { forwarder.forwarding.notForwarded.isEmpty })
        agent.report([
            GuestListener(port: port, address: .anyIPv4),
            GuestListener(port: other, address: .anyIPv4),
        ])
        #expect(
            await Self.eventually { forwarder.forwarding.forwarded == [port, other].sorted() })
        await forwarder.stop()
    }

    @Test func reportsAnotherBindError() async throws {
        let agent = FakeAgent()
        let forwarder = try await Self.forwarder(
            agent, bind: { _ in .failure(.other(family: "::1", code: EADDRNOTAVAIL)) })
        agent.report([GuestListener(port: 5000, address: .anyIPv4)])
        #expect(
            await Self.eventually {
                forwarder.forwarding
                    == PortForwarding(notForwarded: [.init(port: 5000, reason: .bindFailed)])
            })
        await forwarder.stop()
    }

    @Test func forwardsAtMostItsLimitOfPorts() async throws {
        let agent = FakeAgent()
        let forwarder = try await Self.forwarder(agent, maximumPorts: 2)
        let ports = try (0..<3).map { _ in try Self.freePort() }.sorted()
        agent.report(ports.map { GuestListener(port: $0, address: .anyIPv4) })
        #expect(
            await Self.eventually {
                forwarder.forwarding
                    == PortForwarding(
                        forwarded: Array(ports[0..<2]),
                        notForwarded: [.init(port: ports[2], reason: .limit)])
            })
        await forwarder.stop()
    }

    // MARK: Connections

    @Test func relaysAConnectionWithItsHalfClose() async throws {
        let agent = FakeAgent()
        let forwarder = try await Self.forwarder(agent)
        let port = try Self.freePort()
        agent.report([GuestListener(port: port, address: .loopbackIPv6)])
        #expect(await Self.eventually { forwarder.forwarding.forwarded == [port] })

        // The Mac connects over 127.0.0.1; the guest listens on ::1 only.
        let mac = try Self.connect(false, port).get()
        let (request, guest) = try #require(await agent.takeConnection())
        #expect(request.port == port)
        #expect(request.family == .ipv6)
        try Self.send("GET /", mac)
        _ = shutdown(mac.rawValue, SHUT_WR)
        #expect(Self.readToEnd(guest).text == "GET /")
        try Self.send("200 OK", guest)
        guest.close()
        #expect(Self.readToEnd(mac) == ("200 OK", 0))
        #expect(await Self.eventually { await forwarder.connectionCount == 0 })
        await forwarder.stop()
    }

    @Test func resetsAConnectionBeyondItsLimit() async throws {
        let agent = FakeAgent()
        let forwarder = try await Self.forwarder(agent, maximumConnections: 1)
        let port = try Self.freePort()
        agent.report([GuestListener(port: port, address: .anyIPv4)])
        #expect(await Self.eventually { forwarder.forwarding.forwarded == [port] })
        let first = try Self.connect(false, port).get()
        let (_, guest) = try #require(await agent.takeConnection())
        let second = try Self.connect(false, port).get()
        #expect(Self.readToEnd(second).error == ECONNRESET)
        // The first still works.
        try Self.send("ping", first)
        _ = shutdown(first.rawValue, SHUT_WR)
        #expect(Self.readToEnd(guest).text == "ping")
        await forwarder.stop()
    }

    @Test func endsEveryConnectionAndPortWhenItStops() async throws {
        let agent = FakeAgent()
        let registry = ForwardedPortRegistry()
        let forwarder = try await Self.forwarder(agent, registry: registry)
        let port = try Self.freePort()
        agent.report([GuestListener(port: port, address: .anyIPv4)])
        #expect(await Self.eventually { forwarder.forwarding.forwarded == [port] })
        let mac = try Self.connect(false, port).get()
        let (_, guest) = try #require(await agent.takeConnection())
        await forwarder.stop()
        // Both sides see their connection end: the end of the stream, or a reset.
        #expect([0, ECONNRESET].contains(Self.readToEnd(mac).error))
        #expect(Self.readToEnd(guest).text.isEmpty)
        #expect(!Self.isListening(port))
        #expect(registry.owner(of: port) == nil)
        #expect(forwarder.forwarding == PortForwarding())
    }

    /// A channel that ends is opened again, and the new channel's first report is compared
    /// with what was forwarded, so that a port that still listens stays forwarded.
    @Test func opensTheChannelAgainAfterItEnds() async throws {
        let agent = FakeAgent()
        let forwarder = try await Self.forwarder(agent)
        let port = try Self.freePort()
        agent.report([GuestListener(port: port, address: .anyIPv4)])
        #expect(await Self.eventually { forwarder.forwarding.forwarded == [port] })
        agent.closeChannel()
        #expect(await Self.eventually { agent.lock.withLock { agent.channelsOpened == 2 } })
        #expect(await agent.waitForChannel())
        agent.report([GuestListener(port: port, address: .anyIPv4)])
        try await Task.sleep(for: .milliseconds(50))
        #expect(forwarder.forwarding.forwarded == [port])
        #expect(Self.isListening(port))
        await forwarder.stop()
    }

    /// Decision record 0018: the test that asserts a time.
    @Suite(.serialized) struct Latency {
        @Test func resetsAConnectionTheGuestRefuses() async throws {
            let agent = FakeAgent()
            let forwarder = try await PortForwarderTests.forwarder(agent)
            let port = try PortForwarderTests.freePort()
            agent.lock.withLock { agent.refusedPorts = [port] }
            agent.report([GuestListener(port: port, address: .anyIPv4)])
            #expect(
                await PortForwarderTests.eventually { forwarder.forwarding.forwarded == [port] })
            let mac = try PortForwarderTests.connect(true, port).get()
            let started = ContinuousClock.now
            let (text, error) = PortForwarderTests.readToEnd(mac)
            #expect(text.isEmpty)
            #expect(error == ECONNRESET)
            #expect(ContinuousClock.now - started < .seconds(2))
            #expect(await PortForwarderTests.eventually { await forwarder.connectionCount == 0 })
            await forwarder.stop()
        }
    }
}
