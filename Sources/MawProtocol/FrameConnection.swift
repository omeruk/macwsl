import CMawSystem

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Why a connection ended before its conversation finished.
public enum ConnectionError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The peer sent a frame that cannot be read.
    case frame(FrameError)
    /// The peer closed the connection where a frame was expected.
    case closed
    /// Nothing arrived before the deadline. The associated value names what was expected.
    case timedOut(String)
    /// A system call on the connection failed.
    case system(SystemError)
    /// A valid message arrived where a different one was expected.
    case unexpectedMessage(String)
    /// The peer speaks a different protocol version.
    case versionMismatch(local: UInt32, remote: UInt32)
    /// The peer reported an error.
    case remote(AgentError)

    public var description: String {
        switch self {
        case .frame(let error): error.description
        case .closed: "the connection was closed unexpectedly"
        case .timedOut(let what): "timed out waiting for \(what)"
        case .system(let error): error.description
        case .unexpectedMessage(let what): what
        case .versionMismatch(let local, let remote):
            "this side speaks protocol version \(local), the other side version \(remote)"
        case .remote(let error): error.message
        }
    }
}

/// Frames over a connected, non-blocking stream socket, with bounded buffers in both
/// directions.
///
/// An instance belongs to one thread at a time; ownership may pass from the thread that opens
/// it to the thread that runs the session, which is why it is `@unchecked Sendable`. Callers poll `descriptor` themselves and call
/// `receive()` when it is readable and `flush()` when it is writable. They stop polling for
/// input while `canReceive` is false and stop producing output while `pendingOutputCount` is
/// large; that is how back-pressure travels across the connection. The blocking helpers at the
/// end are for short request-reply exchanges.
public final class FrameConnection: @unchecked Sendable {
    public let descriptor: OwnedDescriptor
    public private(set) var isAtEndOfInput = false

    private var decoder = FrameDecoder()
    private var outbox = ByteBuffer()
    private var readBuffer = [UInt8](repeating: 0, count: 64 << 10)

    /// Takes ownership of a connected socket and makes it non-blocking.
    public init(_ descriptor: OwnedDescriptor) throws(ConnectionError) {
        self.descriptor = descriptor
        let error = maw_set_nonblocking(descriptor.rawValue)
        guard error == 0 else {
            throw .system(SystemError("fcntl(O_NONBLOCK)", code: error))
        }
        // Not every descriptor is a socket (tests use pipes); a failure only means that
        // `maw_send` covers SIGPIPE instead.
        _ = maw_suppress_sigpipe(descriptor.rawValue)
    }

    public var rawDescriptor: Int32 { descriptor.rawValue }

    /// Bytes queued but not yet accepted by the socket.
    public var pendingOutputCount: Int { outbox.count }

    /// Whether to poll for input: false at end-of-file, and while a whole frame is buffered.
    public var canReceive: Bool { !isAtEndOfInput && decoder.canAcceptMoreInput }

    // MARK: Output

    public func enqueue(_ frame: Frame) {
        outbox.append(contentsOf: Frame.header(type: frame.type, payloadSize: frame.payload.count))
        outbox.append(contentsOf: frame.payload)
    }

    /// Queues `bytes` as data frames of at most `AgentProtocol.maximumDataChunkSize` bytes.
    public func enqueueData(_ bytes: UnsafeRawBufferPointer, type: FrameType) {
        var offset = 0
        while offset < bytes.count {
            let size = min(AgentProtocol.maximumDataChunkSize, bytes.count - offset)
            outbox.append(contentsOf: Frame.header(type: type, payloadSize: size))
            outbox.append(contentsOf: bytes[offset..<(offset + size)])
            offset += size
        }
    }

    /// Writes as much queued output as the socket accepts. Returns whether all of it was
    /// written.
    @discardableResult
    public func flush() throws(ConnectionError) -> Bool {
        while pendingOutputCount > 0 {
            let sent = outbox.withUnsafeBytes { buffer in
                maw_send(rawDescriptor, buffer.baseAddress!, buffer.count)
            }
            if sent < 0 {
                switch errno {
                case EINTR: continue
                case EAGAIN, EWOULDBLOCK: return false
                // macOS reports ENOTCONN instead of EPIPE when the send races the peer's close.
                case EPIPE, ECONNRESET, ENOTCONN: throw .closed
                default: throw .system(SystemError("send"))
                }
            }
            outbox.consume(sent)
        }
        return true
    }

    // MARK: Input

    /// Reads what the socket has, once. Sets `isAtEndOfInput` at end-of-file.
    public func receive() throws(ConnectionError) {
        let count = readBuffer.withUnsafeMutableBytes { bytes in
            retryingOnInterrupt { read(rawDescriptor, bytes.baseAddress, bytes.count) }
        }
        if count > 0 {
            decoder.append(readBuffer[..<count])
        } else if count == 0 || errno == ECONNRESET {
            isAtEndOfInput = true
        } else if errno != EAGAIN && errno != EWOULDBLOCK {
            throw .system(SystemError("read"))
        }
    }

    /// The next complete frame, or `nil` if none is buffered. At end-of-file, throws if a
    /// partial frame is left over.
    public func nextFrame() throws(ConnectionError) -> Frame? {
        do throws(FrameError) {
            if let frame = try decoder.nextFrame() {
                return frame
            }
            if isAtEndOfInput {
                try decoder.finish()
            }
            return nil
        } catch {
            throw .frame(error)
        }
    }

    // MARK: Blocking exchanges

    /// Writes all queued output, waiting for the socket as needed.
    ///
    /// If the peer has stopped reading, the output is discarded without an error: the peer
    /// may have closed the connection after saying why (the agent's `busy` reply does this),
    /// and the next read returns that reply, or reports the end of the connection.
    public func flush(until deadline: ContinuousClock.Instant?) throws(ConnectionError) {
        do {
            while try !flush() {
                try wait(for: POLLOUT, until: deadline, expecting: "the connection to accept data")
            }
        } catch .closed {
            discardPendingOutput()
        }
    }

    /// Drops queued output, for a peer that has stopped reading.
    public func discardPendingOutput() {
        outbox.removeAll()
    }

    /// Waits for the next frame. Throws `closed` at end-of-file.
    public func receiveFrame(
        until deadline: ContinuousClock.Instant?, expecting what: String = "a frame"
    ) throws(ConnectionError) -> Frame {
        while true {
            if let frame = try nextFrame() {
                return frame
            }
            if isAtEndOfInput {
                throw .closed
            }
            try wait(for: POLLIN, until: deadline, expecting: what)
            try receive()
        }
    }

    /// Waits for the next control message.
    public func receiveControl(
        until deadline: ContinuousClock.Instant?, expecting what: String
    ) throws(ConnectionError) -> ControlMessage {
        let frame = try receiveFrame(until: deadline, expecting: what)
        do throws(FrameError) {
            return try frame.controlMessage()
        } catch {
            throw .frame(error)
        }
    }

    /// Sends this side's protocol version, followed by `frames`, and returns the peer's. Both
    /// sides send first, so neither waits for the other. The host sends its request in
    /// `frames`, so that the request does not wait for the agent's version (docs/protocol.md).
    public func exchangeVersions(
        until deadline: ContinuousClock.Instant?, thenSending frames: [Frame] = []
    ) throws(ConnectionError) -> UInt32 {
        enqueue(.version())
        for frame in frames {
            enqueue(frame)
        }
        try flush(until: deadline)
        let frame = try receiveFrame(until: deadline, expecting: "the protocol version")
        do throws(FrameError) {
            return try frame.protocolVersion()
        } catch {
            throw .frame(error)
        }
    }

    private func wait(
        for events: Int32, until deadline: ContinuousClock.Instant?, expecting what: String
    ) throws(ConnectionError) {
        var request = [pollRequest(rawDescriptor, events)]
        let ready: Int32
        do {
            ready = try pollDescriptors(&request, timeout: pollTimeout(until: deadline))
        } catch {
            throw .system(error)
        }
        if ready == 0 {
            throw .timedOut(what)
        }
    }
}
