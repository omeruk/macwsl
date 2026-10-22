import Darwin
import Foundation
import MawClient
import MawCore
import MawProtocol
import MawTerminalIO
import MawXPC
import os

/// Runs a session through the daemon: opens it, runs the plan's command with the guest agent
/// over the connection the daemon hands over, and returns the command's exit status.
///
/// Terminal bytes travel between this process and the guest directly; the daemon only holds
/// the session's lease, through the XPC connection, until this process exits.
struct SessionRunner {
    /// How long to wait for the daemon's reason after the guest connection breaks. The daemon
    /// sends `sessionEnded` before it stops a machine, but a crash may reach the connection
    /// first.
    static let endingReasonTimeout = Duration.seconds(1)

    let plan: SessionPlan
    let mode: SessionMode

    /// What ended the session.
    enum Ending: Sendable {
        case exited(Result<ExitStatus, MawError>)
        case daemon(DaemonClient.Event)
        case signal(Int32)
    }

    func run() async throws -> Int32 {
        // Before anything else, so that output to a closed pipe (`| head`) cannot kill maw.
        signal(SIGPIPE, SIG_IGN)
        let client = try await DaemonClient.connect()
        defer { client.close() }
        let events = EventRelay(client.events)
        let session = try await client.openSession(on: plan.machine)
        let request = ExecRequest(
            program: plan.program, user: plan.user,
            locale: GuestLocale.preferred(
                languageCode: Locale.current.language.languageCode?.identifier,
                regionCode: Locale.current.region?.identifier),
            environment: mode.environment(host: ProcessInfo.processInfo.environment),
            workingDirectory: plan.workingDirectory,
            terminal: mode == .terminal
                ? (Terminal.windowSize() ?? TerminalSize(rows: 24, columns: 80)) : nil)

        let ending: Ending
        switch mode {
        case .pipes:
            ending = try await runWithPipes(request, session: session, events: events)
        case .terminal:
            ending = try await runOnTerminal(request, session: session, events: events)
        }
        return try await status(after: ending, events: events)
    }

    // MARK: Modes

    /// Pipes: standard output and error stay separate, and SIGINT, SIGTERM, and SIGHUP go to
    /// the command.
    private func runWithPipes(
        _ request: ExecRequest, session: DaemonSession, events: EventRelay
    ) async throws -> Ending {
        let router = SignalRouter(SignalMonitor([SIGINT, SIGTERM, SIGHUP]))
        let process = try await start(request, session: session)
        router.attach(process)
        Self.forwardStandardInput(to: process)
        return await Self.firstEnding(process: process, events: events, signals: nil)
    }

    /// A terminal: raw mode, window size changes, and the terminal restored on every path.
    /// Ctrl-C is a byte for the guest. SIGINT, SIGTERM, SIGHUP, and SIGQUIT sent to maw from
    /// elsewhere end the session, after which the terminal is restored; the guest agent then
    /// hangs up the guest's terminal, as sshd does.
    private func runOnTerminal(
        _ request: ExecRequest, session: DaemonSession, events: EventRelay
    ) async throws -> Ending {
        let signals = SignalMonitor(SignalMonitor.orderlySignals)
        let resizes = SignalMonitor([SIGWINCH])
        let rawMode = try RawMode(for: "a shell")
        defer { rawMode.restore() }
        let process = try await start(request, session: session)
        Self.forwardStandardInput(to: process)
        let resizing = Task {
            for await _ in resizes.signals {
                if let size = Terminal.windowSize() {
                    process.resize(size)
                }
            }
        }
        defer { resizing.cancel() }
        return await Self.firstEnding(process: process, events: events, signals: signals.signals)
    }

    private func start(_ request: ExecRequest, session: DaemonSession) async throws(MawError)
        -> GuestProcess
    {
        try await session.agentClient().exec(request, output: Self.writeOutput)
    }

    // MARK: Ending

    /// The exit status for `ending`, or the error that explains it.
    private func status(after ending: Ending, events: EventRelay) async throws -> Int32 {
        switch ending {
        case .exited(.success(let status)):
            return status.shellStatus
        case .exited(.failure(let error)):
            // The guest connection broke. The daemon usually knows why.
            if let event = await events.next(within: Self.endingReasonTimeout) {
                throw Self.error(for: event, machine: plan.machine)
            }
            throw error
        case .daemon(let event):
            throw Self.error(for: event, machine: plan.machine)
        case .signal(let number):
            return 128 + number
        }
    }

    static func error(for event: DaemonClient.Event, machine: MachineID) -> MawError {
        switch event {
        case .sessionEnded(let ended):
            .machineStopped(machine: ended.machine.name, reason: ended.reason)
        case .connectionLost:
            .daemonConnectionLost(during: "the session on \(machine.name)")
        case .installProgress:
            // A session's connection never installs; EventRelay drops these.
            .daemonProtocolError(reason: "installation progress arrived during a session")
        }
    }

    /// Waits for whichever comes first: the command ends, the daemon reports something, or
    /// a signal arrives.
    static func firstEnding(
        process: GuestProcess, events: EventRelay, signals: AsyncStream<Int32>?
    ) async -> Ending {
        // waitForExit() does not end on cancellation; a stream does.
        let (exits, continuation) = AsyncStream.makeStream(of: Result<ExitStatus, MawError>.self)
        Task {
            do throws(MawError) {
                continuation.yield(.success(try await process.waitForExit()))
            } catch {
                continuation.yield(.failure(error))
            }
            continuation.finish()
        }
        return await withTaskGroup(of: Ending?.self) { group in
            group.addTask {
                for await result in exits { return .exited(result) }
                return nil
            }
            group.addTask {
                await events.next().map { .daemon($0) }
            }
            if let signals {
                group.addTask {
                    for await number in signals { return .signal(number) }
                    return nil
                }
            }
            var ending: Ending = .daemon(.connectionLost)
            while let next = await group.next() {
                if let next {
                    ending = next
                    break
                }
            }
            group.cancelAll()
            return ending
        }
    }

    // MARK: Standard streams

    /// Writes the command's output to this process's standard output or error. A write error
    /// such as EPIPE discards the output; the command keeps running.
    @Sendable
    static func writeOutput(
        _ stream: GuestAgentClient.OutputStream, _ bytes: UnsafeRawBufferPointer
    ) {
        try? writeAll(bytes, to: stream == .stdout ? STDOUT_FILENO : STDERR_FILENO)
    }

    /// Copies standard input to the command on a thread of its own, then ends its input.
    static func forwardStandardInput(to process: GuestProcess) {
        Thread {
            var buffer = [UInt8](repeating: 0, count: 32 << 10)
            while true {
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0, process.write(buffer[..<count]) else { break }
            }
            process.closeInput()
        }.start()
    }
}

/// Keeps the daemon's first event for the session.
///
/// Every event ends a session, so only the first matters, and reading it does not consume it:
/// a waiter that is cancelled, such as the losing task of `firstEnding`, cannot lose it for
/// the next one. (An `AsyncStream` also finishes when a task iterating it is cancelled, so the
/// session cannot iterate `DaemonClient.events` twice.)
final class EventRelay: Sendable {
    private struct State {
        var event: DaemonClient.Event?
        var isFinished = false
        var waiters: [UUID: CheckedContinuation<DaemonClient.Event?, Never>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ events: AsyncStream<DaemonClient.Event>) {
        Task { [self] in
            for await event in events {
                if case .installProgress = event { continue }
                settle(event)
            }
            settle(nil)
        }
    }

    /// The first event, once there is one; `nil` if the stream finished without one or the
    /// task is cancelled.
    func next() async -> DaemonClient.Event? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> DaemonClient.Event?? in
                    if let event = state.event { return .some(event) }
                    if state.isFinished || Task.isCancelled { return .some(nil) }
                    state.waiters[id] = continuation
                    return .none
                }
                if case .some(let event) = ready {
                    continuation.resume(returning: event)
                }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(returning: nil)
        }
    }

    /// The first event, if there is one within `timeout`.
    func next(within timeout: Duration) async -> DaemonClient.Event? {
        await withTaskGroup(of: DaemonClient.Event?.self) { group in
            group.addTask { await self.next() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Records the first event, or the end of the stream with `nil`, and wakes every waiter.
    private func settle(_ event: DaemonClient.Event?) {
        let (waiters, result) = state.withLock { state in
            if state.event == nil && !state.isFinished {
                if let event { state.event = event } else { state.isFinished = true }
            }
            defer { state.waiters = [:] }
            return (Array(state.waiters.values), state.event)
        }
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }
}
