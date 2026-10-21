import CMawSystem
import MawCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// A command running in the guest, started by `GuestAgentClient.exec`.
///
/// A dedicated thread runs the connection: it hands output to the `OutputHandler` and sends
/// what the methods below queue. Every method is safe to call from any thread or task.
public final class GuestProcess: @unchecked Sendable {
    /// The process ID in the guest.
    public let pid: Int32

    /// Standard input that `write` may queue before it blocks.
    static let inputLimit = 256 << 10
    /// Queued frames move to the connection while it holds less than this.
    static let connectionOutputLimit = 64 << 10

    private let lock = ConditionLock()
    private var queue: [Frame] = []
    private var queuedInputBytes = 0
    private var result: Result<ExitStatus, MawError>?
    private var waiters: [CheckedContinuation<Result<ExitStatus, MawError>, Never>] = []
    private let wakeReader: OwnedDescriptor
    private let wakeWriter: OwnedDescriptor

    init(
        connection: FrameConnection, pid: Int32, output: @escaping GuestAgentClient.OutputHandler
    ) throws(MawError) {
        self.pid = pid
        var fds: [Int32] = [-1, -1]
        let error = maw_pipe(&fds)
        guard error == 0 else {
            throw .guestAgentFailed(reason: SystemError("pipe", code: error).description)
        }
        wakeReader = OwnedDescriptor(fds[0])
        wakeWriter = OwnedDescriptor(fds[1])
        _ = maw_set_nonblocking(fds[0])
        _ = maw_set_nonblocking(fds[1])

        let started = startDetachedThread { [self] in
            run(connection, output: output)
        }
        guard started else {
            connection.descriptor.close()
            throw .guestAgentFailed(reason: "could not start the I/O thread")
        }
    }

    // MARK: Input

    /// Queues bytes for the process's standard input. Blocks while more than
    /// `inputLimit` bytes are queued. Returns false once the process has ended.
    @discardableResult
    public func write(_ bytes: some Collection<UInt8>) -> Bool {
        let accepted = lock.withLock {
            while queuedInputBytes >= Self.inputLimit && result == nil {
                lock.wait()
            }
            guard result == nil else { return false }
            var remaining = bytes[...]
            while !remaining.isEmpty {
                let chunk = remaining.prefix(AgentProtocol.maximumDataChunkSize)
                queue.append(Frame(type: .stdin, payload: Array(chunk)))
                queuedInputBytes += chunk.count
                remaining = remaining.dropFirst(chunk.count)
            }
            return true
        }
        if accepted {
            wake()
        }
        return accepted
    }

    /// Ends standard input. In terminal mode, sends the terminal's end-of-file character.
    public func closeInput() {
        enqueue(.stdinEOF)
    }

    /// Sends a signal: to the process group in pipe mode, to the terminal's foreground process
    /// group in terminal mode.
    public func send(_ signal: Signal) {
        enqueue(.signal(signal))
    }

    /// Changes the terminal's window size. Has no effect in pipe mode.
    public func resize(_ size: TerminalSize) {
        enqueue(.resize(size))
    }

    private func enqueue(_ message: ControlMessage) {
        let accepted = lock.withLock {
            guard result == nil else { return false }
            queue.append(.control(message))
            return true
        }
        if accepted {
            wake()
        }
    }

    private func wake() {
        var byte: UInt8 = 1
        _ = systemWrite(wakeWriter.rawValue, &byte, 1)
    }

    // MARK: Exit

    /// Waits until the process has ended and its output has been delivered.
    public func waitForExit() async throws(MawError) -> ExitStatus {
        let outcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<ExitStatus, MawError>, Never>) in
            let finished = lock.withLock { () -> Result<ExitStatus, MawError>? in
                if let result {
                    return result
                }
                waiters.append(continuation)
                return nil
            }
            if let finished {
                continuation.resume(returning: finished)
            }
        }
        return try outcome.get()
    }

    // MARK: I/O thread

    private func run(_ connection: FrameConnection, output: GuestAgentClient.OutputHandler) {
        let outcome: Result<ExitStatus, MawError>
        do {
            outcome = .success(try serve(connection, output: output))
        } catch {
            outcome = .failure(GuestAgentClient.map(error, during: "exec"))
        }
        connection.descriptor.close()

        let waiting = lock.withLock {
            result = outcome
            lock.broadcast()
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in waiting {
            waiter.resume(returning: outcome)
        }
    }

    private func serve(_ connection: FrameConnection, output: GuestAgentClient.OutputHandler)
        throws(ConnectionError) -> ExitStatus
    {
        var drain = [UInt8](repeating: 0, count: 64)
        // Set when the agent has closed its side, typically right after sending `exited`.
        // What it sent before is still read; what is queued for it is dropped.
        var agentStoppedReading = false
        while true {
            // First the frames already buffered: the reply to `exec` may have arrived in the
            // same read as the process's first output.
            while let frame = try connection.nextFrame() {
                switch frame.type {
                case .stdout:
                    frame.payload.withUnsafeBytes { output(.stdout, $0) }
                case .stderr:
                    frame.payload.withUnsafeBytes { output(.stderr, $0) }
                case .control:
                    let message: ControlMessage
                    do throws(FrameError) {
                        message = try frame.controlMessage()
                    } catch {
                        throw .frame(error)
                    }
                    switch message {
                    case .exited(let status):
                        return status
                    case .error(let error):
                        throw .remote(error)
                    default:
                        throw .unexpectedMessage(
                            "unexpected \(message.name) message during an exec session")
                    }
                case .version, .stdin:
                    throw .frame(.unexpectedType(frame.type.rawValue, expected: "output"))
                }
            }
            if connection.isAtEndOfInput {
                throw .closed
            }

            moveQueuedFrames(to: connection)
            if agentStoppedReading {
                connection.discardPendingOutput()
            } else {
                do {
                    try connection.flush()
                } catch .closed {
                    agentStoppedReading = true
                    connection.discardPendingOutput()
                }
            }

            var events: Int32 = 0
            if connection.canReceive {
                events |= POLLIN
            }
            if connection.pendingOutputCount > 0 {
                events |= POLLOUT
            }
            var requests = [
                pollRequest(connection.rawDescriptor, events),
                pollRequest(wakeReader.rawValue, POLLIN),
            ]
            do {
                _ = try pollDescriptors(&requests, timeout: -1)
            } catch {
                throw .system(error)
            }
            if requests[1].returned(POLLIN) {
                while drain.withUnsafeMutableBytes({
                    read(wakeReader.rawValue, $0.baseAddress, $0.count)
                }) > 0 {}
            }
            if requests[0].returned(POLLIN | POLLHUP | POLLERR) {
                try connection.receive()
            }
        }
    }

    /// Moves queued frames to the connection, up to its output limit, and wakes writers
    /// waiting for room.
    private func moveQueuedFrames(to connection: FrameConnection) {
        lock.withLock {
            var moved = 0
            while moved < queue.count
                && connection.pendingOutputCount < Self.connectionOutputLimit
            {
                let frame = queue[moved]
                connection.enqueue(frame)
                if frame.type == .stdin {
                    queuedInputBytes -= frame.payload.count
                }
                moved += 1
            }
            if moved > 0 {
                queue.removeFirst(moved)
                lock.broadcast()
            }
        }
    }
}
