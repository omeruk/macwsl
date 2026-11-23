import Testing

@testable import MawProtocol

@Suite struct SocketDiagnosticsTests {
    typealias Family = SocketDiagnostics.Family

    static func le32(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
    static func le16(_ value: UInt16) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    static func header(length: Int, type: UInt16, sequence: UInt32) -> [UInt8] {
        le32(UInt32(length)) + le16(type) + le16(2) + le32(sequence) + le32(77)
    }

    /// One `inet_diag_msg` in its netlink header.
    static func message(
        family: Family, state: UInt8 = 10, port: UInt16, address: [UInt8], inode: UInt32 = 1,
        sequence: UInt32 = 5
    ) -> [UInt8] {
        var body: [UInt8] = [family.rawValue, state, 0, 0]
        body += [UInt8(port >> 8), UInt8(port & 0xFF), 0, 0]
        body += address + [UInt8](repeating: 0, count: 16 - address.count)
        body += [UInt8](repeating: 0, count: 16)  // destination
        body += le32(0) + le32(0) + le32(0)  // interface, cookie
        body += le32(0) + le32(0) + le32(0) + le32(1000) + le32(inode)
        return header(length: 16 + body.count, type: 20, sequence: sequence) + body
    }

    static func done(sequence: UInt32 = 5) -> [UInt8] {
        header(length: 20, type: 3, sequence: sequence) + le32(0)
    }

    static let loopback6 = [UInt8](repeating: 0, count: 15) + [1]
    static let any6 = [UInt8](repeating: 0, count: 16)

    @Test func buildsADumpRequestForListeningTCPSockets() {
        let request = SocketDiagnostics.request(family: .ipv6, sequence: 9)
        #expect(request.count == 72)
        #expect(Array(request[0..<4]) == Self.le32(72))
        #expect(Array(request[4..<6]) == Self.le16(20))
        #expect(Array(request[6..<8]) == Self.le16(0x0301))
        #expect(Array(request[8..<12]) == Self.le32(9))
        #expect(Array(request[16..<20]) == [10, 6, 0, 0])
        #expect(Array(request[20..<24]) == Self.le32(1 << 10))
        #expect(request[24...].allSatisfy { $0 == 0 })
    }

    @Test func readsSocketsAndTheEndOfTheDump() throws {
        let datagram =
            Self.message(family: .ipv4, port: 8000, address: [0, 0, 0, 0], inode: 11)
            + Self.message(family: .ipv4, port: 53, address: [127, 0, 0, 53], inode: 12)
            + Self.done()
        let reply = try SocketDiagnostics.parse(datagram, family: .ipv4, sequence: 5)
        #expect(reply.isDone)
        #expect(reply.error == nil)
        #expect(
            reply.sockets == [
                .init(family: .ipv4, state: 10, port: 8000, address: [0, 0, 0, 0], inode: 11),
                .init(family: .ipv4, state: 10, port: 53, address: [127, 0, 0, 53], inode: 12),
            ])
    }

    @Test func aDumpCanSpanSeveralDatagrams() throws {
        let first = try SocketDiagnostics.parse(
            Self.message(family: .ipv6, port: 3000, address: Self.any6), family: .ipv6,
            sequence: 5)
        #expect(!first.isDone)
        #expect(first.sockets.count == 1)
        let second = try SocketDiagnostics.parse(Self.done(), family: .ipv6, sequence: 5)
        #expect(second.isDone)
        #expect(second.sockets.isEmpty)
    }

    @Test func reportsAnError() throws {
        let datagram =
            Self.header(length: 36, type: 2, sequence: 5) + Self.le32(UInt32(bitPattern: -2))
            + [UInt8](repeating: 0, count: 16)
        let reply = try SocketDiagnostics.parse(datagram, family: .ipv4, sequence: 5)
        #expect(reply.error == -2)
    }

    @Test func refusesMalformedReplies() {
        let message = Self.message(family: .ipv4, port: 80, address: [0, 0, 0, 0])
        // A header cut short.
        #expect(throws: SocketDiagnostics.ParseError.truncated) {
            try SocketDiagnostics.parse(message[0..<10], family: .ipv4, sequence: 5)
        }
        // A length that runs past the datagram.
        #expect(throws: SocketDiagnostics.ParseError.truncated) {
            try SocketDiagnostics.parse(message.dropLast(4), family: .ipv4, sequence: 5)
        }
        // A length shorter than a header.
        #expect(throws: SocketDiagnostics.ParseError.truncated) {
            try SocketDiagnostics.parse(
                Self.le32(8) + Array(message[4...]), family: .ipv4, sequence: 5)
        }
        // A socket message too short for inet_diag_msg.
        #expect(throws: SocketDiagnostics.ParseError.truncated) {
            try SocketDiagnostics.parse(
                Self.header(length: 24, type: 20, sequence: 5) + [2, 10, 0, 0, 0, 0, 0, 0],
                family: .ipv4, sequence: 5)
        }
        // An error message without its code.
        #expect(throws: SocketDiagnostics.ParseError.truncated) {
            try SocketDiagnostics.parse(
                Self.header(length: 16, type: 2, sequence: 5), family: .ipv4, sequence: 5)
        }
        #expect(throws: SocketDiagnostics.ParseError.unexpectedFamily(2)) {
            try SocketDiagnostics.parse(message, family: .ipv6, sequence: 5)
        }
        #expect(throws: SocketDiagnostics.ParseError.unexpectedSequence(5)) {
            try SocketDiagnostics.parse(message, family: .ipv4, sequence: 6)
        }
    }

    @Test func keepsWildcardAndLoopbackListenersOnly() {
        func listener(_ family: Family, _ address: [UInt8], state: UInt8 = 10, port: UInt16 = 8000)
            -> GuestListener?
        {
            SocketDiagnostics.listener(
                .init(family: family, state: state, port: port, address: address, inode: 3),
                excludingInodes: [])
        }
        #expect(listener(.ipv4, [0, 0, 0, 0]) == GuestListener(port: 8000, address: .anyIPv4))
        #expect(
            listener(.ipv4, [127, 0, 0, 1]) == GuestListener(port: 8000, address: .loopbackIPv4))
        #expect(listener(.ipv6, Self.any6) == GuestListener(port: 8000, address: .anyIPv6))
        #expect(
            listener(.ipv6, Self.loopback6) == GuestListener(port: 8000, address: .loopbackIPv6))
        // systemd-resolved's stub listeners, another loopback address, a bridge, the NAT address.
        #expect(listener(.ipv4, [127, 0, 0, 53]) == nil)
        #expect(listener(.ipv4, [127, 0, 0, 54]) == nil)
        #expect(listener(.ipv4, [127, 1, 0, 1]) == nil)
        #expect(listener(.ipv4, [172, 17, 0, 1]) == nil)
        #expect(listener(.ipv4, [192, 168, 64, 2]) == nil)
        // IPv4-mapped loopback and a link-local IPv6 address.
        #expect(
            listener(.ipv6, [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF, 127, 0, 0, 1]) == nil)
        #expect(listener(.ipv6, [0xFE, 0x80] + [UInt8](repeating: 0, count: 13) + [1]) == nil)
        // Not listening, and port 0.
        #expect(listener(.ipv4, [0, 0, 0, 0], state: 1) == nil)
        #expect(listener(.ipv4, [0, 0, 0, 0], port: 0) == nil)
    }

    @Test func leavesOutTheAgentsOwnSockets() {
        let socket = SocketDiagnostics.Socket(
            family: .ipv4, state: 10, port: 53, address: [127, 0, 0, 1], inode: 42)
        #expect(SocketDiagnostics.listener(socket, excludingInodes: [42]) == nil)
        #expect(SocketDiagnostics.listener(socket, excludingInodes: [41]) != nil)
    }

    @Test func listenersSortByPort() {
        let sorted = [
            GuestListener(port: 9000, address: .anyIPv4),
            GuestListener(port: 80, address: .loopbackIPv6),
            GuestListener(port: 80, address: .anyIPv4),
        ].sorted()
        #expect(sorted.map(\.port) == [80, 80, 9000])
        #expect(sorted.map(\.description) == ["0.0.0.0:80", "[::1]:80", "0.0.0.0:9000"])
    }
}
