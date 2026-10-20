/// The host <-> guest wire protocol.
///
/// The message format is defined in phase 04. Until then this module only records the protocol
/// version, so that the host and guest can refuse to talk across incompatible versions.
public enum ProtocolVersion {
    public static let current: UInt32 = 1
}
