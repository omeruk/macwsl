import CMawSystem
import Testing

@testable import MawProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@Suite struct ByteRelayTests {
    static func pair() throws -> (OwnedDescriptor, OwnedDescriptor) {
        var fds: [Int32] = [-1, -1]
        try #require(maw_socketpair(&fds) == 0)
        return (OwnedDescriptor(fds[0]), OwnedDescriptor(fds[1]))
    }

    static func readToEnd(_ descriptor: OwnedDescriptor) -> [UInt8] {
        _ = maw_set_blocking(descriptor.rawValue)
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(descriptor.rawValue, &buffer, buffer.count)
            guard count > 0 else { return bytes }
            bytes += buffer[..<count]
        }
    }

    final class Ending: @unchecked Sendable {
        let lock = ConditionLock()
        var aborted: Bool?
    }

    /// Several megabytes each way, with a small buffer, arrive intact; the end of one side's
    /// stream reaches the other, and the relay reports its end once both have ended.
    @Test func carriesBothDirectionsAndTheirEnds() throws {
        let (left, leftRelay) = try Self.pair()
        let (right, rightRelay) = try Self.pair()
        let ending = Ending()
        let relay = ByteRelay.start(leftRelay, rightRelay, bufferSize: 4096) { aborted in
            ending.lock.withLock { ending.aborted = aborted }
        }
        #expect(relay != nil)
        let forward = (0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let backward = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 13) }
        _ = startDetachedThread {
            try? writeAll(forward, to: left.rawValue)
            _ = shutdown(left.rawValue, Int32(SHUT_WR))
        }
        _ = startDetachedThread {
            try? writeAll(backward, to: right.rawValue)
            _ = shutdown(right.rawValue, Int32(SHUT_WR))
        }
        #expect(Self.readToEnd(right) == forward)
        #expect(Self.readToEnd(left) == backward)
        let deadline = ContinuousClock.now + .seconds(20)
        while ending.lock.withLock({ ending.aborted }) == nil && ContinuousClock.now < deadline {
            usleep(1_000)
        }
        #expect(ending.lock.withLock { ending.aborted } == false)
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
        #expect(Self.readToEnd(left).isEmpty)
        #expect(Self.readToEnd(right).isEmpty)
        let deadline = ContinuousClock.now + .seconds(20)
        while ending.lock.withLock({ ending.aborted }) == nil && ContinuousClock.now < deadline {
            usleep(1_000)
        }
        #expect(ending.lock.withLock { ending.aborted } == true)
    }
}
