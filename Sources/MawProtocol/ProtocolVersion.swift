/// The host <-> guest wire protocol, specified in docs/protocol.md.
///
/// Both sides send their version first on every connection and close the connection if the
/// versions differ, so that a host and a guest agent from different builds never misread each
/// other. Any change to the messages in `ControlMessage` increments the version.
public enum ProtocolVersion {
    public static let current: UInt32 = 8
}

/// Constants of the wire protocol.
public enum AgentProtocol {
    /// The vsock port the guest agent listens on. 0x4D57 is "MW" in ASCII.
    public static let vsockPort: UInt32 = 0x4D57
    /// The largest frame payload either side accepts. A frame that declares a larger payload
    /// closes the connection before any of it is read.
    public static let maximumPayloadSize = 1 << 20
    /// The largest payload either side puts in one stdin, stdout, or stderr frame.
    public static let maximumDataChunkSize = 32 << 10
    /// The standard input, in bytes of `stdin` payload, that the host may have sent and the
    /// agent not yet reported with `stdinConsumed`. It bounds the agent's backlog, so that the
    /// agent can always read the connection and act on `signal` and `resize` at once.
    public static let inputWindow = 1 << 20
    /// The host's vsock port that the agent dials in reply to `dialBack`. 0x4D58 is "MX".
    public static let dialBackPort: UInt32 = 0x4D58
    /// The size of a `DialBackNonce` and of a `dialBackNonce` frame's payload.
    public static let dialBackNonceSize = 32
    /// The connections the agent serves at once. The host keeps at most this many `dialBack`
    /// requests pending per machine.
    public static let maximumConnections = 64
    /// The host's vsock port that the agent dials for each forwarded connection, in reply to
    /// `connect` on the forwarding channel (docs/protocol.md, "Forwarding"). 0x4D59 is "MY".
    public static let forwardingPort: UInt32 = 0x4D59
    /// The forwarded connections the agent keeps open at once. A `connect` beyond them fails
    /// with `connectFailed`.
    public static let maximumForwardedConnections = 256
    /// The most listeners one `listeners` message may carry.
    public static let maximumListeners = 1_024
    /// How often the agent lists the guest's listeners while the forwarding channel is open.
    public static let listenerScanInterval = Duration.milliseconds(250)
}
