/// The host <-> guest wire protocol, specified in docs/protocol.md.
///
/// Both sides send their version first on every connection and close the connection if the
/// versions differ, so that a host and a guest agent from different builds never misread each
/// other. Any change to the messages in `ControlMessage` increments the version.
public enum ProtocolVersion {
    public static let current: UInt32 = 1
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
}
