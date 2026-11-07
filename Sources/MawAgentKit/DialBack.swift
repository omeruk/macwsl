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

/// Why the agent could not open a connection to the host for a `dialBack` request. The agent
/// reports it to the host as an `error` with code `dialBackFailed`.
public enum DialBackError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No socket could be created.
    case socketFailed(SystemError)
    /// Every source port from 1023 down to 1 is in use.
    case noFreePort
    /// Binding a source port failed for a reason other than its being in use, such as EACCES
    /// for an agent without CAP_NET_BIND_SERVICE.
    case bindFailed(port: UInt32, SystemError)
    /// The host refused the connection, or it failed.
    case connectFailed(SystemError)
    /// The connection did not complete within the dial's timeout.
    case timedOut(Duration)

    public var description: String {
        switch self {
        case .socketFailed(let error):
            "cannot create a vsock socket: \(error)"
        case .noFreePort:
            "no source port below 1024 is free"
        case .bindFailed(let port, let error):
            "cannot bind source port \(port): \(error)"
        case .connectFailed(let error):
            "cannot connect to the host: \(error)"
        case .timedOut(let timeout):
            "the connection to the host did not complete within \(timeout.milliseconds) ms"
        }
    }
}

/// The system calls that a dial makes. Tests replace them.
public struct DialBackSystem: Sendable {
    /// Opens a non-blocking stream socket.
    public var openSocket: @Sendable () throws(SystemError) -> OwnedDescriptor
    /// Binds the socket to a source port. Returns 0 or an errno value.
    public var bind: @Sendable (_ descriptor: Int32, _ port: UInt32) -> Int32
    /// Starts connecting to the host's `port`. Returns 0, EINPROGRESS, or an errno value.
    public var connect: @Sendable (_ descriptor: Int32, _ port: UInt32) -> Int32
    /// The outcome of a connection in progress, once the socket is writable: 0 or an errno
    /// value.
    public var pendingError: @Sendable (_ descriptor: Int32) -> Int32

    public init(
        openSocket: @escaping @Sendable () throws(SystemError) -> OwnedDescriptor,
        bind: @escaping @Sendable (Int32, UInt32) -> Int32,
        connect: @escaping @Sendable (Int32, UInt32) -> Int32,
        pendingError: @escaping @Sendable (Int32) -> Int32
    ) {
        self.openSocket = openSocket
        self.bind = bind
        self.connect = connect
        self.pendingError = pendingError
    }

    /// vsock, to the host's context ID (2).
    public static let vsock = DialBackSystem(
        openSocket: { () throws(SystemError) -> OwnedDescriptor in
            let descriptor = maw_vsock_socket()
            guard descriptor >= 0 else { throw SystemError("socket(AF_VSOCK)") }
            return OwnedDescriptor(descriptor)
        },
        bind: { maw_vsock_bind($0, $1) },
        connect: { maw_vsock_connect($0, DialBackDialer.hostContextID, $1) },
        pendingError: { descriptor in
            var error: Int32 = 0
            let result = maw_socket_error(descriptor, &error)
            return result == 0 ? error : result
        })
}

/// Opens the agent's connection to the host for a `dialBack` request.
///
/// The source port is the highest free one below 1024, so that the host can refuse at once a
/// connection from a guest process without CAP_NET_BIND_SERVICE. That only filters: a process
/// with the capability, such as root in a container, can bind such a port too. The nonce
/// that the agent sends first is what the host checks.
public struct DialBackDialer: Sendable {
    /// The host's vsock context ID (`VMADDR_CID_HOST`).
    public static let hostContextID: UInt32 = 2
    public static let highestSourcePort: UInt32 = 1023
    public static let lowestSourcePort: UInt32 = 1

    public var system: DialBackSystem
    /// The host's port.
    public var port: UInt32
    /// How long the connection may take once a source port is bound.
    public var timeout: Duration

    public init(
        system: DialBackSystem = .vsock, port: UInt32 = AgentProtocol.dialBackPort,
        timeout: Duration = .seconds(2)
    ) {
        self.system = system
        self.port = port
        self.timeout = timeout
    }

    /// Binds the highest free source port below 1024, counting down and skipping ports in use,
    /// and connects to the host. Returns the connected socket, or throws without leaving one
    /// open.
    public func dial() throws(DialBackError) -> OwnedDescriptor {
        let socket: OwnedDescriptor
        do {
            socket = try system.openSocket()
        } catch {
            throw .socketFailed(error)
        }
        do throws(DialBackError) {
            try bindSourcePort(socket.rawValue)
            try connect(socket.rawValue)
            return socket
        } catch {
            socket.close()
            throw error
        }
    }

    private func bindSourcePort(_ descriptor: Int32) throws(DialBackError) {
        var sourcePort = Self.highestSourcePort
        while true {
            let error = system.bind(descriptor, sourcePort)
            switch error {
            case 0:
                return
            case EADDRINUSE where sourcePort > Self.lowestSourcePort:
                sourcePort -= 1
            case EADDRINUSE:
                throw .noFreePort
            default:
                throw .bindFailed(port: sourcePort, SystemError("bind", code: error))
            }
        }
    }

    private func connect(_ descriptor: Int32) throws(DialBackError) {
        let deadline = ContinuousClock.now + timeout
        let started = system.connect(descriptor, port)
        switch started {
        case 0:
            return
        case EINPROGRESS:
            break
        default:
            throw .connectFailed(SystemError("connect", code: started))
        }
        var request = [pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)]
        let ready: Int32
        do {
            ready = try pollDescriptors(&request, timeout: pollTimeout(until: deadline))
        } catch {
            throw .connectFailed(error)
        }
        guard ready > 0 else { throw .timedOut(timeout) }
        let outcome = system.pendingError(descriptor)
        guard outcome == 0 else {
            throw .connectFailed(SystemError("connect", code: outcome))
        }
    }
}
