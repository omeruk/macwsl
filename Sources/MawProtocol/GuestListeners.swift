/// A TCP listener in the guest that `localhost` forwarding carries to the Mac
/// (docs/decisions/0023-localhost-forwarding.md): a port on a wildcard or a loopback address.
public struct GuestListener: Hashable, Sendable, Codable, Comparable,
    CustomStringConvertible
{
    /// The listening addresses that are forwarded. Every other address, such as
    /// systemd-resolved's 127.0.0.53 or a container bridge, is not.
    public enum Address: String, Hashable, Sendable, Codable, CaseIterable {
        /// 0.0.0.0
        case anyIPv4
        /// ::
        case anyIPv6
        /// 127.0.0.1
        case loopbackIPv4
        /// ::1
        case loopbackIPv6

        public var isIPv6: Bool { self == .anyIPv6 || self == .loopbackIPv6 }
    }

    public var port: UInt16
    public var address: Address

    public init(port: UInt16, address: Address) {
        self.port = port
        self.address = address
    }

    public static func < (lhs: GuestListener, rhs: GuestListener) -> Bool {
        (lhs.port, lhs.address.rawValue) < (rhs.port, rhs.address.rawValue)
    }

    public var description: String {
        switch address {
        case .anyIPv4: "0.0.0.0:\(port)"
        case .anyIPv6: "[::]:\(port)"
        case .loopbackIPv4: "127.0.0.1:\(port)"
        case .loopbackIPv6: "[::1]:\(port)"
        }
    }
}

/// The netlink `sock_diag` messages with which the agent lists the guest's listening TCP
/// sockets: `SOCK_DIAG_BY_FAMILY` with `inet_diag_req_v2`, answered by `inet_diag_msg`s
/// (linux/sock_diag.h, linux/inet_diag.h). Pure, so that its tests run on the Mac.
///
/// Netlink headers and `inet_diag_msg`'s counters are in the host's byte order; ports and
/// addresses in `inet_diag_sockid` are in network order. The guest is aarch64, little-endian,
/// like the Macs that run the tests.
public enum SocketDiagnostics {
    /// `AF_INET` and `AF_INET6` on Linux.
    public enum Family: UInt8, Sendable, CaseIterable {
        case ipv4 = 2
        case ipv6 = 10
    }

    /// One socket from a reply.
    public struct Socket: Equatable, Sendable {
        public var family: Family
        public var state: UInt8
        public var port: UInt16
        /// 4 bytes for IPv4, 16 for IPv6, in network order.
        public var address: [UInt8]
        public var inode: UInt32

        public init(family: Family, state: UInt8, port: UInt16, address: [UInt8], inode: UInt32) {
            self.family = family
            self.state = state
            self.port = port
            self.address = address
            self.inode = inode
        }
    }

    /// What one datagram of a reply holds.
    public struct Reply: Equatable, Sendable {
        public var sockets: [Socket] = []
        /// `NLMSG_DONE` arrived: the dump is complete.
        public var isDone = false
        /// `NLMSG_ERROR` with this negative errno value; the dump has ended.
        public var error: Int32?

        public init(sockets: [Socket] = [], isDone: Bool = false, error: Int32? = nil) {
            self.sockets = sockets
            self.isDone = isDone
            self.error = error
        }
    }

    public enum ParseError: Error, Equatable, Sendable {
        /// A header or message is shorter than its type requires, or a length runs past the
        /// datagram.
        case truncated
        /// A socket of a family that was not asked for.
        case unexpectedFamily(UInt8)
        /// The reply's sequence number is not the request's.
        case unexpectedSequence(UInt32)
    }

    /// `TCP_LISTEN` in the kernel's `tcp_states.h`.
    public static let listenState: UInt8 = 10
    /// `SOCK_DIAG_BY_FAMILY`.
    static let requestType: UInt16 = 20
    static let doneType: UInt16 = 3
    static let errorType: UInt16 = 2
    /// `NLM_F_REQUEST | NLM_F_DUMP`.
    static let dumpFlags: UInt16 = 0x0001 | 0x0300
    static let headerSize = 16
    /// `inet_diag_req_v2`: family, protocol, ext, pad, states, then `inet_diag_sockid`.
    static let requestBodySize = 56
    /// `inet_diag_msg`: family, state, timer, retrans, `inet_diag_sockid` (48 bytes),
    /// expires, rqueue, wqueue, uid, inode.
    static let messageSize = 72
    /// `IPPROTO_TCP`.
    static let tcp: UInt8 = 6

    /// A dump request for the TCP sockets of `family` in the listening state.
    public static func request(family: Family, sequence: UInt32) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(headerSize + requestBodySize)
        append(UInt32(headerSize + requestBodySize), to: &bytes)
        append(requestType, to: &bytes)
        append(dumpFlags, to: &bytes)
        append(sequence, to: &bytes)
        append(UInt32(0), to: &bytes)
        bytes += [family.rawValue, tcp, 0, 0]
        append(UInt32(1) << UInt32(listenState), to: &bytes)
        bytes += [UInt8](repeating: 0, count: 48)
        return bytes
    }

    /// Reads one datagram of a reply to `request(family:sequence:)`.
    public static func parse(
        _ datagram: some RandomAccessCollection<UInt8>, family: Family, sequence: UInt32
    ) throws(ParseError) -> Reply {
        let bytes = Array(datagram)
        var reply = Reply()
        var offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= headerSize else { throw .truncated }
            let length = Int(readUInt32(bytes, offset))
            let type = readUInt16(bytes, offset + 4)
            let replySequence = readUInt32(bytes, offset + 8)
            guard length >= headerSize, length <= bytes.count - offset else { throw .truncated }
            guard replySequence == sequence else { throw .unexpectedSequence(replySequence) }
            let body = offset + headerSize
            switch type {
            case doneType:
                reply.isDone = true
                return reply
            case errorType:
                guard length - headerSize >= 4 else { throw .truncated }
                reply.error = Int32(bitPattern: readUInt32(bytes, body))
                return reply
            case requestType:
                guard length - headerSize >= messageSize else { throw .truncated }
                guard bytes[body] == family.rawValue else {
                    throw .unexpectedFamily(bytes[body])
                }
                let port = UInt16(bytes[body + 4]) << 8 | UInt16(bytes[body + 5])
                let addressStart = body + 8
                let addressLength = family == .ipv4 ? 4 : 16
                reply.sockets.append(
                    Socket(
                        family: family, state: bytes[body + 1], port: port,
                        address: Array(bytes[addressStart..<addressStart + addressLength]),
                        inode: readUInt32(bytes, body + 68)))
            default:
                // NLMSG_NOOP and other control messages carry nothing for a dump.
                break
            }
            // NLMSG_ALIGN: messages start on 4-byte boundaries.
            offset += (length + 3) & ~3
        }
        return reply
    }

    /// The forwarded listener that a socket is, or `nil`: a socket that is not listening, one
    /// on another address, port 0, or one of `excludedInodes`, the agent's own sockets.
    public static func listener(_ socket: Socket, excludingInodes excludedInodes: Set<UInt32>)
        -> GuestListener?
    {
        guard socket.state == listenState, socket.port != 0,
            !excludedInodes.contains(socket.inode)
        else { return nil }
        let address: GuestListener.Address
        switch (socket.family, socket.address) {
        case (.ipv4, [0, 0, 0, 0]): address = .anyIPv4
        case (.ipv4, [127, 0, 0, 1]): address = .loopbackIPv4
        case (.ipv6, [UInt8](repeating: 0, count: 16)): address = .anyIPv6
        case (.ipv6, [UInt8](repeating: 0, count: 15) + [1]): address = .loopbackIPv6
        default: return nil
        }
        return GuestListener(port: socket.port, address: address)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { bytes += $0 }
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
}
