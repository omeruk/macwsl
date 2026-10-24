import MawCore

/// Talks to the guest agent over connections that `connect` opens, one per request, as
/// docs/protocol.md describes.
///
/// The client does not care what transport the descriptors use. `VirtualMachine` connects over
/// vsock; the unit tests connect to the agent's session code through a `socketpair`.
public struct GuestAgentClient: Sendable {
    public typealias Connector = @Sendable () async throws(MawError) -> OwnedDescriptor

    /// Which stream a piece of output came from.
    public enum OutputStream: Sendable, Equatable {
        case stdout
        case stderr
    }

    /// Receives a process's output, in order, on a thread of the client's own. It may block;
    /// once `GuestProcess.outputLimit` bytes wait for it, the client stops reading the
    /// process's output from the guest, which applies back-pressure to the process. Signals and
    /// resizes still reach the guest while it blocks.
    public typealias OutputHandler = @Sendable (OutputStream, UnsafeRawBufferPointer) -> Void

    private let connect: Connector
    private let replyTimeout: Duration
    private let guestName: String

    /// - Parameters:
    ///   - replyTimeout: How long to wait for the handshake and for each reply to a request.
    ///   - guestName: What errors call the guest, such as the distribution's name.
    ///   - connect: Opens a new connection to the agent.
    public init(
        replyTimeout: Duration = .seconds(10), guestName: String = "the guest",
        connect: @escaping Connector
    ) {
        self.connect = connect
        self.replyTimeout = replyTimeout
        self.guestName = guestName
    }

    /// Asks the agent for its version, the kernel release, and the uptime.
    public func info() async throws(MawError) -> AgentInfo {
        let descriptor = try await connect()
        let timeout = replyTimeout
        return try await runOnDedicatedThread { () throws(MawError) -> AgentInfo in
            try Self.mapErrors(during: "info") { () throws(ConnectionError) -> AgentInfo in
                let connection = try Self.open(descriptor, timeout: timeout)
                connection.enqueue(.control(.info))
                switch try Self.reply(on: connection, timeout: timeout, to: "info") {
                case .agentInfo(let info):
                    return info
                case let other:
                    throw .unexpectedMessage("expected agentInfo, received \(other.name)")
                }
            }
        }
    }

    /// Asks the guest to power off. Returns once the agent has acknowledged; the virtual
    /// machine stops shortly after.
    public func shutdown() async throws(MawError) {
        let descriptor = try await connect()
        let timeout = replyTimeout
        try await runOnDedicatedThread { () throws(MawError) in
            try Self.mapErrors(during: "shutdown") { () throws(ConnectionError) in
                let connection = try Self.open(descriptor, timeout: timeout)
                connection.enqueue(.control(.shutdown))
                switch try Self.reply(on: connection, timeout: timeout, to: "shutdown") {
                case .shutdownAcknowledged:
                    return
                case let other:
                    throw .unexpectedMessage(
                        "expected shutdownAcknowledged, received \(other.name)")
                }
            }
        }
    }

    /// Asks the agent to open a connection to the host's dial-back port that starts with
    /// `nonce`. Returns once the agent reports that it connected; the host's listener receives
    /// the connection.
    public func dialBack(_ nonce: DialBackNonce) async throws(MawError) {
        let descriptor = try await connect()
        let timeout = replyTimeout
        try await runOnDedicatedThread { () throws(MawError) in
            try Self.mapErrors(during: "dialBack") { () throws(ConnectionError) in
                let connection = try Self.open(descriptor, timeout: timeout)
                connection.enqueue(.control(.dialBack(nonce)))
                switch try Self.reply(on: connection, timeout: timeout, to: "dialBack") {
                case .dialedBack:
                    return
                case let other:
                    throw .unexpectedMessage("expected dialedBack, received \(other.name)")
                }
            }
        }
    }

    /// Starts a command. Returns once the agent reports it started.
    public func exec(
        _ request: ExecRequest, output: @escaping OutputHandler
    ) async throws(MawError) -> GuestProcess {
        let descriptor = try await connect()
        let timeout = replyTimeout
        let command: String
        switch request.program {
        case .argv(let argv): command = argv.first ?? ""
        case .shellCommand, .loginShell: command = request.program.description
        }
        let guestName = self.guestName
        return try await runOnDedicatedThread { () throws(MawError) -> GuestProcess in
            let (connection, pid) = try Self.mapErrors(
                during: "exec", command: command, guestName: guestName
            ) {
                () throws(ConnectionError) -> (FrameConnection, Int32) in
                let connection = try Self.open(descriptor, timeout: timeout)
                connection.enqueue(.control(.exec(request)))
                switch try Self.reply(on: connection, timeout: timeout, to: "exec") {
                case .started(let pid):
                    return (connection, pid)
                case let other:
                    throw .unexpectedMessage("expected started, received \(other.name)")
                }
            }
            return try GuestProcess(connection: connection, pid: pid, output: output)
        }
    }

    // MARK: Conversation steps

    /// Wraps a descriptor and exchanges protocol versions.
    static func open(_ descriptor: OwnedDescriptor, timeout: Duration) throws(ConnectionError)
        -> FrameConnection
    {
        let connection = try FrameConnection(descriptor)
        let deadline = ContinuousClock.now + timeout
        let remote = try connection.exchangeVersions(until: deadline)
        guard remote == ProtocolVersion.current else {
            throw .versionMismatch(local: ProtocolVersion.current, remote: remote)
        }
        return connection
    }

    /// Sends what is queued and waits for one control message in reply. An `error` reply is
    /// thrown.
    static func reply(on connection: FrameConnection, timeout: Duration, to request: String)
        throws(ConnectionError) -> ControlMessage
    {
        let deadline = ContinuousClock.now + timeout
        try connection.flush(until: deadline)
        let message = try connection.receiveControl(
            until: deadline, expecting: "the reply to \(request)")
        if case .error(let error) = message {
            throw .remote(error)
        }
        return message
    }

    /// Runs one conversation and turns its errors into `MawError`s.
    static func mapErrors<Result>(
        during request: String, command: String = "", guestName: String = "the guest",
        _ body: () throws(ConnectionError) -> Result
    ) throws(MawError) -> Result {
        do {
            return try body()
        } catch {
            throw map(error, during: request, command: command, guestName: guestName)
        }
    }

    static func map(
        _ error: ConnectionError, during request: String, command: String = "",
        guestName: String = "the guest"
    ) -> MawError {
        switch error {
        case .versionMismatch(let local, let remote):
            return .guestAgentVersionMismatch(host: local, guest: remote)
        case .remote(let agentError):
            switch agentError.code {
            case .versionMismatch:
                return .guestAgentVersionMismatch(
                    host: agentError.hostVersion ?? ProtocolVersion.current,
                    guest: agentError.guestVersion ?? 0)
            case .commandNotFound:
                return .guestCommandNotFound(command: command, reason: agentError.message)
            case .permissionDenied, .spawnFailed:
                return .guestCommandNotStarted(command: command, reason: agentError.message)
            case .userNotFound:
                return .userNotFound(agentError.user ?? "", distribution: guestName)
            case .dialBackFailed:
                return .sessionDialBackFailed(reason: agentError.message)
            case .protocolViolation, .shutdownFailed, .busy:
                return .guestAgentFailed(reason: "\(request): \(agentError.message)")
            }
        case .timedOut(let what):
            return .guestAgentUnavailable(reason: "\(request): timed out waiting for \(what)")
        case .frame, .closed, .system, .unexpectedMessage:
            return .guestAgentFailed(reason: "\(request): \(error)")
        }
    }
}
