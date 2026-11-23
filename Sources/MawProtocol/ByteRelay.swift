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
/// - Neither direction blocks in `read(2)` or `write(2)`. Both sockets are nonblocking, and a
///   direction that must wait does so in `poll(2)` for at most `pollIntervalMilliseconds`,
///   then tries again. On macOS, a thread blocked in `read(2)` on a socket that another
///   thread writes to can miss the wakeup for the peer's end of stream, and stays blocked
///   although the socket polls as readable; the bound turns such a miss into a delay of at
///   most one interval.
public final class ByteRelay: @unchecked Sendable {
    /// The bytes each direction reads and writes at a time.
    public static let defaultBufferSize = 128 << 10
    /// The longest a direction waits in `poll(2)` before it reads or writes again.
    static let pollIntervalMilliseconds: Int32 = 1_000

    private let lock = ConditionLock()
    private let first: OwnedDescriptor
    private let second: OwnedDescriptor
    private let bufferSize: Int
    private let finished: @Sendable (_ aborted: Bool) -> Void
    private var running = 2
    private var aborted = false
    /// Set, under `lock`, before both descriptors are closed: `abort()` must not shut down a
    /// number that may already belong to another socket.
    private var closing = false

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
    /// nonblocking. Returns `nil`, with both closed and without calling `finished`, if its
    /// threads cannot start. `finished` runs once, after both are closed, with whether the
    /// relay ended by an error or `abort()`.
    public static func start(
        _ first: OwnedDescriptor, _ second: OwnedDescriptor,
        bufferSize: Int = defaultBufferSize,
        finished: @escaping @Sendable (_ aborted: Bool) -> Void
    ) -> ByteRelay? {
        for descriptor in [first, second] {
            _ = maw_set_nonblocking(descriptor.rawValue)
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
        lock.withLock {
            aborted = true
            guard !closing else { return }
            for descriptor in [first, second] {
                _ = shutdown(descriptor.rawValue, Int32(SHUT_RDWR))
            }
        }
    }

    private func copy(from source: OwnedDescriptor, to destination: OwnedDescriptor) {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        copying: while true {
            let count = read(source.rawValue, buffer, bufferSize)
            if count == 0 {
                _ = shutdown(destination.rawValue, Int32(SHUT_WR))
                break
            }
            if count < 0 {
                if Self.mustWait(errno) {
                    Self.wait(for: source, Int32(POLLIN))
                    continue
                }
                abort()
                break
            }
            var offset = 0
            while offset < count {
                let written = maw_send(destination.rawValue, buffer + offset, count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && Self.mustWait(errno) {
                    Self.wait(for: destination, Int32(POLLOUT))
                } else {
                    abort()
                    break copying
                }
            }
        }
        directionEnded()
    }

    /// Whether a nonblocking read or write that failed with `code` is to be tried again.
    private static func mustWait(_ code: Int32) -> Bool {
        code == EAGAIN || code == EWOULDBLOCK || code == EINTR
    }

    /// Waits until `descriptor` reports `events`, an error, or its end, or until the interval
    /// has passed. The caller tries again in every case, so a missed wakeup costs at most the
    /// interval.
    private static func wait(for descriptor: OwnedDescriptor, _ events: Int32) {
        var request = pollfd(fd: descriptor.rawValue, events: Int16(events), revents: 0)
        _ = poll(&request, 1, pollIntervalMilliseconds)
    }

    /// Counts one direction as ended; after the second, closes both sockets and reports.
    private func directionEnded() {
        let (last, wasAborted) = lock.withLock {
            running -= 1
            closing = running == 0
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
