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
    /// `endDeadline`. It reads only once `poll(2)` reports the descriptor ready, so the read
    /// never waits. The descriptor stays blocking, since another thread writes to it.
    static func readToEnd(_ descriptor: OwnedDescriptor) -> [UInt8]? {
        let deadline = ContinuousClock.now + endDeadline
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

    /// Writes `bytes` to `descriptor` and then ends its stream, on a thread of its own.
    static func send(_ bytes: [UInt8], to descriptor: OwnedDescriptor) -> Bool {
        startDetachedThread {
            try? writeAll(bytes, to: descriptor.rawValue)
            _ = shutdown(descriptor.rawValue, Int32(SHUT_WR))
        }
    }

    final class Ending: @unchecked Sendable {
        let lock = ConditionLock()
        var aborted: Bool?

        /// Whether the relay reported its end within `endDeadline`, and how.
        func wait() -> Bool? {
            let deadline = ContinuousClock.now + ByteRelayTests.endDeadline
            while lock.withLock({ aborted }) == nil && ContinuousClock.now < deadline {
                usleep(1_000)
            }
            return lock.withLock { aborted }
        }
    }

    /// Relays `forward` from left to right and `backward` from right to left, each followed by
    /// its end, with a small buffer. Returns `nil` if both arrived intact and the relay
    /// reported an end without an abort, and otherwise what went wrong. It records no issue
    /// itself, so that it can run on threads outside a test's task.
    ///
    /// With `inTurn`, one thread reads the forward bytes to their end and only then the
    /// backward ones, so that the backward direction stalls on full buffers while the forward
    /// one ends; otherwise each side has a reader of its own.
    static func relayBothWays(
        _ forward: [UInt8], _ backward: [UInt8], bufferSize: Int = 4096, inTurn: Bool
    ) -> String? {
        guard let (left, leftRelay) = try? pair(), let (right, rightRelay) = try? pair() else {
            return "socketpair failed"
        }
        let ending = Ending()
        let relay = ByteRelay.start(leftRelay, rightRelay, bufferSize: bufferSize) { aborted in
            ending.lock.withLock { ending.aborted = aborted }
        }
        guard relay != nil else { return "the relay did not start" }
        guard send(forward, to: left), send(backward, to: right) else {
            return "a writer did not start"
        }
        let received = Received()
        let readersStarted =
            inTurn
            ? startDetachedThread {
                received.set(\.forward, readToEnd(right))
                received.set(\.backward, readToEnd(left))
            }
            : startDetachedThread({ received.set(\.forward, readToEnd(right)) })
                && startDetachedThread({ received.set(\.backward, readToEnd(left)) })
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
        switch ending.wait() {
        case false: break
        case true: problems.append("the relay reported an abort")
        case nil: problems.append("the relay did not report its end")
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

    /// Several megabytes each way, with a small buffer, arrive intact; the end of one side's
    /// stream reaches the other, and the relay reports its end once both have ended.
    @Test(arguments: [false, true]) func carriesBothDirectionsAndTheirEnds(inTurn: Bool) {
        let forward = (0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let backward = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 13) }
        #expect(Self.relayBothWays(forward, backward, inTurn: inTurn) == nil)
    }

    /// One direction ends at a random moment while the other keeps carrying small writes; the
    /// relay still carries the rest of the second direction and its end, and reports no abort.
    @Test func carriesOneDirectionAfterTheOtherEnds() throws {
        let trials = 100
        var problems: [String] = []
        for trial in 0..<trials {
            let (left, leftRelay) = try Self.pair()
            let (right, rightRelay) = try Self.pair()
            let ending = Ending()
            let relay = ByteRelay.start(leftRelay, rightRelay, bufferSize: 4096) { aborted in
                ending.lock.withLock { ending.aborted = aborted }
            }
            try #require(relay != nil)
            let chunk = [UInt8](repeating: UInt8(truncatingIfNeeded: trial), count: 64)
            let writes = 64
            try #require(
                startDetachedThread {
                    for _ in 0..<writes {
                        try? writeAll(chunk, to: right.rawValue)
                        usleep(UInt32.random(in: 0...40))
                    }
                    _ = shutdown(right.rawValue, Int32(SHUT_WR))
                })
            let received = Received()
            try #require(startDetachedThread { received.set(\.backward, Self.readToEnd(left)) })
            usleep(UInt32.random(in: 0...2_000))
            _ = shutdown(left.rawValue, Int32(SHUT_WR))
            let forward = Self.readToEnd(right)
            received.set(\.forward, forward)
            let arrived = received.wait()
            let aborted = ending.wait()
            if arrived.forward != [] || arrived.backward?.count != writes * chunk.count
                || aborted != false
            {
                problems.append(
                    "trial \(trial): forward \(arrived.forward?.count ?? -1), backward \(arrived.backward?.count ?? -1), aborted \(String(describing: aborted))"
                )
                break
            }
        }
        #expect(problems.isEmpty, "\(problems)")
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
            ByteRelay.start(leftRelay, rightRelay) { aborted in
                ending.lock.withLock { ending.aborted = aborted }
            })
        for number in numbers {
            #expect(fcntl(number, F_GETFL) & O_NONBLOCK != 0, "descriptor \(number)")
        }
        relay.abort()
        #expect(Self.readToEnd(left) == [])
        #expect(Self.readToEnd(right) == [])
        #expect(ending.wait() == true)
    }

    @Test func abortEndsBothSides() throws {
        let (left, leftRelay) = try Self.pair()
        let (right, rightRelay) = try Self.pair()
        let ending = Ending()
        let relay = try #require(
            ByteRelay.start(leftRelay, rightRelay) { aborted in
                ending.lock.withLock { ending.aborted = aborted }
            })
        relay.abort()
        #expect(Self.readToEnd(left) == [])
        #expect(Self.readToEnd(right) == [])
        #expect(ending.wait() == true)
    }

    /// Tests that run many relays, apart from the latency tests (docs/decisions/0018-test-groups.md).
    @Suite struct Load {
        /// Many relays, one after another, each carrying both directions to their ends under
        /// flow control, all end. On macOS a thread blocked in `read(2)` on a socket can stay
        /// blocked although data or the end of stream waits there; before `ByteRelay` waited in
        /// `poll(2)` with a bound, 10 of 1,280 relays never ended, and this test failed in 6 of
        /// 20 runs.
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
