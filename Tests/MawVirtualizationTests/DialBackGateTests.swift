import Darwin
import MawCore
import MawProtocol
import Testing
import os

@testable import MawVirtualization

@Suite struct DialBackGateTests {
    // MARK: Admission, before anything is read

    @Test(arguments: [UInt32(1024), 1025, 49152, UInt32.max])
    func refusesAnUnprivilegedSourcePort(_ port: UInt32) throws {
        let gate = TestGate()
        _ = try gate.gate.expect()
        #expect(gate.gate.admit(sourcePort: port) == .unprivilegedSourcePort(port))
        #expect(gate.gate.admit(sourcePort: 1023) == nil)
    }

    @Test func refusesAConnectionWhileNoSessionWaits() throws {
        let gate = TestGate()
        #expect(gate.gate.admit(sourcePort: 1023) == .noPendingRequest)
        let pending = try gate.gate.expect()
        gate.gate.cancel(pending)
        #expect(gate.gate.admit(sourcePort: 1023) == .noPendingRequest)
    }

    @Test func refusesAConnectionOnceTheOnlyNonceHasExpired() throws {
        let gate = TestGate()
        _ = try gate.gate.expect()
        gate.clock.advance(by: .seconds(5))
        #expect(gate.gate.admit(sourcePort: 1023) == .noPendingRequest)
    }

    /// However many sessions open at once, each one's dial finds a place: N waiting sessions
    /// admit N dials that have not yet sent their nonce.
    @Test(arguments: [1, 32, 64])
    func admitsADialForEveryWaitingSessionInABurst(_ sessions: Int) throws {
        let gate = TestGate()
        for _ in 0..<sessions {
            _ = try gate.gate.expect()
        }
        for dial in 0..<sessions {
            #expect(gate.gate.admit(sourcePort: 1023) == nil, "dial \(dial + 1) of \(sessions)")
        }
        #expect(gate.reports.isEmpty)
    }

    @Test func refusesEveryDialWhileNoSessionWaits() {
        let gate = TestGate()
        for _ in 0..<10 {
            #expect(gate.gate.admit(sourcePort: 1023) == .noPendingRequest)
        }
    }

    /// Beyond one place for each waiting session, 4 admitted connections may be without a
    /// nonce; the next is refused until one of them has been authenticated, refused, or
    /// abandoned.
    @Test(arguments: [1, 3, 64])
    func capsTheConnectionsThatHaveNotSentTheirNonce(_ sessions: Int) async throws {
        let gate = TestGate()
        for _ in 0..<sessions {
            _ = try gate.gate.expect()
        }
        let limit = sessions + 4
        for _ in 0..<limit {
            #expect(gate.gate.admit(sourcePort: 1023) == nil)
        }
        #expect(gate.gate.admit(sourcePort: 1023) == .tooManyUnauthenticated(limit: limit))
        #expect(gate.gate.admit(sourcePort: 1022) == .tooManyUnauthenticated(limit: limit))

        let pair = try SocketPair()
        pair.closeGuestSide()
        #expect(
            gate.gate.authenticate(pair.host)
                == .nonceNotReceived("the connection closed after 0 bytes"))
        #expect(gate.gate.admit(sourcePort: 1023) == nil)
        #expect(gate.gate.admit(sourcePort: 1023) == .tooManyUnauthenticated(limit: limit))

        gate.gate.abandon()
        #expect(gate.gate.admit(sourcePort: 1023) == nil)
    }

    /// The places follow the waiting sessions: once a session's request is withdrawn, its
    /// place goes with it.
    @Test func givesUpThePlaceOfASessionThatNoLongerWaits() throws {
        let gate = TestGate()
        let first = try gate.gate.expect()
        _ = try gate.gate.expect()
        for _ in 0..<6 {
            #expect(gate.gate.admit(sourcePort: 1023) == nil)
        }
        #expect(gate.gate.admit(sourcePort: 1023) == .tooManyUnauthenticated(limit: 6))
        gate.gate.cancel(first)
        #expect(gate.gate.admit(sourcePort: 1023) == .tooManyUnauthenticated(limit: 5))
    }

    // MARK: Authentication

    @Test func handsTheConnectionToTheSessionWhoseNonceItSends() async throws {
        let gate = TestGate()
        let pending = try gate.gate.expect()
        let other = try gate.gate.expect()
        let pair = try SocketPair()
        try pair.send(Frame.dialBackNonce(pending.nonce).encoded)

        #expect(gate.gate.admit(sourcePort: 1023) == nil)
        #expect(gate.gate.authenticate(pair.host) == nil)
        let descriptor = try #require(await gate.gate.connection(for: pending))
        #expect(descriptor === pair.host)
        // The other session still waits.
        #expect(gate.gate.admit(sourcePort: 1023) == nil)
        gate.gate.abandon()
        gate.gate.cancel(other)
    }

    @Test func handsTheConnectionToASessionThatAlreadyWaits() async throws {
        let gate = TestGate()
        let pending = try gate.gate.expect()
        let pair = try SocketPair()
        try pair.send(Frame.dialBackNonce(pending.nonce).encoded)

        async let received = gate.gate.connection(for: pending)
        try await Task.sleep(for: .milliseconds(50))
        #expect(gate.gate.admit(sourcePort: 1023) == nil)
        #expect(gate.gate.authenticate(pair.host) == nil)
        #expect(await received === pair.host)
    }

    /// Exactly the 37 bytes of the nonce frame are read: the session's own bytes stay in the
    /// socket for the client.
    @Test func readsNothingAfterTheNonceFrame() async throws {
        let gate = TestGate()
        let pending = try gate.gate.expect()
        let pair = try SocketPair()
        let session = Frame.version().encoded + Array("the session's bytes".utf8)
        try pair.send(Frame.dialBackNonce(pending.nonce).encoded + session)

        #expect(gate.gate.admit(sourcePort: 1023) == nil)
        #expect(gate.gate.authenticate(pair.host) == nil)
        let descriptor = try #require(await gate.gate.connection(for: pending))
        pair.closeGuestSide()
        #expect(try SocketPair.readToEnd(descriptor.rawValue) == session)
    }

    @Test func refusesAndClosesAnUnknownNonce() async throws {
        let gate = TestGate()
        let pending = try gate.gate.expect()
        let pair = try SocketPair()
        try pair.send(Frame.dialBackNonce(.random()).encoded)

        #expect(gate.gate.admit(sourcePort: 1023) == nil)
        #expect(gate.gate.authenticate(pair.host) == .unknownNonce)
        #expect(pair.host.rawValue == -1)
        #expect(pair.guestSeesTheClose())

        // The session's own connection still matches.
        let genuine = try SocketPair()
        try genuine.send(Frame.dialBackNonce(pending.nonce).encoded)
        #expect(gate.gate.admit(sourcePort: 1023) == nil)
        #expect(gate.gate.authenticate(genuine.host) == nil)
        #expect(await gate.gate.connection(for: pending) === genuine.host)
    }

    /// A nonce is single use: a second connection that sends it is refused.
    @Test func refusesANonceThatWasAlreadyUsed() async throws {
        let gate = TestGate()
        let pending = try gate.gate.expect()
        let keepWaiting = try gate.gate.expect()
        let first = try SocketPair()
        let second = try SocketPair()
        try first.send(Frame.dialBackNonce(pending.nonce).encoded)
        try second.send(Frame.dialBackNonce(pending.nonce).encoded)

        #expect(gate.gate.admit(sourcePort: 1023) == nil)
        #expect(gate.gate.authenticate(first.host) == nil)
        #expect(gate.gate.admit(sourcePort: 1023) == nil)
        #expect(gate.gate.authenticate(second.host) == .unknownNonce)
        #expect(second.host.rawValue == -1)
        #expect(await gate.gate.connection(for: pending) === first.host)
        gate.gate.cancel(keepWaiting)
    }

    @Test func refusesAnExpiredNonce() async throws {
        let gate = TestGate()
        let pending = try gate.gate.expect()
        let pair = try SocketPair()
        try pair.send(Frame.dialBackNonce(pending.nonce).encoded)

        #expect(gate.gate.admit(sourcePort: 1023) == nil)
        gate.clock.advance(by: .seconds(5))
        #expect(gate.gate.authenticate(pair.host) == .unknownNonce)
        #expect(await gate.gate.connection(for: pending) == nil)
    }

    @Test func refusesAWithdrawnNonce() async throws {
        let gate = TestGate()
        let pending = try gate.gate.expect()
        let keepWaiting = try gate.gate.expect()
        gate.gate.cancel(pending)
        let pair = try SocketPair()
        try pair.send(Frame.dialBackNonce(pending.nonce).encoded)

        #expect(gate.gate.admit(sourcePort: 1023) == nil)
        #expect(gate.gate.authenticate(pair.host) == .unknownNonce)
        #expect(await gate.gate.connection(for: pending) == nil)
        gate.gate.cancel(keepWaiting)
    }

    static let malformedFrames: [(String, [UInt8])] = {
        let valid = Frame.dialBackNonce(.random()).encoded
        return [
            ("control frame", Frame.control(.info).encoded),
            ("version frame", Frame.version().encoded),
            ("unknown type", [0, 0, 0, 32, 0x7F] + Array(repeating: 0, count: 32)),
            ("31-byte nonce", [0, 0, 0, 31, 0x04] + Array(repeating: 0, count: 31)),
            ("33-byte nonce", [0, 0, 0, 33, 0x04] + Array(repeating: 0, count: 33)),
            ("empty nonce", [0, 0, 0, 0, 0x04]),
            ("oversized nonce", [0xFF, 0xFF, 0xFF, 0xFF, 0x04]),
            ("short header", Array(valid.prefix(3))),
            ("short payload", Array(valid.prefix(20))),
            ("nothing", []),
        ]
    }()

    @Test(arguments: malformedFrames)
    func refusesAShortOrMalformedNonceFrame(_ name: String, _ bytes: [UInt8]) throws {
        let gate = TestGate()
        _ = try gate.gate.expect()
        let pair = try SocketPair()
        try pair.send(bytes)
        pair.closeGuestSide()

        #expect(gate.gate.admit(sourcePort: 1023) == nil)
        let started = ContinuousClock.now
        let refusal = try #require(gate.gate.authenticate(pair.host))
        #expect(ContinuousClock.now - started < .seconds(1))
        switch refusal {
        case .malformedNonceFrame, .nonceNotReceived: break
        default: Issue.record("\(name): refused because \(refusal)")
        }
        #expect(pair.host.rawValue == -1)
    }

    /// A connection that sends nothing, or part of a frame, is closed after 2 s.
    @Test(arguments: [0, 36])
    func waitsAtMostTwoSecondsForTheNonce(sending count: Int) async throws {
        let gate = TestGate(limits: DialBackGate.Limits())
        #expect(gate.gate.limits.nonceReadTimeout == .seconds(2))
        let pending = try gate.gate.expect()
        let pair = try SocketPair()
        try pair.send(Array(Frame.dialBackNonce(pending.nonce).encoded.prefix(count)))

        #expect(gate.gate.admit(sourcePort: 1023) == nil)
        // On a thread of its own, as the listener does: a 2-second block on the cooperative
        // pool would hold up other tests' tasks. Timed on that thread, so that the time the
        // task takes to resume is not counted.
        let host = pair.host
        let (refusal, elapsed) = await runOnDedicatedThread {
            let started = ContinuousClock.now
            let refusal = gate.gate.authenticate(host)
            return (refusal, ContinuousClock.now - started)
        }
        // The header is read first, then the payload.
        let received = count < Frame.headerSize ? count : count - Frame.headerSize
        #expect(refusal == .nonceNotReceived("timed out after \(received) bytes"))
        #expect(elapsed >= .seconds(2))
        #expect(elapsed < .seconds(3))
        #expect(pair.host.rawValue == -1)
    }

    // MARK: Pending sessions

    @Test func keepsAtMostSixtyFourSessionsWaiting() throws {
        let gate = TestGate()
        #expect(gate.gate.limits.pendingRequests == 64)
        var pending: [DialBackGate.Pending] = []
        for _ in 0..<64 {
            pending.append(try gate.gate.expect())
        }
        #expect(throws: MawError.sessionDialBackBusy(limit: 64)) {
            try gate.gate.expect()
        }
        gate.gate.cancel(pending[0])
        _ = try gate.gate.expect()
        // Expired nonces leave room too.
        gate.clock.advance(by: .seconds(5))
        _ = try gate.gate.expect()
    }

    @Test func drawsADifferentNonceForEachSession() throws {
        let gate = TestGate()
        let nonces = try (0..<64).map { _ in try gate.gate.expect().nonce }
        #expect(Set(nonces).count == 64)
    }

    @Test func endsTheWaitWhenTheNonceExpires() async throws {
        var limits = DialBackGate.Limits()
        limits.nonceLifetime = .milliseconds(200)
        let gate = DialBackGate(limits: limits) { _ in }
        let pending = try gate.expect()
        let started = ContinuousClock.now
        #expect(await gate.connection(for: pending) == nil)
        #expect(ContinuousClock.now - started >= .milliseconds(200))
        #expect(gate.admit(sourcePort: 1023) == .noPendingRequest)
    }

    @Test func endsTheWaitWhenTheTaskIsCancelled() async throws {
        let gate = TestGate()
        let pending = try gate.gate.expect()
        let wait = Task { await gate.gate.connection(for: pending) }
        try await Task.sleep(for: .milliseconds(50))
        wait.cancel()
        #expect(await wait.value == nil)
        #expect(gate.gate.admit(sourcePort: 1023) == .noPendingRequest)
    }

    @Test func closesAConnectionThatNoSessionCollects() throws {
        let gate = TestGate()
        let pending = try gate.gate.expect()
        let pair = try SocketPair()
        try pair.send(Frame.dialBackNonce(pending.nonce).encoded)
        #expect(gate.gate.admit(sourcePort: 1023) == nil)
        #expect(gate.gate.authenticate(pair.host) == nil)
        gate.gate.cancel(pending)
        #expect(pair.host.rawValue == -1)
    }

    @Test func refusesEverythingOnceClosed() async throws {
        let gate = TestGate()
        let pending = try gate.gate.expect()
        let wait = Task { await gate.gate.connection(for: pending) }
        try await Task.sleep(for: .milliseconds(50))
        gate.gate.close()
        #expect(await wait.value == nil)
        #expect(gate.gate.admit(sourcePort: 1023) == .closed)
        #expect(throws: MawError.self) { try gate.gate.expect() }
    }

    // MARK: Reports

    @Test func limitsTheRateOfReportsAndNeverReportsANonce() throws {
        let gate = TestGate()
        for _ in 0..<20 {
            _ = gate.gate.admit(sourcePort: 2000)
        }
        #expect(gate.reports.count == 5)
        #expect(
            gate.reports.first
                == "refused a dial-back connection: source port 2000 is not below 1024")

        gate.clock.advance(by: .seconds(10))
        let pending = try gate.gate.expect()
        let wrong = DialBackNonce.random()
        let pair = try SocketPair()
        try pair.send(Frame.dialBackNonce(wrong).encoded)
        #expect(gate.gate.admit(sourcePort: 1023) == nil)
        #expect(gate.gate.authenticate(pair.host) == .unknownNonce)
        #expect(gate.reports.count == 6)
        #expect(
            gate.reports.last
                == "15 further refusals were not logged; refused a dial-back connection: the nonce "
                + "matches no waiting session")
        for report in gate.reports {
            #expect(!report.contains(pending.nonce.hexadecimal))
            #expect(!report.contains(wrong.hexadecimal))
        }
    }

    // MARK: Opening a session's connection

    @Test func opensTheConnectionThatTheAgentDials() async throws {
        let gate = TestGate()
        let agent = FakeAgent(gate: gate.gate, reply: .dial)
        let descriptor = try await gate.gate.openSessionConnection(through: agent.client)
        #expect(
            try SocketPair.readExactly(descriptor.rawValue, count: 9) == Frame.version().encoded)
        #expect(agent.requests.value == [.dialBack(agent.nonces.value[0])])
    }

    @Test func reportsADialThatTheAgentCouldNotMake() async throws {
        let gate = TestGate()
        let agent = FakeAgent(
            gate: gate.gate, reply: .fail("cannot connect to the host: connect: Connection refused")
        )
        await #expect(
            throws: MawError.sessionDialBackFailed(
                reason: "cannot connect to the host: connect: Connection refused")
        ) {
            _ = try await gate.gate.openSessionConnection(through: agent.client)
        }
        #expect(gate.gate.admit(sourcePort: 1023) == .noPendingRequest)
    }

    /// The agent reports that it dialed, but no connection with the nonce arrives: the session
    /// fails rather than fall back to a connection that the host opens.
    @Test func failsWhenTheDialedConnectionDoesNotArrive() async throws {
        var limits = DialBackGate.Limits()
        limits.nonceLifetime = .milliseconds(300)
        let gate = DialBackGate(limits: limits) { _ in }
        let agent = FakeAgent(gate: gate, reply: .claimWithoutDialing)
        let started = ContinuousClock.now
        await #expect(throws: MawError.sessionDialBackMissing(milliseconds: 300)) {
            _ = try await gate.openSessionConnection(through: agent.client)
        }
        #expect(ContinuousClock.now - started >= .milliseconds(300))
        #expect(agent.connections.value == 1)
    }
}

// MARK: Support

/// A gate with a clock that the test moves, and the reports it made.
private final class TestGate: Sendable {
    let clock: TestClock
    let gate: DialBackGate
    private let collected: OSAllocatedUnfairLock<[String]>

    var reports: [String] { collected.withLock { $0 } }

    init(limits: DialBackGate.Limits = DialBackGate.Limits()) {
        let clock = TestClock()
        let collected = OSAllocatedUnfairLock(initialState: [String]())
        self.clock = clock
        self.collected = collected
        gate = DialBackGate(
            limits: limits, now: { clock.now },
            report: { message in collected.withLock { $0.append(message) } })
    }
}

private final class TestClock: Sendable {
    private let instant = OSAllocatedUnfairLock(initialState: ContinuousClock.now)

    var now: ContinuousClock.Instant { instant.withLock { $0 } }

    func advance(by duration: Duration) {
        instant.withLock { $0 += duration }
    }
}

/// A connected pair of Unix stream sockets: `host` for the gate, the other end for the test,
/// in the guest's place.
private final class SocketPair: Sendable {
    let host: OwnedDescriptor
    let guest: OwnedDescriptor

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw SystemError("socketpair")
        }
        host = OwnedDescriptor(descriptors[0])
        guest = OwnedDescriptor(descriptors[1])
    }

    func send(_ bytes: [UInt8]) throws {
        try writeAll(bytes, to: guest.rawValue)
    }

    func closeGuestSide() {
        guest.close()
    }

    /// Whether the guest's end reads end-of-file, because the host's end was closed.
    func guestSeesTheClose() -> Bool {
        var byte: UInt8 = 0
        return read(guest.rawValue, &byte, 1) == 0
    }

    static func readExactly(_ descriptor: Int32, count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let result = bytes.withUnsafeMutableBytes {
                read(descriptor, $0.baseAddress! + received, count - received)
            }
            guard result > 0 else { throw SystemError("read") }
            received += result
        }
        return bytes
    }

    static func readToEnd(_ descriptor: Int32) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let result = read(descriptor, &buffer, buffer.count)
            guard result >= 0 else { throw SystemError("read") }
            if result == 0 { return bytes }
            bytes.append(contentsOf: buffer[..<result])
        }
    }
}

/// Plays the agent's side of the request connection: answers each `dialBack` request as
/// `reply` says, dialing the gate as the guest's vsock transport would.
private final class FakeAgent: Sendable {
    enum Reply: Sendable {
        /// Dials the gate from port 1023, sends the nonce frame and a version frame, and
        /// replies `dialedBack`.
        case dial
        /// Replies `dialBackFailed`.
        case fail(String)
        /// Replies `dialedBack` without dialing.
        case claimWithoutDialing
    }

    let gate: DialBackGate
    let reply: Reply
    let requests = Locked<[ControlMessage]>([])
    let nonces = Locked<[DialBackNonce]>([])
    let connections = Locked(0)
    private let dialed = Locked<[SocketPair]>([])

    init(gate: DialBackGate, reply: Reply) {
        self.gate = gate
        self.reply = reply
    }

    var client: GuestAgentClient {
        GuestAgentClient(replyTimeout: .seconds(5)) { [self] () throws(MawError) in
            var descriptors: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw .guestAgentUnavailable(reason: "socketpair failed")
            }
            connections.update { $0 += 1 }
            let agentSide = OwnedDescriptor(descriptors[1])
            startDetachedThread { [self] in serve(agentSide) }
            return OwnedDescriptor(descriptors[0])
        }
    }

    private func serve(_ descriptor: OwnedDescriptor) {
        defer { descriptor.close() }
        let deadline = ContinuousClock.now + .seconds(5)
        guard let connection = try? FrameConnection(descriptor),
            (try? connection.exchangeVersions(until: deadline)) != nil,
            let request = try? connection.receiveControl(until: deadline, expecting: "a request")
        else { return }
        requests.update { $0.append(request) }
        guard case .dialBack(let nonce) = request else { return }
        nonces.update { $0.append(nonce) }
        switch reply {
        case .dial:
            guard let pair = try? SocketPair(),
                (try? pair.send(Frame.dialBackNonce(nonce).encoded + Frame.version().encoded))
                    != nil
            else { return }
            dialed.update { $0.append(pair) }
            if gate.admit(sourcePort: 1023) == nil {
                gate.authenticate(pair.host)
            }
            connection.enqueue(.control(.dialedBack))
        case .fail(let reason):
            connection.enqueue(.control(.error(AgentError(.dialBackFailed, reason))))
        case .claimWithoutDialing:
            connection.enqueue(.control(.dialedBack))
        }
        try? connection.flush(until: deadline)
    }
}

private final class Locked<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(_ value: Value) {
        lock = OSAllocatedUnfairLock(initialState: value)
    }

    var value: Value { lock.withLock { $0 } }

    func update(_ body: @Sendable (inout Value) -> Void) {
        lock.withLock { body(&$0) }
    }
}
