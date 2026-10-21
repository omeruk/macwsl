/// The kind of a frame, carried in the byte after the length.
public enum FrameType: UInt8, Sendable, CaseIterable {
    /// The sender's protocol version: 4 bytes, big-endian. Each side sends it first. Its layout
    /// never changes, so that any two versions can detect a mismatch.
    case version = 0x01
    /// A `ControlMessage`, JSON-encoded.
    case control = 0x02
    /// Raw bytes for the process's standard input (host to guest).
    case stdin = 0x10
    /// Raw bytes from the process's standard output, or from its terminal (guest to host).
    case stdout = 0x11
    /// Raw bytes from the process's standard error (guest to host).
    case stderr = 0x12
}

/// One frame: a 4-byte big-endian payload length, the 1-byte type, then the payload.
public struct Frame: Equatable, Sendable {
    /// The bytes before the payload.
    public static let headerSize = 5

    public var type: FrameType
    public var payload: [UInt8]

    public init(type: FrameType, payload: [UInt8] = []) {
        self.type = type
        self.payload = payload
    }

    /// The frame as it is written to the connection.
    public var encoded: [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.headerSize + payload.count)
        Self.appendHeader(type: type, payloadSize: payload.count, to: &bytes)
        bytes.append(contentsOf: payload)
        return bytes
    }

    static func appendHeader(type: FrameType, payloadSize: Int, to bytes: inout [UInt8]) {
        let length = UInt32(payloadSize)
        bytes.append(UInt8(truncatingIfNeeded: length >> 24))
        bytes.append(UInt8(truncatingIfNeeded: length >> 16))
        bytes.append(UInt8(truncatingIfNeeded: length >> 8))
        bytes.append(UInt8(truncatingIfNeeded: length))
        bytes.append(type.rawValue)
    }

    // MARK: Version frames

    public static func version(_ version: UInt32 = ProtocolVersion.current) -> Frame {
        Frame(
            type: .version,
            payload: [
                UInt8(truncatingIfNeeded: version >> 24), UInt8(truncatingIfNeeded: version >> 16),
                UInt8(truncatingIfNeeded: version >> 8), UInt8(truncatingIfNeeded: version),
            ])
    }

    /// The version a version frame carries.
    public func protocolVersion() throws(FrameError) -> UInt32 {
        guard type == .version else {
            throw .unexpectedType(type.rawValue, expected: "version")
        }
        guard payload.count == 4 else {
            throw .malformedVersion(size: payload.count)
        }
        return payload.reduce(0) { $0 << 8 | UInt32($1) }
    }

    // MARK: Control frames

    public static func control(_ message: ControlMessage) -> Frame {
        Frame(type: .control, payload: message.encodedJSON())
    }

    /// The message a control frame carries.
    public func controlMessage() throws(FrameError) -> ControlMessage {
        guard type == .control else {
            throw .unexpectedType(type.rawValue, expected: "control")
        }
        return try ControlMessage(json: payload)
    }
}

/// A frame that cannot be read. Each closes the connection it arrived on, and only that one.
public enum FrameError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The declared payload is larger than `AgentProtocol.maximumPayloadSize`.
    case oversized(UInt32)
    /// The type byte is not a `FrameType`.
    case unknownType(UInt8)
    /// The connection ended in the middle of a frame.
    case truncated(buffered: Int)
    /// A version frame whose payload is not 4 bytes.
    case malformedVersion(size: Int)
    /// A control frame whose payload is not a valid `ControlMessage`.
    case malformedControl(String)
    /// A frame of a known type that is not valid at this point of the conversation.
    case unexpectedType(UInt8, expected: String)

    public var description: String {
        switch self {
        case .oversized(let size):
            "a frame declares \(size) bytes, more than the maximum of "
                + "\(AgentProtocol.maximumPayloadSize)"
        case .unknownType(let type):
            "unknown frame type 0x\(String(type, radix: 16))"
        case .truncated(let buffered):
            "the connection ended in the middle of a frame (\(buffered) bytes buffered)"
        case .malformedVersion(let size):
            "a version frame has \(size) bytes instead of 4"
        case .malformedControl(let reason):
            "a control message could not be decoded: \(reason)"
        case .unexpectedType(let type, let expected):
            "expected a \(expected) frame, but received one of type 0x\(String(type, radix: 16))"
        }
    }
}

/// Splits a byte stream into frames. Bytes may arrive in pieces of any size.
///
/// The buffer never holds more than one maximal frame plus one read's worth of bytes, because
/// the header is validated as soon as it is complete, and callers stop reading while a whole
/// frame is buffered (`canAcceptMoreInput`).
public struct FrameDecoder: Sendable {
    private var buffer: [UInt8] = []
    private var start = 0

    public init() {}

    /// Bytes received but not yet returned as frames.
    public var bufferedByteCount: Int { buffer.count - start }

    /// Whether to read more from the connection. False while a complete frame waits to be
    /// taken, which bounds the buffer.
    public var canAcceptMoreInput: Bool {
        bufferedByteCount < Frame.headerSize + AgentProtocol.maximumPayloadSize
    }

    public mutating func append(_ bytes: some Collection<UInt8>) {
        if start > 0 && start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        }
        buffer.append(contentsOf: bytes)
    }

    /// The next complete frame, or `nil` if more bytes are needed.
    public mutating func nextFrame() throws(FrameError) -> Frame? {
        guard bufferedByteCount >= Frame.headerSize else { return nil }
        let length =
            UInt32(buffer[start]) << 24 | UInt32(buffer[start + 1]) << 16
            | UInt32(buffer[start + 2]) << 8 | UInt32(buffer[start + 3])
        guard length <= AgentProtocol.maximumPayloadSize else {
            throw .oversized(length)
        }
        guard let type = FrameType(rawValue: buffer[start + 4]) else {
            throw .unknownType(buffer[start + 4])
        }
        let end = start + Frame.headerSize + Int(length)
        guard buffer.count >= end else { return nil }
        let frame = Frame(type: type, payload: Array(buffer[(start + Frame.headerSize)..<end]))
        start = end
        // Compact once the consumed prefix dominates, so that the buffer does not keep growing.
        if start > 64 << 10 && start * 2 > buffer.count {
            buffer.removeFirst(start)
            start = 0
        }
        return frame
    }

    /// Called at end-of-file. Throws if a partial frame is left over.
    public func finish() throws(FrameError) {
        if bufferedByteCount > 0 {
            throw .truncated(buffered: bufferedByteCount)
        }
    }
}
