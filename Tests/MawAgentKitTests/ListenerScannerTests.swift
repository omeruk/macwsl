import MawAgentKit
import MawProtocol
import Testing

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@Suite struct ListenerScannerTests {
    static func le32(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    static func le16(_ value: UInt16) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    /// The sequence number of a request datagram.
    static func sequence(of request: [UInt8]) -> UInt32 {
        request[8..<12].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func socket(
        family: UInt8, port: UInt16, address: [UInt8], inode: UInt32, sequence: UInt32
    ) -> [UInt8] {
        var body: [UInt8] = [family, 10, 0, 0, UInt8(port >> 8), UInt8(port & 0xFF), 0, 0]
        body += address + [UInt8](repeating: 0, count: 16 - address.count)
        body += [UInt8](repeating: 0, count: 28)
        body += le32(0) + le32(0) + le32(0) + le32(0) + le32(inode)
        return le32(UInt32(16 + body.count)) + le16(20) + le16(2) + le32(sequence) + le32(0)
            + body
    }

    static func done(sequence: UInt32) -> [UInt8] {
        le32(20) + le16(3) + le16(2) + le32(sequence) + le32(0) + le32(0)
    }

    /// A kernel that answers each request with `replies(family, sequence)`, one datagram at a
    /// time.
    final class FakeKernel {
        var pending: [[UInt8]] = []
        var requests: [[UInt8]] = []
        let replies: (UInt8, UInt32) -> [[UInt8]]

        init(replies: @escaping (UInt8, UInt32) -> [[UInt8]]) {
            self.replies = replies
        }

        var transport: ListenerScanner.Transport {
            ListenerScanner.Transport(
                send: { request in
                    self.requests.append(request)
                    self.pending = self.replies(
                        request[16], ListenerScannerTests.sequence(of: request))
                },
                receive: { () throws(SystemError) -> [UInt8] in
                    guard !self.pending.isEmpty else {
                        throw SystemError("recv", code: ETIMEDOUT)
                    }
                    return self.pending.removeFirst()
                })
        }
    }

    @Test func listsWildcardAndLoopbackListenersOfBothFamilies() throws {
        let kernel = FakeKernel { family, sequence in
            if family == 2 {
                return [
                    Self.socket(
                        family: 2, port: 8000, address: [0, 0, 0, 0], inode: 1, sequence: sequence)
                        + Self.socket(
                            family: 2, port: 53, address: [127, 0, 0, 53], inode: 2,
                            sequence: sequence),
                    Self.socket(
                        family: 2, port: 5432, address: [127, 0, 0, 1], inode: 3, sequence: sequence
                    )
                        + Self.done(sequence: sequence),
                ]
            }
            return [
                Self.socket(
                    family: 10, port: 8000, address: [UInt8](repeating: 0, count: 16), inode: 4,
                    sequence: sequence)
                    + Self.socket(
                        family: 10, port: 9000, address: [UInt8](repeating: 0, count: 15) + [1],
                        inode: 5,
                        sequence: sequence) + Self.done(sequence: sequence)
            ]
        }
        let scanner = ListenerScanner(transport: kernel.transport)
        let listeners = try scanner.scan(excludingInodes: [5])
        #expect(
            listeners == [
                GuestListener(port: 8000, address: .anyIPv4),
                GuestListener(port: 5432, address: .loopbackIPv4),
                GuestListener(port: 8000, address: .anyIPv6),
            ])
        #expect(kernel.requests.map { $0[16] } == [2, 10])
        // Each request has a sequence number of its own.
        #expect(Set(kernel.requests.map(Self.sequence(of:))).count == 2)
    }

    @Test func reportsTheKernelsRefusal() {
        let kernel = FakeKernel { _, sequence in
            [
                Self.le32(36) + Self.le16(2) + Self.le16(0) + Self.le32(sequence) + Self.le32(0)
                    + Self.le32(UInt32(bitPattern: -2)) + [UInt8](repeating: 0, count: 16)
            ]
        }
        #expect(throws: ListenerScanner.ScanError.kernel(-2)) {
            try ListenerScanner(transport: kernel.transport).scan()
        }
    }

    @Test func failsWhenAReplyDoesNotCome() {
        let kernel = FakeKernel { _, _ in [] }
        #expect(throws: ListenerScanner.ScanError.system(SystemError("recv", code: ETIMEDOUT))) {
            try ListenerScanner(transport: kernel.transport).scan()
        }
    }

    @Test func failsOnAReplyToAnotherRequest() {
        let kernel = FakeKernel { _, sequence in [Self.done(sequence: sequence &+ 7)] }
        #expect(throws: ListenerScanner.ScanError.self) {
            try ListenerScanner(transport: kernel.transport).scan()
        }
    }

    @Test func abandonsADumpThatDoesNotEnd() {
        let kernel = FakeKernel { _, sequence in
            Array(
                repeating: Self.socket(
                    family: 2, port: 1, address: [10, 0, 0, 1], inode: 1, sequence: sequence),
                count: ListenerScanner.maximumDatagrams + 1)
        }
        #expect(throws: ListenerScanner.ScanError.tooLong) {
            try ListenerScanner(transport: kernel.transport).scan()
        }
    }
}
