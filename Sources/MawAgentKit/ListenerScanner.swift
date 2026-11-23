import CMawSystem
import MawCore
import MawProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Lists the guest's TCP listeners that `localhost` forwarding carries to the Mac, with
/// netlink `sock_diag` (docs/decisions/0023-localhost-forwarding.md). One scan sends a dump
/// request for IPv4 and one for IPv6 and reads the replies; Part 1 of phase 08 measured
/// 0.13 ms per scan on an idle machine, against 3.3 ms for `/proc/net/tcp` and `tcp6`.
public final class ListenerScanner {
    /// The kernel's side of the scan. Tests replace it.
    public struct Transport {
        /// Sends one request datagram.
        public var send: ([UInt8]) throws(SystemError) -> Void
        /// Receives one reply datagram, waiting at most `ListenerScanner.replyTimeout`.
        public var receive: () throws(SystemError) -> [UInt8]

        public init(
            send: @escaping ([UInt8]) throws(SystemError) -> Void,
            receive: @escaping () throws(SystemError) -> [UInt8]
        ) {
            self.send = send
            self.receive = receive
        }
    }

    public enum ScanError: Error, Equatable, CustomStringConvertible {
        case system(SystemError)
        /// The kernel answered the dump with this errno value.
        case kernel(Int32)
        case malformed(SocketDiagnostics.ParseError)
        /// A dump that does not end within `maximumDatagrams` replies.
        case tooLong

        public var description: String {
            switch self {
            case .system(let error): "sock_diag: \(error)"
            case .kernel(let code): "sock_diag: the kernel refused the dump with errno \(code)"
            case .malformed(let error): "sock_diag: a malformed reply: \(error)"
            case .tooLong: "sock_diag: the dump did not end"
            }
        }
    }

    /// How long a reply may take before the scan fails.
    public static let replyTimeout: Int32 = 1_000
    /// The largest reply datagram the agent reads. The kernel fills each datagram up to the
    /// reader's buffer, so a larger buffer means fewer datagrams.
    public static let datagramSize = 64 << 10
    /// A dump of more datagrams than this is abandoned; at 72 bytes per socket, it would list
    /// more than half a million sockets.
    public static let maximumDatagrams = 1_024

    private let transport: Transport
    private var sequence: UInt32 = 0

    public init(transport: Transport) {
        self.transport = transport
    }

    /// The forwarded listeners: those on 0.0.0.0, ::, 127.0.0.1, and ::1, without the agent's
    /// own sockets, `excludedInodes`.
    public func scan(excludingInodes excludedInodes: Set<UInt32> = []) throws(ScanError)
        -> Set<GuestListener>
    {
        var listeners: Set<GuestListener> = []
        for family in SocketDiagnostics.Family.allCases {
            sequence &+= 1
            do {
                try transport.send(SocketDiagnostics.request(family: family, sequence: sequence))
            } catch {
                throw .system(error)
            }
            var datagrams = 0
            while true {
                datagrams += 1
                guard datagrams <= Self.maximumDatagrams else { throw .tooLong }
                let datagram: [UInt8]
                do {
                    datagram = try transport.receive()
                } catch {
                    throw .system(error)
                }
                let reply: SocketDiagnostics.Reply
                do {
                    reply = try SocketDiagnostics.parse(
                        datagram, family: family, sequence: sequence)
                } catch {
                    throw .malformed(error)
                }
                for socket in reply.sockets {
                    if let listener = SocketDiagnostics.listener(
                        socket, excludingInodes: excludedInodes)
                    {
                        listeners.insert(listener)
                    }
                }
                if let code = reply.error { throw .kernel(code) }
                if reply.isDone { break }
            }
        }
        return listeners
    }
}

extension ListenerScanner.Transport {
    /// A NETLINK_SOCK_DIAG socket of the guest's kernel. The descriptor stays open for the
    /// scanner's life, closed on exec.
    public static func kernel() throws(SystemError) -> ListenerScanner.Transport {
        let descriptor = maw_socket_diagnostics_open()
        guard descriptor >= 0 else { throw SystemError("socket(AF_NETLINK, NETLINK_SOCK_DIAG)") }
        let socket = OwnedDescriptor(descriptor)
        return ListenerScanner.Transport(
            send: { (request: [UInt8]) throws(SystemError) in
                let code = request.withUnsafeBytes {
                    maw_socket_diagnostics_send(socket.rawValue, $0.baseAddress, $0.count)
                }
                guard code == 0 else { throw SystemError("sendto(sock_diag)", code: code) }
            },
            receive: { () throws(SystemError) -> [UInt8] in
                var poll = [pollfd(fd: socket.rawValue, events: Int16(POLLIN), revents: 0)]
                guard try pollDescriptors(&poll, timeout: ListenerScanner.replyTimeout) > 0
                else { throw SystemError("recv(sock_diag)", code: ETIMEDOUT) }
                var buffer = [UInt8](repeating: 0, count: ListenerScanner.datagramSize)
                while true {
                    let count = buffer.withUnsafeMutableBytes {
                        recv(socket.rawValue, $0.baseAddress, $0.count, 0)
                    }
                    if count < 0 && errno == EINTR { continue }
                    guard count >= 0 else { throw SystemError("recv(sock_diag)") }
                    return Array(buffer[..<count])
                }
            })
    }
}
