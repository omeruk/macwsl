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
/// A dedicated I/O thread runs the connection: it sends what the methods below queue and
/// queues the output it receives for a second thread, which hands it to the `OutputHandler`.
/// Every method is safe to call from any thread or task.
///
/// Standard input and its end travel in order. `signal` and `resize` overtake the input that
/// has not been sent yet, and the input window (`AgentProtocol.inputWindow`) keeps the input
/// already sent small enough for the agent to read the connection at all times, so that both
/// reach the agent at once however much input the process leaves unread. The I/O thread never
/// waits for the `OutputHandler`, so that they also reach it while the handler blocks.
public final class GuestProcess: @unchecked Sendable {
    /// The process ID in the guest.
    public let pid: Int32

    /// Standard input that `write` may queue before it blocks.
    static let inputLimit = 256 << 10
    /// Queued frames move to the connection while it holds less than this.
    static let connectionOutputLimit = 64 << 10
    /// Output that may wait for the `OutputHandler` before the I/O thread stops reading it.
    static let outputLimit = 256 << 10

    private typealias QueuedOutput = (stream: GuestAgentClient.OutputStream, bytes: [UInt8])

    private let lock = ConditionLock()
    /// Standard input and its end, in order.
    private var queue: [Frame] = []
    /// `signal` and `resize`, sent before `queue`. Each signal is queued once, as a process's
    /// pending signals are, and only the latest size, so that this stays small.
    private var controlQueue: [ControlMessage] = []
    private var queuedInputBytes = 0
    /// Standard input sent and not yet reported consumed by the agent. Used by the I/O thread
    /// only.
    private var unconsumedInput = 0
    /// Output received and not yet handed to the `OutputHandler`.
    private var outputQueue: [QueuedOutput] = []
    private var queuedOutputBytes = 0
    /// How the connection ended, set by the I/O thread. Input is refused from then on.
    private var ending: Result<ExitStatus, MawError>?
    /// `ending`, once the output received before it has been delivered.
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

        guard startDetachedThread({ [self] in deliverOutput(to: output) }) else {
            connection.descriptor.close()
            throw .guestAgentFailed(reason: "could not start the output thread")
        }
        guard startDetachedThread({ [self] in run(connection) }) else {
            connection.descriptor.close()
            end(.failure(.guestAgentFailed(reason: "could not start the I/O thread")))
            throw .guestAgentFailed(reason: "could not start the I/O thread")
        }
    }

    // MARK: Input

    /// Queues bytes for the process's standard input. Blocks while more than
    /// `inputLimit` bytes are queued. Returns false once the process has ended.
    @discardableResult
    public func write(_ bytes: some Collection<UInt8>) -> Bool {
        let accepted = lock.withLock {
            while queuedInputBytes >= Self.inputLimit && ending == nil {
                lock.wait()
            }
            guard ending == nil else { return false }
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

    /// Ends standard input, after the input queued before. In terminal mode, sends the
    /// terminal's end-of-file character.
    public func closeInput() {
        enqueue { queue.append(.control(.stdinEOF)) }
    }

    /// Sends a signal: to the process group in pipe mode, to the terminal's foreground process
    /// group in terminal mode. It overtakes standard input that has not been sent yet.
    public func send(_ signal: Signal) {
        enqueue {
            if !controlQueue.contains(.signal(signal)) {
                controlQueue.append(.signal(signal))
            }
        }
    }

    /// Changes the terminal's window size. Has no effect in pipe mode. It overtakes standard
    /// input that has not been sent yet.
    public func resize(_ size: TerminalSize) {
        enqueue {
            controlQueue.removeAll {
                if case .resize = $0 { true } else { false }
            }
            controlQueue.append(.resize(size))
        }
    }

    private func enqueue(_ add: () -> Void) {
        let accepted = lock.withLock {
            guard ending == nil else { return false }
            add()
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

    // MARK: Output thread

    /// Hands queued output to `output` until the connection has ended and everything before
    /// the end has been delivered, then publishes the result.
    private func deliverOutput(to output: GuestAgentClient.OutputHandler) {
        while true {
            let work = lock.withLock { () -> OutputWork in
                while outputQueue.isEmpty && ending == nil {
                    lock.wait()
                }
                if let ending, outputQueue.isEmpty {
                    return .finish(ending)
                }
                defer {
                    outputQueue = []
                    queuedOutputBytes = 0
                }
                return .deliver(outputQueue, resumeReading: queuedOutputBytes >= Self.outputLimit)
            }
            switch work {
            case .deliver(let batch, let resumeReading):
                // The I/O thread stopped reading at the limit; it may read again.
                if resumeReading {
                    wake()
                }
                for piece in batch {
                    piece.bytes.withUnsafeBytes { output(piece.stream, $0) }
                }
            case .finish(let outcome):
                publish(outcome)
                return
            }
        }
    }

    private enum OutputWork {
        case deliver([QueuedOutput], resumeReading: Bool)
        case finish(Result<ExitStatus, MawError>)
    }

    private func publish(_ outcome: Result<ExitStatus, MawError>) {
        let waiting = lock.withLock {
            result = outcome
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in waiting {
            waiter.resume(returning: outcome)
        }
    }

    // MARK: I/O thread

    private func run(_ connection: FrameConnection) {
        let outcome: Result<ExitStatus, MawError>
        do {
            outcome = .success(try serve(connection))
        } catch {
            outcome = .failure(GuestAgentClient.map(error, during: "exec"))
        }
        connection.descriptor.close()
        end(outcome)
    }

    /// Records how the connection ended: writers stop waiting, and the output thread
    /// publishes `outcome` once it has delivered the output before it.
    private func end(_ outcome: Result<ExitStatus, MawError>) {
        lock.withLock {
            ending = outcome
            lock.broadcast()
        }
    }

    private func queueOutput(_ stream: GuestAgentClient.OutputStream, _ bytes: [UInt8]) {
        lock.withLock {
            if outputQueue.isEmpty {
                lock.broadcast()
            }
            outputQueue.append((stream, bytes))
            queuedOutputBytes += bytes.count
        }
    }

    private func serve(_ connection: FrameConnection) throws(ConnectionError) -> ExitStatus {
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
                    queueOutput(.stdout, frame.payload)
                case .stderr:
                    queueOutput(.stderr, frame.payload)
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
                case .stdinConsumed:
                    let bytes: UInt32
                    do throws(FrameError) {
                        bytes = try frame.consumedByteCount()
                    } catch {
                        throw .frame(error)
                    }
                    guard Int(bytes) <= unconsumedInput else {
                        throw .unexpectedMessage(
                            "the agent reported \(bytes) bytes of input consumed, but only "
                                + "\(unconsumedInput) were outstanding")
                    }
                    unconsumedInput -= Int(bytes)
                case .version, .stdin, .dialBackNonce:
                    throw .frame(.unexpectedType(frame.type.rawValue, expected: "output"))
                }
            }
            if connection.isAtEndOfInput {
                throw .closed
            }

            let framesRemain = moveQueuedFrames(to: connection)
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
            // While the output thread is behind, the I/O thread stops reading, which applies
            // back-pressure to the process, but it keeps sending.
            let outputIsFull = lock.withLock { queuedOutputBytes >= Self.outputLimit }
            if connection.canReceive && !outputIsFull {
                events |= POLLIN
            }
            // Frames that only the connection's output limit holds back need the next
            // iteration as well: when one flush then sends everything, as vsock's large credit
            // grants allow, a writer blocked on the full queue sends no wake-up. Frames held
            // back by the input window wait for `stdinConsumed` instead.
            if connection.pendingOutputCount > 0 || (framesRemain && !agentStoppedReading) {
                events |= POLLOUT
            }
            // With no events, the connection is left out: `poll` reports a hang-up whatever the
            // events requested, and the thread would spin until the output thread catches up.
            var requests = [
                pollRequest(events == 0 ? -1 : connection.rawDescriptor, events),
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
            if events & POLLIN != 0 && requests[0].returned(POLLIN | POLLHUP | POLLERR) {
                try connection.receive()
            }
        }
    }

    /// Moves queued frames to the connection, and wakes writers waiting for room: `signal`
    /// and `resize` first, then standard input and its end, in order, while the connection
    /// holds less than its output limit and the input window has room. Returns whether frames
    /// remain that only the output limit holds back.
    private func moveQueuedFrames(to connection: FrameConnection) -> Bool {
        lock.withLock {
            for message in controlQueue {
                connection.enqueue(.control(message))
            }
            controlQueue.removeAll()

            var moved = 0
            var heldByWindow = false
            while moved < queue.count
                && connection.pendingOutputCount < Self.connectionOutputLimit
            {
                let frame = queue[moved]
                if frame.type == .stdin {
                    guard unconsumedInput + frame.payload.count <= AgentProtocol.inputWindow
                    else {
                        heldByWindow = true
                        break
                    }
                    unconsumedInput += frame.payload.count
                    queuedInputBytes -= frame.payload.count
                }
                connection.enqueue(frame)
                moved += 1
            }
            if moved > 0 {
                queue.removeFirst(moved)
                lock.broadcast()
            }
            return !queue.isEmpty && !heldByWindow
        }
    }
}
