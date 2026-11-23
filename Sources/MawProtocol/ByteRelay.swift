import CMawSystem
import MawCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Copies a forwarded connection's bytes in both directions between two connected stream
/// sockets, on two threads of its own, until both directions have ended; then closes both
/// and reports the end (docs/decisions/0023-localhost-forwarding.md). The daemon relays a
/// Mac's TCP connection to the agent's vsock connection, and the agent that connection to the
/// guest's listener.
///
/// - The end of one side's stream becomes `shutdown(SHUT_WR)` on the other, so that a
///   half-close is carried.
/// - A failed read or write, or `abort()`, ends both directions, and both sockets are closed
///   with a reset, so that each peer sees the connection fail rather than end.
/// - Each direction holds at most `bufferSize` bytes: it reads only once the previous read is
///   written, so a slow reader holds the writer back through the sockets' flow control.
public final class ByteRelay: @unchecked Sendable {
    /// The bytes each direction reads and writes at a time.
    public static let defaultBufferSize = 128 << 10

    private let lock = ConditionLock()
    private let first: OwnedDescriptor
    private let second: OwnedDescriptor
    private let bufferSize: Int
    private let finished: @Sendable (_ aborted: Bool) -> Void
    private var running = 2
    private var aborted = false

    private init(
        _ first: OwnedDescriptor, _ second: OwnedDescriptor, bufferSize: Int,
        finished: @escaping @Sendable (Bool) -> Void
    ) {
        self.first = first
        self.second = second
        self.bufferSize = bufferSize
        self.finished = finished
    }

    /// Starts relaying between `first` and `second`, which it then owns, and makes them
    /// blocking. Returns `nil`, with both closed and without calling `finished`, if its
    /// threads cannot start. `finished` runs once, after both are closed, with whether the
    /// relay ended by an error or `abort()`.
    public static func start(
        _ first: OwnedDescriptor, _ second: OwnedDescriptor,
        bufferSize: Int = defaultBufferSize,
        finished: @escaping @Sendable (_ aborted: Bool) -> Void
    ) -> ByteRelay? {
        for descriptor in [first, second] {
            _ = maw_set_blocking(descriptor.rawValue)
            _ = maw_suppress_sigpipe(descriptor.rawValue)
        }
        let relay = ByteRelay(first, second, bufferSize: bufferSize, finished: finished)
        guard startDetachedThread({ relay.copy(from: first, to: second) }) else {
            first.close()
            second.close()
            return nil
        }
        guard startDetachedThread({ relay.copy(from: second, to: first) }) else {
            // The first thread is running; ending both directions makes it return, and this
            // direction counts as ended.
            relay.abort()
            relay.directionEnded()
            return relay
        }
        return relay
    }

    /// Ends both directions at once and resets both connections.
    public func abort() {
        lock.withLock { aborted = true }
        for descriptor in [first, second] {
            _ = shutdown(descriptor.rawValue, Int32(SHUT_RDWR))
        }
    }

    private func copy(from source: OwnedDescriptor, to destination: OwnedDescriptor) {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        copying: while true {
            let count = retryingOnInterrupt { read(source.rawValue, buffer, bufferSize) }
            if count == 0 {
                _ = shutdown(destination.rawValue, Int32(SHUT_WR))
                break
            }
            guard count > 0 else {
                abort()
                break
            }
            var offset = 0
            while offset < count {
                let written = maw_send(destination.rawValue, buffer + offset, count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else {
                    abort()
                    break copying
                }
                offset += written
            }
        }
        directionEnded()
    }

    /// Counts one direction as ended; after the second, closes both sockets and reports.
    private func directionEnded() {
        let (last, wasAborted) = lock.withLock {
            running -= 1
            return (running == 0, aborted)
        }
        guard last else { return }
        if wasAborted {
            _ = maw_set_reset_on_close(first.rawValue)
            _ = maw_set_reset_on_close(second.rawValue)
        }
        first.close()
        second.close()
        finished(wasAborted)
    }
}
