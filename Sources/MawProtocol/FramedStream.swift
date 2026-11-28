/// A framed byte stream (docs/protocol.md, "Framed byte streams"): a connection between the
/// host and the agent that carries one byte stream in each direction as `streamData` frames,
/// ends each direction with one `streamEnd` frame, and is closed by the host first.
///
/// Virtualization.framework's vsock does not carry a guest's half-close once data is waiting
/// for the host, and discards data that the guest has sent when the guest closes after the
/// host has half-closed (docs/decisions/0023-localhost-forwarding.md, "Correction of
/// 2026-11-28"). Neither side therefore uses the connection's own half-close: the end of each
/// direction travels in the stream, and the guest never closes first.
public enum FramedStream {
    /// The frame that ends one direction.
    public static let endFrame: [UInt8] = Frame.header(type: .streamEnd, payloadSize: 0)

    /// Writes the header of a `streamData` frame of `count` bytes to `pointer`, which has room
    /// for `Frame.headerSize` bytes.
    static func writeDataHeader(count: Int, to pointer: UnsafeMutableRawPointer) {
        let header = Frame.header(type: .streamData, payloadSize: count)
        for (index, byte) in header.enumerated() {
            pointer.storeBytes(of: byte, toByteOffset: index, as: UInt8.self)
        }
    }
}

/// What makes a framed byte stream's bytes invalid. Each closes the connection with a reset.
public enum FramedStreamError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A frame of a type other than `streamData` and `streamEnd`.
    case unexpectedType(UInt8)
    /// A `streamData` frame without bytes, or with more than `AgentProtocol.streamChunkSize`.
    case dataSize(UInt32)
    /// A `streamEnd` frame with a payload.
    case endSize(UInt32)
    /// Bytes after the `streamEnd` frame.
    case bytesAfterEnd

    /// The problem with a stream frame of `type` that declares `length` bytes, if any.
    static func sizeProblem(_ type: FrameType, _ length: UInt32) -> FramedStreamError? {
        switch type {
        case .streamData:
            (1...UInt32(AgentProtocol.streamChunkSize)).contains(length) ? nil : .dataSize(length)
        case .streamEnd:
            length == 0 ? nil : .endSize(length)
        default:
            nil
        }
    }

    public var description: String {
        switch self {
        case .unexpectedType(let type):
            "a framed byte stream carries a frame of type 0x\(String(type, radix: 16))"
        case .dataSize(let size):
            "a streamData frame has \(size) bytes, not 1 to \(AgentProtocol.streamChunkSize)"
        case .endSize(let size):
            "a streamEnd frame has \(size) bytes instead of 0"
        case .bytesAfterEnd:
            "a framed byte stream carries bytes after its streamEnd frame"
        }
    }
}

/// Splits the bytes of one direction of a framed byte stream, as they arrive in pieces of any
/// size, into its data and its end, without copying the data: each `data` event names a range
/// of the bytes given to `next`.
public struct FramedStreamDecoder: Sendable {
    public enum Event: Equatable, Sendable {
        /// Payload bytes, at these offsets of the bytes given to `next`.
        case data(Range<Int>)
        /// The `streamEnd` frame.
        case end
    }

    private var header: (UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0)
    private var headerCount = 0
    private var payloadLeft = 0
    /// Whether the `streamEnd` frame has arrived.
    public private(set) var hasEnded = false

    public init() {}

    /// Whether the bytes so far end at a frame boundary.
    public var isBetweenFrames: Bool { headerCount == 0 && payloadLeft == 0 }

    /// The next event in `bytes`, starting at `offset`, which it advances past what it used;
    /// `nil` once `offset` reaches the end of `bytes` without completing an event.
    public mutating func next(_ bytes: UnsafeRawBufferPointer, from offset: inout Int)
        throws(FramedStreamError) -> Event?
    {
        while offset < bytes.count {
            if hasEnded { throw .bytesAfterEnd }
            if payloadLeft > 0 {
                let count = min(payloadLeft, bytes.count - offset)
                defer {
                    offset += count
                    payloadLeft -= count
                }
                return .data(offset..<(offset + count))
            }
            var stored = header
            var filled = headerCount
            var position = offset
            withUnsafeMutableBytes(of: &stored) { destination in
                while filled < Frame.headerSize && position < bytes.count {
                    destination[filled] = bytes[position]
                    filled += 1
                    position += 1
                }
            }
            header = stored
            offset = position
            guard filled == Frame.headerSize else {
                headerCount = filled
                return nil
            }
            headerCount = 0
            let length =
                UInt32(header.0) << 24 | UInt32(header.1) << 16 | UInt32(header.2) << 8
                | UInt32(header.3)
            guard let type = FrameType(rawValue: header.4),
                type == .streamData || type == .streamEnd
            else {
                throw .unexpectedType(header.4)
            }
            if let problem = FramedStreamError.sizeProblem(type, length) { throw problem }
            if type == .streamEnd {
                hasEnded = true
                return .end
            }
            payloadLeft = Int(length)
        }
        return nil
    }
}
