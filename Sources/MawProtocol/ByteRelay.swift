import CMawSystem
import MawCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Relays a plain stream socket and a framed byte stream (`FramedStream`) to each other, on
/// two threads of its own, until both directions have ended; then closes both and reports the
/// end. The daemon relays a Mac's TCP connection to the agent's vsock connection, and the agent
/// that connection to the guest's listener (docs/decisions/0023-localhost-forwarding.md).
///
/// - Bytes read from the plain socket go out as `streamData` frames, and its end as the
///   `streamEnd` frame. The data of `streamData` frames goes to the plain socket, and the
///   `streamEnd` frame becomes `shutdown(SHUT_WR)` on it, so that a half-close is carried.
/// - The stream's connection itself is never half-closed, and the host closes it first: the
///   `host` role closes as soon as it has sent its end and received the guest's. The `guest`
///   role then waits for that close, for at most `closeWaitLimit` without progress, so that
///   nothing the guest sent is lost (see `FramedStream`).
/// - A failed read or write, invalid stream bytes, the stream's connection ending before its
///   `streamEnd` frame, or `abort()` ends both directions, and both sockets are closed with a
///   reset, so that each peer sees the connection fail rather than end.
/// - Each direction holds at most `bufferSize` bytes: it reads only once the previous read is
///   written, so a slow reader holds the writer back through the sockets' flow control.
/// - Neither direction blocks in `read(2)` or `write(2)`. Both sockets are nonblocking, and a
///   direction that must wait does so in `poll(2)` for at most `pollIntervalMilliseconds`,
///   then tries again. On macOS, a thread blocked in `read(2)` on a socket that another
///   thread writes to can miss the wakeup for the peer's end of stream, and stays blocked
///   although the socket polls as readable; the bound turns such a miss into a delay of at
///   most one interval.
public final class ByteRelay: @unchecked Sendable {
    /// Which side of the framed byte stream the relay is.
    public enum Role: Sendable, Equatable {
        /// Closes the stream's connection once both directions have ended.
        case host
        /// Waits for the host to close the stream's connection once both directions have
        /// ended, and closes it itself after `closeWaitLimit` without progress: without its
        /// send queue on that connection shrinking.
        case guest(closeWaitLimit: Duration)
    }

    /// How the relay ended.
    public enum Ending: Sendable, Equatable {
        /// Both directions ended, and the host closed the stream's connection, or this relay
        /// as the host closed it.
        case completed
        /// An error, invalid stream bytes, an early end of the stream's connection, or
        /// `abort()` reset both connections.
        case aborted
        /// The guest waited `closeWaitLimit` without progress for the host's close, and closed
        /// the connection itself. `sendQueueVisible` is false when its send queue could never
        /// be read (`SIOCOUTQ`), so that only time counted.
        case closedWithoutAcknowledgement(sendQueueVisible: Bool)
    }

    /// The bytes each direction reads and writes at a time, and the most it accepts.
    public static let defaultBufferSize = AgentProtocol.streamChunkSize
    /// The longest a direction waits in `poll(2)` before it reads or writes again.
    static let pollIntervalMilliseconds: Int32 = 1_000

    private let lock = ConditionLock()
    private let plain: OwnedDescriptor
    private let stream: OwnedDescriptor
    private let role: Role
    private let bufferSize: Int
    private let finished: @Sendable (Ending) -> Void
    private var running = 2
    private var aborted = false
    private var unacknowledged: Ending?
    /// Set, under `lock`, once the plain socket's end is read, before the `streamEnd` frame is
    /// written: from then on, the host may close the connection at any moment.
    private var sendingEnd = false
    /// Set, under `lock`, once the `streamEnd` frame is written in full: the guest's wait for
    /// the host's close starts only then, so that a write that the host holds back is never
    /// taken for a host that does not close.
    private var endWritten = false
    /// Set, under `lock`, before both descriptors are closed: `abort()` must not shut down a
    /// number that may already belong to another socket.
    private var closing = false

    private init(
        plain: OwnedDescriptor, stream: OwnedDescriptor, role: Role, bufferSize: Int,
        finished: @escaping @Sendable (Ending) -> Void
    ) {
        self.plain = plain
        self.stream = stream
        self.role = role
        self.bufferSize = bufferSize
        self.finished = finished
    }

    /// Starts relaying between `plain` and `stream`, which it then owns, and makes them
    /// nonblocking. Returns `nil`, with both closed and without calling `finished`, if its
    /// threads cannot start. `finished` runs once, after both are closed, with how the relay
    /// ended. `bufferSize` is at most `AgentProtocol.streamChunkSize`.
    public static func start(
        plain: OwnedDescriptor, stream: OwnedDescriptor, role: Role,
        bufferSize: Int = defaultBufferSize,
        finished: @escaping @Sendable (Ending) -> Void
    ) -> ByteRelay? {
        for descriptor in [plain, stream] {
            _ = maw_set_nonblocking(descriptor.rawValue)
            _ = maw_suppress_sigpipe(descriptor.rawValue)
        }
        let relay = ByteRelay(
            plain: plain, stream: stream, role: role,
            bufferSize: min(max(bufferSize, 1), AgentProtocol.streamChunkSize),
            finished: finished)
        guard startDetachedThread({ relay.sendToStream() }) else {
            plain.close()
            stream.close()
            return nil
        }
        guard startDetachedThread({ relay.receiveFromStream() }) else {
            // The first thread is running; ending both directions makes it return, and this
            // direction counts as ended.
            relay.abort()
            relay.directionEnded()
            return relay
        }
        return relay
    }

    /// Ends both directions at once and resets both connections.
    ///
    /// Reading ends at once on both sockets. The plain socket's sending side is not shut down:
    /// that would send its peer a clean end of stream before the reset of the close, and a
    /// Mac client would read that end first. Both directions see `aborted` instead and stop
    /// writing within one poll interval.
    public func abort() {
        lock.withLock {
            aborted = true
            guard !closing else { return }
            _ = maw_set_reset_on_close(plain.rawValue)
            _ = shutdown(plain.rawValue, Int32(SHUT_RD))
            _ = shutdown(stream.rawValue, Int32(SHUT_RDWR))
        }
    }

    private var isAborted: Bool { lock.withLock { aborted } }

    // MARK: Plain to stream

    /// Frames what the plain socket sends, then its end.
    private func sendToStream() {
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Frame.headerSize + bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = read(plain.rawValue, buffer + Frame.headerSize, bufferSize)
            if count > 0 {
                FramedStream.writeDataHeader(count: count, to: buffer)
                guard sendAll(buffer, Frame.headerSize + count, to: stream) else {
                    abort()
                    break
                }
            } else if count == 0 {
                // After `abort()`, the plain socket reads as ended; that end is not its peer's.
                if isAborted { break }
                lock.withLock { sendingEnd = true }
                let sent = FramedStream.endFrame.withUnsafeBytes {
                    sendAll($0.baseAddress!, $0.count, to: stream)
                }
                if sent {
                    lock.withLock { endWritten = true }
                } else {
                    abort()
                }
                break
            } else if Self.mustWait(errno) {
                Self.wait(for: plain, Int32(POLLIN))
            } else {
                abort()
                break
            }
        }
        directionEnded()
    }

    // MARK: Stream to plain

    /// Writes the stream's data to the plain socket, and its end as `shutdown(SHUT_WR)`. As
    /// the guest, then waits for the host to close the connection.
    private func receiveFromStream() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var decoder = FramedStreamDecoder()
        var closeWait: CloseWait?
        receiving: while true {
            let count = read(stream.rawValue, buffer, bufferSize)
            if count > 0 {
                var offset = 0
                // The host stops reading at the guest's end, but first decodes the rest of the
                // read that carried it, so that a byte after the end resets both connections.
                var hostReachedEnd = false
                do {
                    while let event = try decoder.next(
                        UnsafeRawBufferPointer(start: buffer, count: count), from: &offset)
                    {
                        switch event {
                        case .data(let range):
                            guard sendAll(buffer + range.lowerBound, range.count, to: plain)
                            else {
                                abort()
                                break receiving
                            }
                        case .end:
                            _ = shutdown(plain.rawValue, Int32(SHUT_WR))
                            if case .guest(let limit) = role {
                                closeWait = CloseWait(limit: limit)
                            } else {
                                hostReachedEnd = true
                            }
                        }
                    }
                } catch {
                    abort()
                    break
                }
                if hostReachedEnd { break }
            } else if count < 0 && Self.mustWait(errno) {
                if var wait = closeWait {
                    let expired = wait.waitForClose(of: stream, endWritten: hasWrittenEnd)
                    closeWait = wait
                    if expired {
                        let ending = Ending.closedWithoutAcknowledgement(
                            sendQueueVisible: wait.sendQueueVisible)
                        lock.withLock { unacknowledged = ending }
                        break
                    }
                } else {
                    Self.wait(for: stream, Int32(POLLIN))
                }
            } else if count == 0 {
                // The connection ended: the host's close, which the guest waits for once both
                // directions have ended, or else an early end, which loses data. The host may
                // close as soon as the guest's end arrives, before the sending direction has
                // recorded that the write finished, so that direction decides.
                if closeWait == nil || !hasSentEnd || !sendingDirectionWroteItsEnd() {
                    abort()
                }
                break
            } else {
                // A reset or another failure is never the host's close.
                abort()
                break
            }
        }
        directionEnded()
    }

    private var hasSentEnd: Bool { lock.withLock { sendingEnd } }

    /// Waits until the sending direction has written its `streamEnd` frame in full, or failed:
    /// a host that closed before receiving it makes the write fail at once. Returns whether
    /// the frame was written.
    private func sendingDirectionWroteItsEnd() -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let (written, failed) = lock.withLock { (endWritten, aborted) }
            if written { return true }
            if failed { return false }
            usleep(1_000)
        }
        return false
    }
    private var hasWrittenEnd: Bool { lock.withLock { endWritten } }

    /// The guest's wait for the host's close, which counts only time without progress.
    private struct CloseWait {
        let limit: Duration
        private var lastProgress = ContinuousClock.now
        private var unsent = Int32.max
        /// Whether `SIOCOUTQ` could be read at least once.
        private(set) var sendQueueVisible = false

        init(limit: Duration) { self.limit = limit }

        /// Waits up to one poll interval for the connection's end; returns whether the limit
        /// has passed without progress. Until the guest's own `streamEnd` frame is written in
        /// full, its sending direction is still writing, and the limit does not run.
        mutating func waitForClose(of stream: OwnedDescriptor, endWritten: Bool) -> Bool {
            let now = ContinuousClock.now
            let queued = maw_unsent_bytes(stream.rawValue)
            if !endWritten || (queued >= 0 && queued < unsent) {
                lastProgress = now
            }
            if queued >= 0 {
                unsent = queued
                sendQueueVisible = true
            }
            let left = limit - (now - lastProgress)
            guard left > .zero else { return true }
            let milliseconds =
                left.components.seconds * 1_000
                + left.components.attoseconds / 1_000_000_000_000_000 + 1
            ByteRelay.wait(
                for: stream, Int32(POLLIN),
                milliseconds: Int32(min(Int64(ByteRelay.pollIntervalMilliseconds), milliseconds)))
            return false
        }
    }

    // MARK: Shared

    /// Writes `count` bytes from `pointer` to `destination`, waiting while it cannot take
    /// them. Returns false on an error.
    private func sendAll(
        _ pointer: UnsafeRawPointer, _ count: Int, to destination: OwnedDescriptor
    ) -> Bool {
        var offset = 0
        while offset < count {
            let written = maw_send(destination.rawValue, pointer + offset, count - offset)
            if written > 0 {
                offset += written
            } else if written < 0 && Self.mustWait(errno) {
                // A peer that does not read would otherwise hold an aborted relay forever.
                if isAborted { return false }
                Self.wait(for: destination, Int32(POLLOUT))
            } else {
                return false
            }
        }
        return true
    }

    /// Whether a nonblocking read or write that failed with `code` is to be tried again.
    private static func mustWait(_ code: Int32) -> Bool {
        code == EAGAIN || code == EWOULDBLOCK || code == EINTR
    }

    /// Waits until `descriptor` reports `events`, an error, or its end, or until the interval
    /// has passed. The caller tries again in every case, so a missed wakeup costs at most the
    /// interval.
    private static func wait(
        for descriptor: OwnedDescriptor, _ events: Int32,
        milliseconds: Int32 = pollIntervalMilliseconds
    ) {
        var request = pollfd(fd: descriptor.rawValue, events: Int16(events), revents: 0)
        _ = poll(&request, 1, milliseconds)
    }

    /// Counts one direction as ended; after the second, closes both sockets and reports.
    private func directionEnded() {
        let (last, ending) = lock.withLock { () -> (Bool, Ending) in
            running -= 1
            closing = running == 0
            let ending: Ending = aborted ? .aborted : unacknowledged ?? .completed
            return (running == 0, ending)
        }
        guard last else { return }
        if ending == .aborted {
            _ = maw_set_reset_on_close(plain.rawValue)
            _ = maw_set_reset_on_close(stream.rawValue)
        }
        plain.close()
        stream.close()
        finished(ending)
    }
}
