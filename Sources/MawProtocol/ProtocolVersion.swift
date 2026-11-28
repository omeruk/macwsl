/// The host <-> guest wire protocol, specified in docs/protocol.md.
///
/// Both sides send their version first on every connection and close the connection if the
/// versions differ, so that a host and a guest agent from different builds never misread each
/// other. Any change to the messages in `ControlMessage`, or to the frames or what a connection
/// carries after them, increments the version.
public enum ProtocolVersion {
    public static let current: UInt32 = 10
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
    /// The largest payload of a `streamData` frame, and the most bytes that each direction of
    /// a framed byte stream's relay reads at a time (docs/protocol.md, "Framed byte streams").
    public static let streamChunkSize = 128 << 10
    /// How long the agent waits for the host to close a framed byte stream once both of its
    /// directions have ended and its own `streamEnd` frame is written, counting only time in
    /// which its send queue (`SIOCOUTQ`) did not shrink. A reader on the Mac that is slow
    /// while that queue holds data is never cut off. The queue empties while up to about
    /// 0.5 MiB can still wait on the Mac's side, which it does not see: a reader that does not
    /// take that rest within this long after the queue empties finds the connection closed by
    /// the agent first, however steadily it reads. A host that never closes the connection
    /// costs the guest nothing after this long.
    public static let streamCloseWaitLimit = Duration.seconds(120)
    /// The most listeners one `listeners` message may carry.
    public static let maximumListeners = 1_024
    /// How often the agent lists the guest's listeners while the forwarding channel is open.
    public static let listenerScanInterval = Duration.milliseconds(250)
    /// The guest address on which the agent answers DNS queries, on port 53 over UDP and TCP
    /// (docs/decisions/0024-dns-through-the-mac.md). A link-local address that the agent adds
    /// to the dummy link `dnsLink`: containers in the guest can reach it, unlike 127.0.0.0/8,
    /// and systemd-resolved uses its servers while that link is up, before DHCP has finished.
    public static let dnsAddress: [UInt8] = [169, 254, 77, 53]
    public static let dnsAddressText = "169.254.77.53"
    /// The guest's dummy link that holds `dnsAddress`.
    public static let dnsLink = "maw-dns"
    public static let dnsPort: UInt16 = 53
    /// The largest payload of a `dnsQuery` or `dnsAnswer` frame: a 4-byte tag and a message of
    /// at most 65,535 bytes.
    public static let maximumDNSFramePayload = 4 + 65_535
    /// The guest's queries that the agent has passed to the host and not yet had answered.
    /// Beyond them, a query is answered REFUSED.
    public static let maximumDNSQueriesInFlight = 128
}
