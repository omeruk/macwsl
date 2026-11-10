#if os(macOS)
    import Foundation
    import MawCore
    import MawProtocol
    import MawXPC
    import os

    /// What ended a session that a client runs through the daemon: the command, the daemon,
    /// or a signal to the client. `maw` and the terminal app share it, so that both report a
    /// session's end with the same `MawError`.
    public enum SessionEnding: Sendable {
        case exited(Result<ExitStatus, MawError>)
        /// The connection ended before the command's exit status, with the error that the
        /// guest process reported (`GuestProcess.connectionEndedBeforeExit`).
        case connectionEnded(MawError)
        case daemon(DaemonClient.Event)
        /// A signal that the client chose to end the session on, such as SIGTERM to `maw`.
        case signal(Int32)

        /// How long to wait for the daemon's reason after the guest connection breaks. The
        /// daemon sends `sessionEnded` before it stops a machine, but a crash may reach the
        /// connection first.
        public static let reasonTimeout = Duration.seconds(1)

        /// How a session ended without an error.
        public enum Outcome: Equatable, Sendable {
            /// The command ended with this status.
            case exited(ExitStatus)
            /// The client received this signal.
            case signal(Int32)

            /// The status a shell reports: the command's, or 128 plus the signal's number.
            public var shellStatus: Int32 {
                switch self {
                case .exited(let status): status.shellStatus
                case .signal(let number): 128 + number
                }
            }
        }

        /// Waits for whichever comes first: the command ends, the daemon reports something,
        /// or a signal arrives on `signals`.
        public static func first(
            process: GuestProcess, events: EventRelay, signals: AsyncStream<Int32>?
        ) async -> SessionEnding {
            // waitForExit() does not end on cancellation; a stream does.
            let (exits, continuation) = AsyncStream.makeStream(
                of: Result<ExitStatus, MawError>.self)
            Task {
                do throws(MawError) {
                    continuation.yield(.success(try await process.waitForExit()))
                } catch {
                    continuation.yield(.failure(error))
                }
                continuation.finish()
            }
            return await withTaskGroup(of: SessionEnding?.self) { group in
                group.addTask {
                    for await result in exits {
                        if case .failure(let error) = result, process.connectionEndedBeforeExit {
                            return .connectionEnded(error)
                        }
                        return .exited(result)
                    }
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
                var ending: SessionEnding = .daemon(.connectionLost)
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

        /// The outcome of the session on `machine`, or the error that explains its end. A
        /// broken guest connection waits up to `reasonTimeout` for the daemon's reason.
        public func outcome(events: EventRelay, machine: MachineID) async throws(MawError)
            -> Outcome
        {
            switch self {
            case .exited(.success(let status)):
                return .exited(status)
            case .exited(.failure(let error)):
                // The guest connection broke. The daemon usually knows why.
                if let event = await events.next(within: Self.reasonTimeout) {
                    throw Self.error(for: event, machine: machine)
                }
                throw error
            case .connectionEnded(let error):
                // A machine that stopped ends its sessions' connections too, and the daemon
                // says so.
                if let event = await events.next(within: Self.reasonTimeout) {
                    throw Self.error(for: event, machine: machine)
                }
                Logger.client.debug(
                    "\(machine.name, privacy: .public): the session's connection ended before the exit status: \(error.description, privacy: .public)"
                )
                throw .sessionConnectionEnded(distribution: machine.name)
            case .daemon(let event):
                throw Self.error(for: event, machine: machine)
            case .signal(let number):
                return .signal(number)
            }
        }

        /// The error for a daemon event that ended the session on `machine`.
        public static func error(for event: DaemonClient.Event, machine: MachineID) -> MawError {
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
    }

    /// Keeps the daemon's first event for a session.
    ///
    /// Every event ends a session, so only the first matters, and reading it does not consume
    /// it: a waiter that is cancelled, such as the losing task of `SessionEnding.first`, cannot
    /// lose it for the next one. (An `AsyncStream` also finishes when a task iterating it is
    /// cancelled, so a session cannot iterate `DaemonClient.events` twice.)
    public final class EventRelay: Sendable {
        private struct State {
            var event: DaemonClient.Event?
            var isFinished = false
            var waiters: [UUID: CheckedContinuation<DaemonClient.Event?, Never>] = [:]
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        /// Relays `events`, normally `DaemonClient.events`. Installation progress is dropped.
        public init(_ events: AsyncStream<DaemonClient.Event>) {
            Task { [self] in
                for await event in events {
                    if case .installProgress = event { continue }
                    settle(event)
                }
                settle(nil)
            }
        }

        /// The first event, once there is one; `nil` if the stream finished without one or
        /// the task is cancelled.
        public func next() async -> DaemonClient.Event? {
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
        public func next(within timeout: Duration) async -> DaemonClient.Event? {
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

        /// Records the first event, or the end of the stream with `nil`, and wakes every
        /// waiter.
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

    extension Logger {
        /// The client library. A client reports errors to its user; the unified log keeps
        /// detail that the message leaves out.
        static let client = Logger(subsystem: "dev.maw", category: "client")
    }
#endif
