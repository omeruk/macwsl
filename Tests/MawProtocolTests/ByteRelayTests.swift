import CMawSystem
import Testing

@testable import MawProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Every wait has a deadline and the suite a time limit, so that a relay that never ends fails
/// its test with a message instead of blocking the run.
@Suite(.timeLimit(.minutes(2))) struct ByteRelayTests {
    /// How long a test waits for a stream's end or the relay's report. A relay that misses a
    /// wakeup ends one `ByteRelay.pollIntervalMilliseconds` late, far within this.
    static let endDeadline = Duration.seconds(30)

    static func pair() throws -> (OwnedDescriptor, OwnedDescriptor) {
        var fds: [Int32] = [-1, -1]
        try #require(maw_socketpair(&fds) == 0)
        return (OwnedDescriptor(fds[0]), OwnedDescriptor(fds[1]))
    }

    /// Reads `descriptor` to its end, or returns `nil` if the end has not come within
    /// `deadline`. It reads only once `poll(2)` reports the descriptor ready, so the read
    /// never waits. The descriptor stays blocking, since another thread writes to it.
    static func readToEnd(_ descriptor: OwnedDescriptor, within deadline: Duration = endDeadline)
        -> [UInt8]?
    {
        let deadline = ContinuousClock.now + deadline
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        while ContinuousClock.now < deadline {
            var request = pollfd(fd: descriptor.rawValue, events: Int16(POLLIN), revents: 0)
            guard poll(&request, 1, 100) > 0 else { continue }
            let count = read(descriptor.rawValue, &buffer, buffer.count)
            if count > 0 {
                bytes += buffer[..<count]
            } else if count == 0 || errno != EINTR {
                return bytes
            }
        }
        return nil
    }

    /// Reads frames from `descriptor` until a `streamEnd` frame, and returns them with it, or
    /// `nil` at the connection's end or the deadline without one.
    static func readFramesToEnd(_ descriptor: OwnedDescriptor) throws -> [Frame]? {
        let deadline = ContinuousClock.now + endDeadline
        var decoder = FrameDecoder()
        var frames: [Frame] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        while ContinuousClock.now < deadline {
            while let frame = try decoder.nextFrame() {
                frames.append(frame)
                if frame.type == .streamEnd { return frames }
            }
            var request = pollfd(fd: descriptor.rawValue, events: Int16(POLLIN), revents: 0)
            guard poll(&request, 1, 100) > 0 else { continue }
            let count = read(descriptor.rawValue, &buffer, buffer.count)
            guard count > 0 else { return nil }
            decoder.append(buffer[..<count])
        }
        return nil
    }

    /// Writes `bytes` to `descriptor` and then ends its stream, on a thread of its own.
    static func send(_ bytes: [UInt8], to descriptor: OwnedDescriptor) -> Bool {
        startDetachedThread {
            try? writeAll(bytes, to: descriptor.rawValue)
            _ = shutdown(descriptor.rawValue, Int32(SHUT_WR))
        }
    }

    /// Whether `descriptor` reaches its end, or has bytes, within `milliseconds`.
    static func isReadable(_ descriptor: OwnedDescriptor, within milliseconds: Int32) -> Bool {
        var request = pollfd(fd: descriptor.rawValue, events: Int16(POLLIN), revents: 0)
        return poll(&request, 1, milliseconds) > 0
    }

    static func dataFrame(_ bytes: [UInt8]) -> [UInt8] {
        Frame(type: .streamData, payload: bytes).encoded
    }

    final class Ending: @unchecked Sendable {
        let lock = ConditionLock()
        var ending: ByteRelay.Ending?

        var report: @Sendable (ByteRelay.Ending) -> Void {
            { ending in self.lock.withLock { self.ending = ending } }
        }

        /// How the relay ended, if it reported within `deadline`.
        func wait(within deadline: Duration = ByteRelayTests.endDeadline) -> ByteRelay.Ending? {
            let deadline = ContinuousClock.now + deadline
            while lock.withLock({ ending }) == nil && ContinuousClock.now < deadline {
                usleep(1_000)
            }
            return lock.withLock { ending }
        }

        var now: ByteRelay.Ending? { lock.withLock { ending } }
    }

    /// A forwarded connection as in the daemon and the agent: `client` <-> the host's relay
    /// <-> a framed byte stream <-> the guest's relay <-> `server`.
    struct Chain {
        let client: OwnedDescriptor
        let server: OwnedDescriptor
        let host: Ending
        let guest: Ending
    }

    static func chain(
        bufferSize: Int = 4096, closeWaitLimit: Duration = .seconds(60)
    ) throws -> Chain {
        let (client, hostPlain) = try pair()
        let (hostStream, guestStream) = try pair()
        let (guestPlain, server) = try pair()
        let host = Ending()
        let guest = Ending()
        try #require(
            ByteRelay.start(
                plain: hostPlain, stream: hostStream, role: .host, bufferSize: bufferSize,
                finished: host.report) != nil)
        try #require(
            ByteRelay.start(
                plain: guestPlain, stream: guestStream,
                role: .guest(closeWaitLimit: closeWaitLimit), bufferSize: bufferSize,
                finished: guest.report) != nil)
        return Chain(client: client, server: server, host: host, guest: guest)
    }

    /// Relays `forward` from the client to the server and `backward` from the server to the
    /// client, each followed by its end, with a small buffer. Returns `nil` if both arrived
    /// intact and both relays reported a complete end, and otherwise what went wrong. It
    /// records no issue itself, so that it can run on threads outside a test's task.
    ///
    /// With `inTurn`, one thread reads the forward bytes to their end and only then the
    /// backward ones, so that the backward direction stalls on full buffers while the forward
    /// one ends; otherwise each side has a reader of its own.
    static func relayBothWays(
        _ forward: [UInt8], _ backward: [UInt8], bufferSize: Int = 4096, inTurn: Bool
    ) -> String? {
        guard let chain = try? chain(bufferSize: bufferSize) else { return "the chain failed" }
        guard send(forward, to: chain.client), send(backward, to: chain.server) else {
            return "a writer did not start"
        }
        let received = Received()
        let readersStarted =
            inTurn
            ? startDetachedThread {
                received.set(\.forward, readToEnd(chain.server))
                received.set(\.backward, readToEnd(chain.client))
            }
            : startDetachedThread({ received.set(\.forward, readToEnd(chain.server)) })
                && startDetachedThread({ received.set(\.backward, readToEnd(chain.client)) })
        guard readersStarted else { return "a reader did not start" }
        let arrived = received.wait()
        var problems: [String] = []
        if arrived.forward != forward {
            problems.append("forward: \(arrived.forward.map { "\($0.count) bytes" } ?? "no end")")
        }
        if arrived.backward != backward {
            problems.append(
                "backward: \(arrived.backward.map { "\($0.count) bytes" } ?? "no end")")
        }
        for (name, ending) in [("host", chain.host), ("guest", chain.guest)] {
            let ended = ending.wait()
            if ended != .completed {
                problems.append("the \(name) relay ended \(ended.map { "\($0)" } ?? "never")")
            }
        }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }

    final class Received: @unchecked Sendable {
        let lock = ConditionLock()
        var forward: [UInt8]??
        var backward: [UInt8]??

        func set(_ path: ReferenceWritableKeyPath<Received, [UInt8]??>, _ value: [UInt8]?) {
            lock.withLock { self[keyPath: path] = .some(value) }
        }

        /// Both sides' bytes, `nil` for a side whose end did not come; both readers give up
        /// within `endDeadline`, so this ends.
        func wait() -> (forward: [UInt8]?, backward: [UInt8]?) {
            while true {
                let done = lock.withLock { () -> (forward: [UInt8]?, backward: [UInt8]?)? in
                    guard let forward, let backward else { return nil }
                    return (forward, backward)
                }
                if let done { return done }
                usleep(1_000)
            }
        }
    }

    // MARK: Through both relays

    /// Several megabytes each way, with a small buffer, arrive intact; the end of one side's
    /// stream reaches the other, and both relays report a complete end once both have ended.
    @Test(arguments: [false, true]) func carriesBothDirectionsAndTheirEnds(inTurn: Bool) {
        let forward = (0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let backward = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 13) }
        #expect(Self.relayBothWays(forward, backward, inTurn: inTurn) == nil)
    }

    /// A server that sends a response and closes: the client receives all of it and then the
    /// end, while its own side is still open (the phase 08 defect of decision record 0023,
    /// "Correction of 2026-11-28").
    @Test func endsAResponseWhenTheServerCloses() throws {
        let chain = try Self.chain()
        let response = (0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 11) }
        try #require(
            startDetachedThread {
                try? writeAll(response, to: chain.server.rawValue)
                chain.server.close()
            })
        #expect(Self.readToEnd(chain.client) == response)
        #expect(chain.host.now == nil)
        _ = shutdown(chain.client.rawValue, Int32(SHUT_WR))
        #expect(chain.host.wait() == .completed)
        #expect(chain.guest.wait() == .completed)
    }

    /// A client that sends a request and half-closes, then reads a response that the server
    /// sends once it has read the request's end, and closes.
    @Test func carriesAResponseAfterTheClientHalfCloses() throws {
        let chain = try Self.chain()
        let request = Array("GET 3MiB\n".utf8)
        let response = (0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 5) }
        try writeAll(request, to: chain.client.rawValue)
        _ = shutdown(chain.client.rawValue, Int32(SHUT_WR))
        let server = chain.server
        let received = Received()
        try #require(
            startDetachedThread {
                received.set(\.forward, ByteRelayTests.readToEnd(server))
                try? writeAll(response, to: server.rawValue)
                server.close()
            })
        received.set(\.backward, Self.readToEnd(chain.client))
        let arrived = received.wait()
        #expect(arrived.forward == request)
        #expect(arrived.backward == response)
        #expect(chain.host.wait() == .completed)
        #expect(chain.guest.wait() == .completed)
    }

    /// One direction ends at a random moment while the other keeps carrying small writes; the
    /// relays still carry the rest of the second direction and its end, and report no abort.
    @Test func carriesOneDirectionAfterTheOtherEnds() throws {
        var problems: [String] = []
        for trial in 0..<100 {
            let chain = try Self.chain()
            let chunk = [UInt8](repeating: UInt8(truncatingIfNeeded: trial), count: 64)
            let writes = 64
            let server = chain.server
            try #require(
                startDetachedThread {
                    for _ in 0..<writes {
                        try? writeAll(chunk, to: server.rawValue)
                        usleep(UInt32.random(in: 0...40))
                    }
                    _ = shutdown(server.rawValue, Int32(SHUT_WR))
                })
            let received = Received()
            let client = chain.client
            try #require(startDetachedThread { received.set(\.backward, Self.readToEnd(client)) })
            usleep(UInt32.random(in: 0...2_000))
            _ = shutdown(chain.client.rawValue, Int32(SHUT_WR))
            received.set(\.forward, Self.readToEnd(chain.server))
            let arrived = received.wait()
            let endings = (chain.host.wait(), chain.guest.wait())
            if arrived.forward != [] || arrived.backward?.count != writes * chunk.count
                || endings != (.completed, .completed)
            {
                problems.append(
                    "trial \(trial): forward \(arrived.forward?.count ?? -1), backward \(arrived.backward?.count ?? -1), endings \(endings)"
                )
                break
            }
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    // MARK: The close order

    /// The host closes the stream's connection once it has received the guest's end and sent
    /// its own, and not before.
    @Test func hostClosesOnceBothEndsHaveArrived() throws {
        let (client, plain) = try Self.pair()
        let (stream, guest) = try Self.pair()
        let ending = Ending()
        try #require(
            ByteRelay.start(plain: plain, stream: stream, role: .host, finished: ending.report)
                != nil)
        try writeAll(
            Self.dataFrame(Array("hello".utf8)) + FramedStream.endFrame, to: guest.rawValue)
        #expect(Self.readToEnd(client) == Array("hello".utf8))
        #expect(!Self.isReadable(guest, within: 200))
        #expect(ending.now == nil)
        try writeAll(Array("bye".utf8), to: client.rawValue)
        _ = shutdown(client.rawValue, Int32(SHUT_WR))
        let frames = try Self.readFramesToEnd(guest)
        #expect(
            frames == [
                Frame(type: .streamData, payload: Array("bye".utf8)), Frame(type: .streamEnd),
            ])
        #expect(Self.readToEnd(guest) == [])
        #expect(ending.wait() == .completed)
    }

    /// Once both directions have ended, the guest keeps the stream's connection open until the
    /// host closes it, and then reports a complete end.
    @Test func guestWaitsForTheHostsClose() throws {
        let (plain, server) = try Self.pair()
        let (host, stream) = try Self.pair()
        let ending = Ending()
        try #require(
            ByteRelay.start(
                plain: plain, stream: stream, role: .guest(closeWaitLimit: .seconds(60)),
                finished: ending.report) != nil)
        try writeAll(
            Self.dataFrame(Array("request".utf8)) + FramedStream.endFrame, to: host.rawValue)
        #expect(Self.readToEnd(server) == Array("request".utf8))
        try writeAll(Array("response".utf8), to: server.rawValue)
        server.close()
        let frames = try Self.readFramesToEnd(host)
        #expect(
            frames == [
                Frame(type: .streamData, payload: Array("response".utf8)), Frame(type: .streamEnd),
            ])
        // Nothing more arrives and the guest does not close: it waits for the host.
        #expect(!Self.isReadable(host, within: 1_500))
        #expect(ending.now == nil)
        host.close()
        #expect(ending.wait() == .completed)
    }

    /// A host that never closes costs the guest at most the wait limit without progress: the
    /// guest then closes, and reports it.
    @Test func guestClosesAfterTheWaitLimitWithoutProgress() throws {
        let (plain, server) = try Self.pair()
        let (host, stream) = try Self.pair()
        let ending = Ending()
        try #require(
            ByteRelay.start(
                plain: plain, stream: stream, role: .guest(closeWaitLimit: .milliseconds(300)),
                finished: ending.report) != nil)
        try writeAll(FramedStream.endFrame, to: host.rawValue)
        server.close()
        #expect(try Self.readFramesToEnd(host) == [Frame(type: .streamEnd)])
        let started = ContinuousClock.now
        #expect(ending.wait() == .closedWithoutAcknowledgement)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(Self.readToEnd(host) == [])
    }

    /// The wait limit counts from both ends, not from the guest's own: a guest whose sending
    /// direction runs longer than the limit after the host's end is not cut off.
    @Test func guestWaitLimitStartsOnceItsOwnEndIsSent() throws {
        let (plain, server) = try Self.pair()
        let (host, stream) = try Self.pair()
        let ending = Ending()
        try #require(
            ByteRelay.start(
                plain: plain, stream: stream, role: .guest(closeWaitLimit: .milliseconds(200)),
                finished: ending.report) != nil)
        try writeAll(FramedStream.endFrame, to: host.rawValue)
        // The server keeps sending for longer than the limit.
        for _ in 0..<8 {
            try writeAll([UInt8](repeating: 1, count: 100), to: server.rawValue)
            usleep(100_000)
        }
        #expect(ending.now == nil)
        server.close()
        let frames = try #require(try Self.readFramesToEnd(host))
        #expect(frames.last == Frame(type: .streamEnd))
        #expect(frames.dropLast().reduce(0) { $0 + $1.payload.count } == 800)
        host.close()
        #expect(ending.wait() == .completed)
    }

    /// The wait limit runs only once the guest's `streamEnd` frame is written in full: a host
    /// that holds the guest's last writes back for longer than the limit, as a slow reader on
    /// the Mac does, is not taken for a host that does not close.
    @Test func guestWaitLimitStartsOnlyOnceItsEndIsWritten() throws {
        let (plain, server) = try Self.pair()
        let (host, stream) = try Self.pair()
        let ending = Ending()
        try #require(
            ByteRelay.start(
                plain: plain, stream: stream, role: .guest(closeWaitLimit: .milliseconds(200)),
                bufferSize: 4096, finished: ending.report) != nil)
        try writeAll(FramedStream.endFrame, to: host.rawValue)
        let response = (0..<(2 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 3) }
        try #require(
            startDetachedThread {
                try? writeAll(response, to: server.rawValue)
                server.close()
            })
        // The host reads nothing for several times the limit.
        usleep(1_500_000)
        #expect(ending.now == nil)
        let frames = try #require(try Self.readFramesToEnd(host))
        #expect(frames.last == Frame(type: .streamEnd))
        #expect(frames.dropLast().flatMap(\.payload) == response)
        host.close()
        #expect(ending.wait() == .completed)
    }

    /// The host decodes the rest of the read that carries the guest's end: a byte after it
    /// resets both connections instead of ending them cleanly.
    @Test func hostRefusesBytesAfterTheGuestsEnd() throws {
        let (client, plain) = try Self.pair()
        let (stream, guest) = try Self.pair()
        let ending = Ending()
        try #require(
            ByteRelay.start(plain: plain, stream: stream, role: .host, finished: ending.report)
                != nil)
        try writeAll(Self.dataFrame([1]) + FramedStream.endFrame + [0], to: guest.rawValue)
        #expect(ending.wait() == .aborted)
        _ = client
    }

    /// A connected loopback TCP pair, which, unlike a socket pair, can be reset.
    static func tcpPair() throws -> (OwnedDescriptor, OwnedDescriptor) {
        var listener: Int32 = -1
        try #require(maw_tcp_listen_loopback(0, 0, 4, 0, &listener) == 0)
        defer { close(listener) }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &length)
            }
        }
        var connected: Int32 = -1
        try #require(
            maw_tcp_connect_loopback(0, UInt16(bigEndian: address.sin_port), 2_000, &connected)
                == 0)
        let accepted = accept(listener, nil, nil)
        try #require(accepted >= 0)
        return (OwnedDescriptor(connected), OwnedDescriptor(accepted))
    }

    /// Once both ends have passed, a reset of the stream's connection is a failure, not the
    /// host's close.
    @Test func guestTakesAResetForAFailureNotTheHostsClose() throws {
        let (plain, server) = try Self.pair()
        let (host, stream) = try Self.tcpPair()
        let ending = Ending()
        try #require(
            ByteRelay.start(
                plain: plain, stream: stream, role: .guest(closeWaitLimit: .seconds(60)),
                finished: ending.report) != nil)
        try writeAll(FramedStream.endFrame, to: host.rawValue)
        server.close()
        #expect(try Self.readFramesToEnd(host) == [Frame(type: .streamEnd)])
        _ = maw_set_reset_on_close(host.rawValue)
        host.close()
        #expect(ending.wait() == .aborted)
    }

    // MARK: Failures

    /// The stream's connection ending before its `streamEnd` frame loses data: both relays
    /// report an abort instead of passing the end on.
    @Test(arguments: [ByteRelay.Role.host, .guest(closeWaitLimit: .seconds(60))])
    func anEarlyEndOfTheStreamAborts(role: ByteRelay.Role) throws {
        let (peer, plain) = try Self.pair()
        let (other, stream) = try Self.pair()
        let ending = Ending()
        try #require(
            ByteRelay.start(plain: plain, stream: stream, role: role, finished: ending.report)
                != nil)
        try writeAll(Self.dataFrame([1, 2, 3]), to: other.rawValue)
        other.close()
        #expect(ending.wait() == .aborted)
        #expect(Self.readToEnd(peer) == [1, 2, 3])
    }

    static let invalidStreams: [(String, [UInt8])] = [
        ("empty data", Frame.header(type: .streamData, payloadSize: 0)),
        (
            "oversized data",
            Frame.header(type: .streamData, payloadSize: AgentProtocol.streamChunkSize + 1)
        ),
        ("an end with a payload", Frame(type: .streamEnd, payload: [0]).encoded),
        ("a control frame", Frame.control(.info).encoded),
        ("an unknown type", [0, 0, 0, 1, 0x7F, 0]),
        ("bytes after the end", FramedStream.endFrame + [0]),
    ]

    /// Stream bytes that are not data frames and one end reset both connections.
    @Test(arguments: invalidStreams) func invalidStreamBytesAbort(
        _ name: String, _ bytes: [UInt8]
    ) throws {
        let (peer, plain) = try Self.pair()
        let (other, stream) = try Self.pair()
        let ending = Ending()
        try #require(
            ByteRelay.start(
                plain: plain, stream: stream, role: .guest(closeWaitLimit: .seconds(60)),
                finished: ending.report) != nil)
        try writeAll(bytes, to: other.rawValue)
        #expect(ending.wait() == .aborted, "\(name)")
        _ = peer
    }

    /// Frames that arrive one byte at a time are carried intact.
    @Test func carriesFramesSplitIntoSingleBytes() throws {
        let (client, plain) = try Self.pair()
        let (stream, guest) = try Self.pair()
        let ending = Ending()
        try #require(
            ByteRelay.start(plain: plain, stream: stream, role: .host, finished: ending.report)
                != nil)
        let payload = (0..<300).map { UInt8(truncatingIfNeeded: $0 &* 3) }
        let bytes = Self.dataFrame(payload) + Self.dataFrame([9]) + FramedStream.endFrame
        try #require(
            startDetachedThread {
                for byte in bytes {
                    try? writeAll([byte], to: guest.rawValue)
                    usleep(200)
                }
            })
        #expect(Self.readToEnd(client) == payload + [9])
        _ = shutdown(client.rawValue, Int32(SHUT_WR))
        #expect(ending.wait() == .completed)
    }

    /// Neither direction waits in a blocking `read(2)` or `write(2)`: both sockets are
    /// nonblocking while the relay runs, so that a missed wakeup cannot hold a direction
    /// forever.
    @Test func neverWaitsInABlockingCall() throws {
        let (left, leftRelay) = try Self.pair()
        let (right, rightRelay) = try Self.pair()
        let numbers = [leftRelay.rawValue, rightRelay.rawValue]
        let ending = Ending()
        let relay = try #require(
            ByteRelay.start(
                plain: leftRelay, stream: rightRelay, role: .host, finished: ending.report))
        for number in numbers {
            #expect(fcntl(number, F_GETFL) & O_NONBLOCK != 0, "descriptor \(number)")
        }
        relay.abort()
        #expect(Self.readToEnd(left) == [])
        #expect(Self.readToEnd(right) == [])
        #expect(ending.wait() == .aborted)
    }

    @Test(arguments: [ByteRelay.Role.host, .guest(closeWaitLimit: .seconds(60))])
    func abortEndsBothSides(role: ByteRelay.Role) throws {
        let (left, leftRelay) = try Self.pair()
        let (right, rightRelay) = try Self.pair()
        let ending = Ending()
        let relay = try #require(
            ByteRelay.start(
                plain: leftRelay, stream: rightRelay, role: role, finished: ending.report))
        relay.abort()
        #expect(Self.readToEnd(left) == [])
        #expect(Self.readToEnd(right) == [])
        #expect(ending.wait() == .aborted)
    }

    /// Tests that run many relays, apart from the latency tests (docs/decisions/0018-test-groups.md).
    @Suite struct Load {
        /// Many chains of two relays, one after another, each carrying both directions to
        /// their ends under flow control, all end. On macOS a thread blocked in `read(2)` on a
        /// socket can stay blocked although data or the end of stream waits there; before
        /// `ByteRelay` waited in `poll(2)` with a bound, 10 of 1,280 relays never ended, and
        /// this test failed in 6 of 20 runs.
        @Test func endsEveryOneOfManyRelays() throws {
            let forward = (0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) }
            let backward = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 13) }
            let relays = 1
            let rounds = 64
            let outcomes = Outcomes()
            for round in 1...rounds {
                for _ in 0..<relays {
                    try #require(
                        startDetachedThread {
                            outcomes.add(
                                ByteRelayTests.relayBothWays(forward, backward, inTurn: true))
                        })
                }
                outcomes.wait(until: round * relays)
            }
            let problems = outcomes.lock.withLock { outcomes.problems }
            #expect(
                problems.isEmpty, "\(problems.count) of \(relays * rounds): \(problems.prefix(3))")
        }

        final class Outcomes: @unchecked Sendable {
            let lock = ConditionLock()
            var ended = 0
            var problems: [String] = []

            func add(_ problem: String?) {
                lock.withLock {
                    ended += 1
                    if let problem { problems.append(problem) }
                }
            }

            /// Waits until `total` relays have ended; each gives up within its deadlines.
            func wait(until total: Int) {
                while lock.withLock({ ended }) < total { usleep(1_000) }
            }
        }
    }
}
