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

/// What the agent needs from its surroundings. The guest uses `guest()`; tests supply their
/// own power-off action.
public struct AgentConfiguration: Sendable {
    /// Asks the system to power off. Must return promptly; the power-off happens afterward.
    public var powerOff: @Sendable () throws(SystemError) -> Void
    /// Connections served at once. Beyond this, a connection receives a `busy` error.
    public var maximumConnections: Int
    /// How long a new connection may take to send its version and its request.
    public var requestTimeout: Duration
    /// The guest's files that sessions are planned from: accounts, `maw.conf`, locales.
    public var system: GuestSystem
    /// How long a login shell waits for the system bus, so that `systemd-logind` can register
    /// it, when the machine has only just started.
    public var systemBusTimeout: Duration
    /// Opens the connection to the host that a `dialBack` request asks for. The guest dials
    /// over vsock (`DialBackDialer`); tests supply their own.
    public var dialBack: @Sendable () throws(DialBackError) -> OwnedDescriptor

    public init(
        maximumConnections: Int = AgentProtocol.maximumConnections,
        requestTimeout: Duration = .seconds(10),
        system: GuestSystem = .live,
        systemBusTimeout: Duration = .seconds(2),
        dialBack: @escaping @Sendable () throws(DialBackError) -> OwnedDescriptor = {
            () throws(DialBackError) -> OwnedDescriptor in
            try DialBackDialer().dial()
        },
        powerOff: @escaping @Sendable () throws(SystemError) -> Void
    ) {
        self.maximumConnections = maximumConnections
        self.requestTimeout = requestTimeout
        self.system = system
        self.systemBusTimeout = systemBusTimeout
        self.dialBack = dialBack
        self.powerOff = powerOff
    }
}

/// The guest agent's server: accepts connections and serves each one on its own thread.
///
/// docs/protocol.md describes the conversation on a connection. A connection that breaks the
/// protocol is closed, with an `error` frame where possible; no input closes more than that one
/// connection. `activeConnections` is guarded by `lock`.
public final class AgentServer: @unchecked Sendable {
    public let configuration: AgentConfiguration
    private let logger = Logger(label: "dev.maw.agent")
    private let lock = ConditionLock()
    private var activeConnections = 0

    public init(configuration: AgentConfiguration) {
        self.configuration = configuration
    }

    /// Accepts connections from the host on the vsock `listener` until accepting fails for a
    /// reason other than a transient one, then throws.
    ///
    /// Only the host may connect. The agent runs commands as root, and processes inside the
    /// guest can reach a vsock port too, through the loopback transport, so a connection from
    /// any other context ID is closed before a byte is read (docs/security.md).
    public func acceptConnections(on listener: OwnedDescriptor) throws(SystemError) -> Never {
        while true {
            var peer: UInt32 = 0
            let descriptor = maw_vsock_accept_host(listener.rawValue, &peer)
            if descriptor < 0 {
                switch errno {
                case EPERM:
                    logger.warning(
                        "refused a connection from vsock context \(peer), which is not the host")
                    continue
                case EINTR, ECONNABORTED, EAGAIN:
                    continue
                case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                    // Out of resources: wait for sessions to finish rather than spin.
                    logger.warning("accept: \(SystemError.message(for: errno)); retrying")
                    usleep(100_000)
                    continue
                default:
                    throw SystemError("accept")
                }
            }
            serveOnNewThread(OwnedDescriptor(descriptor))
        }
    }

    /// Serves one connection on a new thread, or refuses it with `busy` at the limit.
    public func serveOnNewThread(_ descriptor: OwnedDescriptor) {
        let admitted = lock.withLock {
            guard activeConnections < configuration.maximumConnections else { return false }
            activeConnections += 1
            return true
        }
        guard admitted else {
            refuse(descriptor)
            return
        }
        let started = startDetachedThread { [self] in
            serve(descriptor)
            lock.withLock { activeConnections -= 1 }
        }
        if !started {
            lock.withLock { activeConnections -= 1 }
            logger.error("could not start a thread for a connection")
            descriptor.close()
        }
    }

    /// Serves one connection on the calling thread, then closes it.
    public func serve(_ descriptor: OwnedDescriptor) {
        defer { descriptor.close() }
        let connection: FrameConnection
        do {
            connection = try FrameConnection(descriptor)
        } catch {
            logger.error("cannot use a new connection: \(error)")
            return
        }
        serve(connection, dialed: false)
    }

    /// Serves `connection`. After a `dialBack` request, closes it and serves the connection
    /// the agent dialed, on the same thread and in the same slot of `maximumConnections`.
    private func serve(_ connection: FrameConnection, dialed: Bool) {
        let next: FrameConnection?
        do {
            next = try converse(on: connection, dialed: dialed)
        } catch {
            report(error, on: connection)
            return
        }
        guard let next else { return }
        connection.descriptor.close()
        defer { next.descriptor.close() }
        serve(next, dialed: true)
    }

    // MARK: Conversation

    /// Answers the connection's one request. Returns the connection the agent dialed, after a
    /// `dialBack` request that succeeded.
    private func converse(on connection: FrameConnection, dialed: Bool) throws(ConnectionError)
        -> FrameConnection?
    {
        let deadline = ContinuousClock.now + configuration.requestTimeout
        let remote = try connection.exchangeVersions(until: deadline)
        guard remote == ProtocolVersion.current else {
            throw .versionMismatch(local: ProtocolVersion.current, remote: remote)
        }

        let request = try connection.receiveControl(until: deadline, expecting: "a request")
        switch request {
        case .info:
            connection.enqueue(
                .control(
                    .agentInfo(
                        AgentInfo(
                            agentVersion: MawVersion.current,
                            protocolVersion: ProtocolVersion.current,
                            kernelRelease: SystemInfo.kernelRelease(),
                            uptimeMilliseconds: SystemInfo.uptimeMilliseconds()))))
        case .shutdown:
            logger.notice("shutdown requested; powering off")
            do {
                try configuration.powerOff()
                connection.enqueue(.control(.shutdownAcknowledged))
            } catch {
                logger.error("cannot power off: \(error)")
                connection.enqueue(.control(.error(AgentError(.shutdownFailed, "\(error)"))))
            }
        case .exec(let execRequest):
            let child: ChildProcess
            do {
                let plan = try SessionPlanner.plan(execRequest, system: configuration.system)
                if plan.waitsForSystemBus {
                    waitForSystemBus()
                }
                child = try ChildProcess.spawn(plan, terminal: execRequest.terminal)
            } catch {
                connection.enqueue(
                    .control(.error(AgentError(error.code, error.message, user: error.user))))
                break
            }
            try ExecSession(connection: connection, child: child, logger: logger).run()
            return nil
        case .dialBack(let nonce):
            // A dialed connection is the host's session; it does not ask for another.
            guard !dialed else {
                throw .unexpectedMessage(
                    "dialBack is not valid on a connection that the agent dialed")
            }
            if let dialedConnection = dial(replyingOn: connection) {
                dialedConnection.enqueue(.dialBackNonce(nonce))
                connection.enqueue(.control(.dialedBack))
                try connection.flush(until: .now + configuration.requestTimeout)
                return dialedConnection
            }
        default:
            throw .unexpectedMessage(
                "expected a request (exec, info, shutdown, or dialBack), received \(request.name)")
        }
        try connection.flush(until: .now + configuration.requestTimeout)
        return nil
    }

    /// Opens the connection that a `dialBack` request asks for. On failure, queues a
    /// `dialBackFailed` error on `connection` and returns `nil`.
    private func dial(replyingOn connection: FrameConnection) -> FrameConnection? {
        let reason: String
        do throws(DialBackError) {
            let descriptor = try configuration.dialBack()
            do {
                return try FrameConnection(descriptor)
            } catch {
                descriptor.close()
                reason = "cannot use the dialed connection: \(error)"
            }
        } catch {
            reason = error.description
        }
        logger.warning("cannot dial the host back: \(reason)")
        connection.enqueue(.control(.error(AgentError(.dialBackFailed, reason))))
        return nil
    }

    /// Waits until the system bus's socket exists, for at most `systemBusTimeout`. Right after
    /// boot, a login shell can be requested before `dbus.socket` listens; `pam_systemd` would
    /// then skip the session's registration. Once the socket exists, `pam_systemd` waits for
    /// `systemd-logind` itself.
    private func waitForSystemBus() {
        let deadline = ContinuousClock.now + configuration.systemBusTimeout
        while !configuration.system.exists(SessionPlanner.systemBusSocket) {
            guard ContinuousClock.now < deadline else {
                logger.notice("the system bus is not available; the session is not registered")
                return
            }
            usleep(20_000)
        }
    }

    /// Logs a failed conversation and tells the peer why, if it can still hear.
    private func report(_ error: ConnectionError, on connection: FrameConnection) {
        let reply: AgentError?
        switch error {
        case .versionMismatch(let local, let remote):
            logger.notice("closing a connection: \(error)")
            reply = AgentError(
                .versionMismatch,
                "the host speaks protocol version \(remote), the agent version \(local)",
                hostVersion: remote, guestVersion: local)
        case .frame, .unexpectedMessage, .timedOut:
            logger.notice("closing a connection: \(error)")
            reply = AgentError(.protocolViolation, error.description)
        case .closed, .system, .remote:
            logger.info("connection ended: \(error)")
            reply = nil
        }
        if let reply {
            connection.enqueue(.control(.error(reply)))
            try? connection.flush(until: .now + .seconds(1))
        }
    }

    /// Sends this side's version and a `busy` error without reading anything.
    private func refuse(_ descriptor: OwnedDescriptor) {
        defer { descriptor.close() }
        logger.warning("refusing a connection: \(configuration.maximumConnections) are active")
        guard let connection = try? FrameConnection(descriptor) else { return }
        connection.enqueue(.version())
        connection.enqueue(
            .control(
                .error(
                    AgentError(
                        .busy,
                        "the agent is serving \(configuration.maximumConnections) connections"))))
        try? connection.flush(until: .now + .seconds(1))
        // Read what the client sent before closing, briefly, so that the close does not
        // discard the reply on transports that reset a connection closed with unread data.
        _ = shutdown(connection.rawDescriptor, Int32(SHUT_WR))
        let deadline = ContinuousClock.now + .milliseconds(100)
        while (try? connection.receiveFrame(until: deadline)) != nil {}
    }
}
