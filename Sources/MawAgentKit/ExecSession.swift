import CMawSystem
import Logging
import MawProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// One exec session: relays a child process's standard streams, signals, and window size over
/// its connection until the process has exited and its output has been sent.
///
/// The session runs one `poll(2)` loop on its own thread. Every buffer is bounded:
///
/// - Input from the host: the host sends at most `AgentProtocol.inputWindow` bytes of standard
///   input that the session has not reported consumed with `stdinConsumed`, so the input
///   waiting for the process never exceeds the window. The session therefore reads the
///   connection at all times and acts on `signal` and `resize` as they arrive, however much
///   input the process leaves unread. Input beyond the window is a protocol violation.
/// - Output to the host: the process's output is read only while the connection holds less
///   than `outputLimit` unsent bytes. Beyond that the process's writes block.
final class ExecSession {
    static let outputLimit = 64 << 10
    /// Consumed input is reported once it reaches this many bytes: often enough that the host
    /// never waits for room while the process reads, rarely enough to cost little
    /// (decision record 0016).
    static let consumedReportThreshold = AgentProtocol.inputWindow / 4
    /// How long output may still arrive after the process exits, from descendants that keep
    /// its pipes open.
    static let drainGrace = Duration.milliseconds(250)
    /// How long a process may run after the host disconnects and SIGHUP is sent, before
    /// SIGKILL.
    static let hangupGrace = Duration.seconds(2)
    /// How often to check for the exit when no exit watch could be opened.
    static let reapInterval = Duration.milliseconds(50)
    /// How long to wait for the host to accept the final `exited` message.
    static let finalFlushTimeout = Duration.seconds(5)

    private let connection: FrameConnection
    private let child: ChildProcess
    private let logger: Logger

    /// Input for the process: the host's bytes, then, after `stdinEOF` in terminal mode, the
    /// terminal's end-of-file character.
    private var pendingInput = ByteBuffer()
    private var endOfFileCharacterPending = false
    /// Set by `stdinEOF`. Later input is discarded.
    private var inputEnded = false
    /// Input written to the process or discarded, not yet reported to the host.
    private var consumedInput = 0
    private var exitedAt: ContinuousClock.Instant?
    private var hostLeftAt: ContinuousClock.Instant?
    private var killedAfterHangup = false
    private var readBuffer = [UInt8](repeating: 0, count: AgentProtocol.maximumDataChunkSize)

    init(connection: FrameConnection, child: ChildProcess, logger: Logger) {
        self.connection = connection
        self.child = child
        self.logger = logger
    }

    private var pendingInputCount: Int { pendingInput.count }

    /// The host's bytes in `pendingInput`.
    private var pendingHostInput: Int {
        pendingInput.count - (endOfFileCharacterPending ? 1 : 0)
    }

    /// Runs the session. On a protocol error, kills the process group, reaps the process, and
    /// rethrows.
    func run() throws(ConnectionError) {
        do {
            try relay()
        } catch {
            child.terminate()
            throw error
        }
    }

    private func relay() throws(ConnectionError) {
        connection.enqueue(.control(.started(pid: child.pid)))
        while true {
            try takeBufferedFrames()

            if child.exitWatch == nil {
                child.reap()
            }
            if let status = child.exitStatus {
                let now = ContinuousClock.now
                let exitedAt = self.exitedAt ?? now
                if self.exitedAt == nil {
                    child.releaseTerminal()
                }
                self.exitedAt = exitedAt
                if child.outputs.isEmpty || now >= exitedAt + Self.drainGrace {
                    if hostLeftAt == nil {
                        connection.enqueue(.control(.exited(status)))
                        try connection.flush(until: now + Self.finalFlushTimeout)
                    }
                    return
                }
            }
            if let hostLeftAt, !killedAfterHangup,
                ContinuousClock.now >= hostLeftAt + Self.hangupGrace
            {
                killedAfterHangup = true
                child.send(SIGKILL)
            }

            reportConsumedInput()
            try pollOnce()
        }
    }

    // MARK: Polling

    private enum Source {
        case connection
        case output(Int)
        case input
        case exitWatch
    }

    private func pollOnce() throws(ConnectionError) {
        var requests: [pollfd] = []
        var sources: [Source] = []
        func add(_ descriptor: Int32, _ events: Int32, _ source: Source) {
            requests.append(pollfd(fd: descriptor, events: Int16(events), revents: 0))
            sources.append(source)
        }

        if hostLeftAt == nil {
            var events: Int32 = 0
            if connection.canReceive {
                events |= POLLIN
            }
            if connection.pendingOutputCount > 0 {
                events |= POLLOUT
            }
            add(connection.rawDescriptor, events, .connection)
        }
        // After the host has gone, output is still read, and discarded, so that the process
        // does not block on a full pipe while it shuts down.
        if hostLeftAt != nil || connection.pendingOutputCount < Self.outputLimit {
            for (index, output) in child.outputs.enumerated() {
                add(output.descriptor.rawValue, POLLIN, .output(index))
            }
        }
        if let input = child.input, pendingInputCount > 0 {
            add(input.rawValue, POLLOUT, .input)
        }
        if let exitWatch = child.exitWatch, child.exitStatus == nil {
            add(exitWatch.rawValue, POLLIN, .exitWatch)
        }

        let ready: Int32
        do {
            ready = try pollDescriptors(&requests, timeout: pollTimeout(until: nextDeadline()))
        } catch {
            throw .system(error)
        }
        guard ready > 0 else { return }

        // Outputs that reached end-of-file are removed after the loop, highest index first, so
        // that the indices in `sources` stay valid while it runs.
        var closedOutputs: [Int] = []
        for (request, source) in zip(requests, sources) where request.revents != 0 {
            switch source {
            case .connection:
                try handleConnection(request)
            case .output(let index):
                if !readOutput(index) {
                    closedOutputs.append(index)
                }
            case .input:
                writeInput()
            case .exitWatch:
                child.reap()
            }
        }
        for index in closedOutputs.sorted(by: >) {
            child.closeOutput(at: index)
        }
    }

    private func nextDeadline() -> ContinuousClock.Instant? {
        var deadlines: [ContinuousClock.Instant] = []
        if let exitedAt {
            deadlines.append(exitedAt + Self.drainGrace)
        } else if child.exitStatus != nil {
            deadlines.append(.now)
        }
        if let hostLeftAt, !killedAfterHangup {
            deadlines.append(hostLeftAt + Self.hangupGrace)
        }
        if child.exitWatch == nil && child.exitStatus == nil {
            deadlines.append(.now + Self.reapInterval)
        }
        return deadlines.min()
    }

    // MARK: Connection

    private func handleConnection(_ request: pollfd) throws(ConnectionError) {
        if request.returned(POLLOUT) {
            do {
                try connection.flush()
            } catch .closed {
                hostLeft()
                return
            }
        }
        if request.returned(POLLIN | POLLHUP | POLLERR) {
            try connection.receive()
            try takeBufferedFrames()
            if connection.isAtEndOfInput && hostLeftAt == nil {
                hostLeft()
            }
        }
    }

    /// The host closed the connection without waiting for the exit. As sshd does, the agent
    /// hangs up on the process, and kills it if it is still running after `hangupGrace`.
    private func hostLeft() {
        logger.notice("exec \(child.pid): the host disconnected; sending SIGHUP")
        hostLeftAt = .now
        pendingInput.removeAll()
        endOfFileCharacterPending = false
        child.closeInput()
        child.send(SIGHUP)
    }

    /// Acts on every buffered frame.
    private func takeBufferedFrames() throws(ConnectionError) {
        while hostLeftAt == nil, let frame = try connection.nextFrame() {
            switch frame.type {
            case .stdin:
                guard
                    pendingHostInput + consumedInput + frame.payload.count
                        <= AgentProtocol.inputWindow
                else {
                    throw .unexpectedMessage(
                        "standard input exceeded the window of \(AgentProtocol.inputWindow) bytes")
                }
                if child.input != nil && !inputEnded {
                    pendingInput.append(contentsOf: frame.payload)
                } else {
                    consumedInput += frame.payload.count
                }
            case .control:
                let message: ControlMessage
                do throws(FrameError) {
                    message = try frame.controlMessage()
                } catch {
                    throw .frame(error)
                }
                try handle(message)
            case .version, .stdinConsumed, .stdout, .stderr, .dialBackNonce:
                throw .frame(.unexpectedType(frame.type.rawValue, expected: "stdin or control"))
            }
        }
    }

    private func handle(_ message: ControlMessage) throws(ConnectionError) {
        switch message {
        case .stdinEOF:
            guard !inputEnded else { return }
            inputEnded = true
            if child.terminal != nil {
                // A terminal has no end-of-file; its line discipline turns the EOF character
                // into one for the reader, as ssh does.
                if child.input != nil {
                    pendingInput.append(child.endOfFileCharacter)
                    endOfFileCharacterPending = true
                }
            } else if pendingInputCount == 0 {
                child.closeInput()
            }
        case .signal(let signal):
            child.send(signal.localNumber)
        case .resize(let size):
            child.resize(size)
        default:
            throw .unexpectedMessage("\(message.name) is not valid during an exec session")
        }
    }

    // MARK: Process streams

    /// Reads one chunk of output. Returns false at end-of-file.
    private func readOutput(_ index: Int) -> Bool {
        let output = child.outputs[index]
        let count = readBuffer.withUnsafeMutableBytes { buffer in
            read(output.descriptor.rawValue, buffer.baseAddress, buffer.count)
        }
        if count > 0 {
            if hostLeftAt == nil {
                readBuffer.withUnsafeBytes { buffer in
                    connection.enqueueData(
                        UnsafeRawBufferPointer(rebasing: buffer[..<count]), type: output.type)
                }
            }
            return true
        }
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
            return true
        }
        // 0 is end-of-file. A pseudo-terminal's primary side reports EIO once every secondary
        // descriptor is closed.
        return false
    }

    private func writeInput() {
        guard let input = child.input else { return }
        let written = pendingInput.withUnsafeBytes { buffer in
            write(input.rawValue, buffer.baseAddress!, buffer.count)
        }
        if written > 0 {
            consumedInput += min(written, pendingHostInput)
            pendingInput.consume(written)
        } else if written < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
            // EPIPE: the process closed its standard input. EIO: the terminal is gone.
            consumedInput += pendingHostInput
            pendingInput.removeAll()
            child.closeInput()
        }
        if pendingInputCount == 0 {
            endOfFileCharacterPending = false
            if inputEnded {
                child.closeInput()
            }
        }
    }

    /// Returns consumed input to the host's window once there is enough of it.
    private func reportConsumedInput() {
        guard hostLeftAt == nil, consumedInput >= Self.consumedReportThreshold else { return }
        connection.enqueue(.stdinConsumed(UInt32(consumedInput)))
        consumedInput = 0
    }
}
