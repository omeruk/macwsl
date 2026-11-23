import CMawSystem
import Logging
import MawCore
import MawProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// What the forwarding channel needs from the guest. `guest()` is the real one; tests supply
/// their own.
public struct ForwardingEnvironment: Sendable {
    /// Lists the guest's forwarded listeners, without the agent's own sockets.
    public var scanListeners: @Sendable () throws(ListenerScanner.ScanError) -> Set<GuestListener>
    /// Connects to the guest's listener on `port` over one family's loopback address.
    public var connectToListener:
        @Sendable (_ family: ForwardingConnect.Family, _ port: UInt16) throws(SystemError) ->
            OwnedDescriptor
    /// Dials the host's `AgentProtocol.forwardingPort`.
    public var dialHost: @Sendable () throws(DialBackError) -> OwnedDescriptor
    public var scanInterval: Duration
    public var maximumConnections: Int

    public init(
        scanListeners:
            @escaping @Sendable () throws(ListenerScanner.ScanError) -> Set<
                GuestListener
            >,
        connectToListener:
            @escaping @Sendable (ForwardingConnect.Family, UInt16) throws(SystemError) ->
            OwnedDescriptor = ForwardingEnvironment.connectOverLoopback,
        dialHost: @escaping @Sendable () throws(DialBackError) -> OwnedDescriptor = {
            () throws(DialBackError) -> OwnedDescriptor in
            try DialBackDialer(port: AgentProtocol.forwardingPort).dial()
        },
        scanInterval: Duration = AgentProtocol.listenerScanInterval,
        maximumConnections: Int = AgentProtocol.maximumForwardedConnections
    ) {
        self.scanListeners = scanListeners
        self.connectToListener = connectToListener
        self.dialHost = dialHost
        self.scanInterval = scanInterval
        self.maximumConnections = maximumConnections
    }

    /// How long the agent waits for the guest's listener to accept a connection.
    public static let connectTimeoutMilliseconds: Int32 = 2_000

    /// A blocking TCP connection to 127.0.0.1 or ::1.
    public static let connectOverLoopback:
        @Sendable (ForwardingConnect.Family, UInt16) throws(SystemError) -> OwnedDescriptor = {
            (family: ForwardingConnect.Family, port: UInt16) throws(SystemError) -> OwnedDescriptor
            in
            var descriptor: Int32 = -1
            let code = maw_tcp_connect_loopback(
                family == .ipv6 ? 1 : 0, port, connectTimeoutMilliseconds, &descriptor)
            guard code == 0 else { throw SystemError("connect", code: code) }
            return OwnedDescriptor(descriptor)
        }
}

/// The agent's side of a machine's forwarding channel (docs/protocol.md, "Forwarding"): it
/// reports the guest's listeners whenever they change, and connects each forwarded connection
/// that the host asks for.
///
/// The channel runs on the thread that received the `forwarding` request. Each `connect`
/// runs on a thread of its own, which reports a failure back through `results` and a pipe
/// that wakes the channel; a connection that succeeds is relayed by a `ByteRelay`.
final class ForwardingChannel: @unchecked Sendable {
    /// Output the host has not read beyond this closes the channel: the host reads the
    /// channel at all times, and only `listeners` and `connectFailed` are written to it.
    static let maximumPendingOutput = 1 << 20

    private let connection: FrameConnection
    private let environment: ForwardingEnvironment
    private let logger: Logger
    private let lock = ConditionLock()
    private var failures: [(id: UInt32, reason: String)] = []
    private var openConnections = 0
    private let wake: (read: OwnedDescriptor, write: OwnedDescriptor)

    init(
        connection: FrameConnection, environment: ForwardingEnvironment, logger: Logger
    ) throws(SystemError) {
        self.connection = connection
        self.environment = environment
        self.logger = logger
        var pipe: [Int32] = [-1, -1]
        let code = maw_pipe(&pipe)
        guard code == 0 else { throw SystemError("pipe", code: code) }
        wake = (OwnedDescriptor(pipe[0]), OwnedDescriptor(pipe[1]))
        _ = maw_set_nonblocking(pipe[0])
        _ = maw_set_nonblocking(pipe[1])
    }

    /// The forwarded connections open now; for tests.
    var connectionCount: Int { lock.withLock { openConnections } }

    /// Serves the channel until the host closes it. Forwarded connections that are open go on
    /// until they end.
    func run() throws(ConnectionError) {
        var reported: Set<GuestListener>?
        var scanFailed = false
        var nextScan = ContinuousClock.now
        while true {
            if ContinuousClock.now >= nextScan {
                nextScan = ContinuousClock.now + environment.scanInterval
                do {
                    let listeners = try environment.scanListeners()
                    scanFailed = false
                    if listeners != reported {
                        reported = listeners
                        connection.enqueue(.control(.listeners(listeners.sorted())))
                    }
                } catch {
                    if !scanFailed {
                        logger.warning("cannot list the guest's listeners: \(error)")
                    }
                    scanFailed = true
                    if reported == nil {
                        reported = []
                        connection.enqueue(.control(.listeners([])))
                    }
                }
            }
            for failure in takeFailures() {
                connection.enqueue(.control(.connectFailed(id: failure.id, reason: failure.reason)))
            }
            try connection.flush()
            guard connection.pendingOutputCount <= Self.maximumPendingOutput else {
                throw .unexpectedMessage("the host does not read the forwarding channel")
            }

            var requests = [
                pollfd(
                    fd: connection.rawDescriptor,
                    events: Int16(POLLIN)
                        | (connection.pendingOutputCount > 0 ? Int16(POLLOUT) : 0),
                    revents: 0),
                pollfd(fd: wake.read.rawValue, events: Int16(POLLIN), revents: 0),
            ]
            do {
                _ = try pollDescriptors(&requests, timeout: pollTimeout(until: nextScan))
            } catch {
                throw .system(error)
            }
            if requests[1].revents != 0 {
                var bytes = [UInt8](repeating: 0, count: 64)
                while read(wake.read.rawValue, &bytes, bytes.count) > 0 {}
            }
            if requests[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                try connection.receive()
                while let frame = try connection.nextFrame() {
                    let message: ControlMessage
                    do {
                        message = try frame.controlMessage()
                    } catch {
                        throw .frame(error)
                    }
                    guard case .connect(let request) = message else {
                        throw .unexpectedMessage(
                            "expected connect on the forwarding channel, received \(message.name)")
                    }
                    open(request)
                }
                if connection.isAtEndOfInput {
                    return
                }
            }
        }
    }

    /// Starts connecting one forwarded connection, or reports at once why it cannot.
    private func open(_ request: ForwardingConnect) {
        let admitted = lock.withLock {
            guard openConnections < environment.maximumConnections else { return false }
            openConnections += 1
            return true
        }
        guard admitted else {
            report(
                request.id,
                "the agent forwards \(environment.maximumConnections) connections already")
            return
        }
        let started = startDetachedThread { [self] in
            connect(request)
        }
        if !started {
            connectionEnded()
            report(request.id, "the agent could not start a thread")
        }
    }

    private func connect(_ request: ForwardingConnect) {
        let listener: OwnedDescriptor
        do {
            listener = try environment.connectToListener(request.family, request.port)
        } catch {
            connectionEnded()
            report(request.id, error.description)
            return
        }
        let host: OwnedDescriptor
        do {
            host = try environment.dialHost()
            _ = maw_set_blocking(host.rawValue)
            try writeAll(Frame.dialBackNonce(request.nonce).encoded, to: host.rawValue)
        } catch {
            listener.close()
            connectionEnded()
            logger.warning("cannot dial the host for a forwarded connection: \(error)")
            report(request.id, "cannot dial the host: \(error)")
            return
        }
        let relay = ByteRelay.start(listener, host) { [self] _ in connectionEnded() }
        if relay == nil {
            connectionEnded()
        }
    }

    private func connectionEnded() {
        lock.withLock { openConnections -= 1 }
    }

    private func report(_ id: UInt32, _ reason: String) {
        var bounded = reason
        while bounded.utf8.count > ForwardingConnect.maximumReasonSize {
            bounded.removeLast()
        }
        lock.withLock { failures.append((id, bounded)) }
        var byte: UInt8 = 1
        _ = write(wake.write.rawValue, &byte, 1)
    }

    private func takeFailures() -> [(id: UInt32, reason: String)] {
        lock.withLock {
            defer { failures = [] }
            return failures
        }
    }
}
