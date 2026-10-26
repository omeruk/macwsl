import CMawSystem
import MawAgentKit
import MawCore
import MawProtocol
import Testing

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The agent's dial for a `dialBack` request: the choice of source port and the reports of
/// failures, with the system calls replaced.
@Suite struct DialBackDialerTests {
    @Test func bindsTheHighestPortBelow1024() throws {
        let fake = FakeDialSystem()
        let descriptor = try DialBackDialer(system: fake.system).dial()
        #expect(descriptor.rawValue >= 0)
        #expect(fake.attemptedPorts == [1023])
        #expect(fake.connectedPorts == [AgentProtocol.dialBackPort])
    }

    @Test func skipsPortsInUse() throws {
        let fake = FakeDialSystem(portsInUse: [1023, 1022, 1021])
        _ = try DialBackDialer(system: fake.system).dial()
        #expect(fake.attemptedPorts == [1023, 1022, 1021, 1020])
    }

    @Test func reportsThatEveryPortIsInUse() {
        let fake = FakeDialSystem(portsInUse: Set(1...1023))
        #expect(throws: DialBackError.noFreePort) {
            try DialBackDialer(system: fake.system).dial()
        }
        #expect(fake.attemptedPorts == Array((1...1023).reversed()))
        #expect(fake.connectedPorts.isEmpty)
        #expect(fake.allSocketsClosed)
    }

    /// An agent without CAP_NET_BIND_SERVICE does not try the next port: none would work.
    @Test func reportsAPortItMayNotBind() {
        let fake = FakeDialSystem(bindError: EACCES)
        #expect(throws: DialBackError.bindFailed(port: 1023, SystemError("bind", code: EACCES))) {
            try DialBackDialer(system: fake.system).dial()
        }
        #expect(fake.attemptedPorts == [1023])
        #expect(fake.allSocketsClosed)
    }

    @Test func reportsASocketThatCannotBeCreated() {
        let fake = FakeDialSystem(socketError: EMFILE)
        #expect(throws: DialBackError.socketFailed(SystemError("socket", code: EMFILE))) {
            try DialBackDialer(system: fake.system).dial()
        }
    }

    @Test func reportsARefusedConnection() {
        let fake = FakeDialSystem(connectResult: ECONNRESET)
        #expect(throws: DialBackError.connectFailed(SystemError("connect", code: ECONNRESET))) {
            try DialBackDialer(system: fake.system).dial()
        }
        #expect(fake.allSocketsClosed)
    }

    @Test func reportsAConnectionThatFailsWhileInProgress() {
        let fake = FakeDialSystem(connectResult: EINPROGRESS, pendingError: ETIMEDOUT)
        #expect(throws: DialBackError.connectFailed(SystemError("connect", code: ETIMEDOUT))) {
            try DialBackDialer(system: fake.system).dial()
        }
        #expect(fake.allSocketsClosed)
    }

    @Test func completesAConnectionInProgress() throws {
        let fake = FakeDialSystem(connectResult: EINPROGRESS)
        let descriptor = try DialBackDialer(system: fake.system).dial()
        #expect(descriptor.rawValue >= 0)
    }

    /// A connection that never completes is given up at the timeout, not waited for.
    @Test func givesUpAtTheTimeout() async {
        let fake = FakeDialSystem(connectResult: EINPROGRESS, neverWritable: true)
        // On a thread of its own: the dial waits for its timeout.
        let (result, elapsed) = await runOnDedicatedThread {
            () -> (Result<OwnedDescriptor, DialBackError>, Duration) in
            let start = ContinuousClock.now
            let result = Result { () throws(DialBackError) in
                try DialBackDialer(system: fake.system, timeout: .milliseconds(200)).dial()
            }
            return (result, ContinuousClock.now - start)
        }
        #expect(throws: DialBackError.timedOut(.milliseconds(200))) { try result.get() }
        #expect(elapsed >= .milliseconds(200) && elapsed < .seconds(2), "\(elapsed)")
        #expect(fake.allSocketsClosed)
    }

    @Test func describesEachFailure() {
        #expect(DialBackError.noFreePort.description == "no source port below 1024 is free")
        #expect(
            DialBackError.timedOut(.seconds(2)).description
                == "the connection to the host did not complete within 2000 ms")
        #expect(
            DialBackError.bindFailed(port: 1023, SystemError("bind", code: EACCES)).description
                == "cannot bind source port 1023: bind: Permission denied")
    }
}

/// The agent's server answering `dialBack`, over socket pairs.
@Suite struct DialBackServerTests {
    /// The agent sends the nonce first on the connection it dialed, then serves that
    /// connection as a new one; the request connection ends with `dialedBack`.
    @Test func servesTheConnectionItDials() async throws {
        let dialed = try DialedPair()
        let agent = TestAgent(dialBack: dialed.agentSide)
        let nonce = DialBackNonce.random()

        let request = try FrameConnection(try agent.connect())
        let host = dialed.host.rawValue
        // On a thread of its own: each step waits for the agent.
        let (version, reply, ending, nonceFrame) = try await runOnDedicatedThread {
            () throws(ConnectionError) -> (
                UInt32, ControlMessage, Result<Frame, ConnectionError>, [UInt8]?
            ) in
            let deadline = ContinuousClock.now + .seconds(10)
            let version = try request.exchangeVersions(until: deadline)
            request.enqueue(.control(.dialBack(nonce)))
            try request.flush(until: deadline)
            let reply = try request.receiveControl(until: deadline, expecting: "dialedBack")
            let ending = Result { () throws(ConnectionError) in
                try request.receiveFrame(until: deadline)
            }
            // Exactly the nonce frame, as the host reads it, and nothing of what follows.
            return (version, reply, ending, readExactly(host, count: 5 + 32))
        }
        #expect(version == ProtocolVersion.current)
        #expect(reply == .dialedBack)
        #expect(throws: ConnectionError.closed) { try ending.get() }

        let first = try #require(nonceFrame)
        var decoder = FrameDecoder()
        decoder.append(first)
        #expect(try decoder.nextFrame()?.dialBackNonce() == nonce)

        let client = GuestAgentClient { () throws(MawError) in dialed.host }
        let output = Output()
        let process = try await client.exec(
            ExecRequest(argv: ["/bin/echo", "dialed"]), output: output.handler)
        #expect(try await process.waitForExit() == .exited(code: 0))
        #expect(output.standardOutput == "dialed\n")
        #expect(dialed.dials.value == 1)
    }

    @Test(arguments: [
        DialBackError.noFreePort,
        .timedOut(.seconds(2)),
        .bindFailed(port: 1023, SystemError("bind", code: EACCES)),
        .connectFailed(SystemError("connect", code: ECONNRESET)),
    ])
    func reportsAFailedDial(_ failure: DialBackError) async throws {
        let agent = TestAgent(dialBack: { () throws(DialBackError) -> OwnedDescriptor in
            throw failure
        })
        let reply = try await request(.dialBack(.random()), from: agent)
        #expect(reply == .error(AgentError(.dialBackFailed, failure.description)))
    }

    /// A connection the agent dialed is the host's session: it cannot ask for another dial.
    @Test func refusesDialBackOnTheDialedConnection() async throws {
        let dialed = try DialedPair()
        let agent = TestAgent(dialBack: dialed.agentSide)
        #expect(try await request(.dialBack(.random()), from: agent) == .dialedBack)
        let host = dialed.host.rawValue
        _ = try #require(await runOnDedicatedThread { readExactly(host, count: 5 + 32) })

        let reply = try await request(.dialBack(.random()), on: try FrameConnection(dialed.host))
        guard case .error(let error) = reply else {
            Issue.record("expected an error, received \(reply.name)")
            return
        }
        #expect(error.code == .protocolViolation)
        #expect(error.message.contains("dialed"))
        #expect(dialed.dials.value == 1)
    }

    /// `dialBack` is a request: after `exec` the connection carries the session, and the
    /// message is a protocol violation there.
    @Test func refusesDialBackDuringAnExecSession() async throws {
        let dials = Counter()
        let agent = TestAgent(dialBack: { () throws(DialBackError) -> OwnedDescriptor in
            dials.increment()
            throw .noFreePort
        })
        let connection = try FrameConnection(try agent.connect())
        // On a thread of its own: each step waits for the agent.
        let (started, reply) = try await runOnDedicatedThread {
            () throws(ConnectionError) -> (ControlMessage, ControlMessage?) in
            let deadline = ContinuousClock.now + .seconds(10)
            _ = try connection.exchangeVersions(until: deadline)
            connection.enqueue(.control(.exec(ExecRequest(argv: ["sleep", "1000"]))))
            try connection.flush(until: deadline)
            let started = try connection.receiveControl(until: deadline, expecting: "started")
            guard case .started = started else { return (started, nil) }
            connection.enqueue(.control(.dialBack(.random())))
            return (started, try GuestAgentClientReply.next(on: connection, until: deadline))
        }
        guard case .started = started, let reply else {
            Issue.record("the process did not start")
            return
        }
        guard case .error(let error) = reply else {
            Issue.record("expected an error, received \(reply.name)")
            return
        }
        #expect(error.code == .protocolViolation)
        #expect(error.message == "dialBack is not valid during an exec session")
        #expect(dials.value == 0)
    }

    /// Sends `message` as the request of a new connection to `agent` and returns the reply.
    private func request(_ message: ControlMessage, from agent: TestAgent) async throws
        -> ControlMessage
    {
        try await request(message, on: try FrameConnection(try agent.connect()))
    }

    private func request(_ message: ControlMessage, on connection: FrameConnection) async throws
        -> ControlMessage
    {
        // On a thread of its own: each step waits for the agent.
        try await runOnDedicatedThread { () throws(ConnectionError) in
            let deadline = ContinuousClock.now + .seconds(10)
            _ = try connection.exchangeVersions(until: deadline)
            connection.enqueue(.control(message))
            return try GuestAgentClientReply.next(on: connection, until: deadline)
        }
    }
}

/// The next control message, skipping `stdinConsumed` frames, after sending what is queued.
enum GuestAgentClientReply {
    static func next(on connection: FrameConnection, until deadline: ContinuousClock.Instant)
        throws(ConnectionError) -> ControlMessage
    {
        try connection.flush(until: deadline)
        while true {
            let frame = try connection.receiveFrame(until: deadline, expecting: "a reply")
            if frame.type == .control {
                do throws(FrameError) {
                    return try frame.controlMessage()
                } catch {
                    throw .frame(error)
                }
            }
        }
    }
}

/// A socket pair standing in for the connection the agent dials: the agent gets one end, once,
/// and the test holds the host's end.
final class DialedPair: Sendable {
    let host: OwnedDescriptor
    private let agent: OwnedDescriptor
    let dials = Counter()

    init() throws {
        var fds: [Int32] = [-1, -1]
        let error = maw_socketpair(&fds)
        guard error == 0 else { throw SystemError("socketpair", code: error) }
        host = OwnedDescriptor(fds[0])
        agent = OwnedDescriptor(fds[1])
    }

    var agentSide: @Sendable () throws(DialBackError) -> OwnedDescriptor {
        { [self] () throws(DialBackError) -> OwnedDescriptor in
            dials.increment()
            return OwnedDescriptor(agent.take())
        }
    }
}

/// Reads exactly `count` bytes from a blocking or non-blocking descriptor, or returns `nil` at
/// end-of-file or after 10 seconds.
func readExactly(_ descriptor: Int32, count: Int) -> [UInt8]? {
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: count)
    let deadline = ContinuousClock.now + .seconds(10)
    while bytes.count < count {
        var request = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)]
        guard (try? pollDescriptors(&request, timeout: pollTimeout(until: deadline))) ?? 0 > 0
        else { return nil }
        let got = buffer.withUnsafeMutableBytes {
            read(descriptor, $0.baseAddress, count - bytes.count)
        }
        if got < 0 && errno == EINTR { continue }
        guard got > 0 else { return nil }
        bytes += buffer[..<got]
    }
    return bytes
}

/// A dial's system calls with outcomes the test chooses. Sockets are socket pair ends, which
/// are writable at once; with `neverWritable`, one whose buffer is full and never drained.
final class FakeDialSystem: @unchecked Sendable {
    private let lock = ConditionLock()
    private var attempts: [UInt32] = []
    private var connects: [UInt32] = []
    private var sockets: [OwnedDescriptor] = []
    private var peers: [OwnedDescriptor] = []
    private let portsInUse: Set<UInt32>
    private let bindError: Int32
    private let socketError: Int32
    private let connectResult: Int32
    private let pendingErrorValue: Int32
    private let neverWritable: Bool

    init(
        portsInUse: Set<UInt32> = [], bindError: Int32 = 0, socketError: Int32 = 0,
        connectResult: Int32 = 0, pendingError: Int32 = 0, neverWritable: Bool = false
    ) {
        self.portsInUse = portsInUse
        self.bindError = bindError
        self.socketError = socketError
        self.connectResult = connectResult
        self.pendingErrorValue = pendingError
        self.neverWritable = neverWritable
    }

    var attemptedPorts: [UInt32] { lock.withLock { attempts } }
    var connectedPorts: [UInt32] { lock.withLock { connects } }
    /// Whether every socket the dialer opened has been closed.
    var allSocketsClosed: Bool { lock.withLock { sockets.allSatisfy { $0.rawValue < 0 } } }

    var system: DialBackSystem {
        DialBackSystem(
            openSocket: { [self] () throws(SystemError) -> OwnedDescriptor in
                if socketError != 0 { throw SystemError("socket", code: socketError) }
                var fds: [Int32] = [-1, -1]
                let error = maw_socketpair(&fds)
                guard error == 0 else { throw SystemError("socketpair", code: error) }
                let socket = OwnedDescriptor(fds[0])
                if neverWritable {
                    fill(fds[0])
                }
                lock.withLock {
                    sockets.append(socket)
                    peers.append(OwnedDescriptor(fds[1]))
                }
                return socket
            },
            bind: { [self] _, port in
                lock.withLock { attempts.append(port) }
                return portsInUse.contains(port) ? EADDRINUSE : bindError
            },
            connect: { [self] _, port in
                lock.withLock { connects.append(port) }
                return connectResult
            },
            pendingError: { [self] _ in pendingErrorValue })
    }

    /// Writes to a non-blocking socket until it accepts nothing more.
    private func fill(_ descriptor: Int32) {
        _ = maw_set_nonblocking(descriptor)
        let chunk = [UInt8](repeating: 0, count: 64 << 10)
        while chunk.withUnsafeBytes({ maw_send(descriptor, $0.baseAddress!, $0.count) }) > 0 {}
    }
}
