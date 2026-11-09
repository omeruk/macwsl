#if os(macOS)
    import Foundation
    import MawCore
    import MawProtocol
    import MawXPC
    import os

    /// A login shell in a distribution on a pseudo-terminal, opened through the daemon: the part
    /// of the terminal app's Linux session that needs neither SwiftTerm nor AppKit.
    ///
    /// The session connects a `DaemonClient` of its own and closes it when the session ends,
    /// whichever way it ends, so that it holds its machine's lease exactly while it is open.
    /// Terminal bytes travel between this process and the guest directly. Framing, the
    /// handshake, flow control, and the dial-back belong to `GuestAgentClient` and
    /// `GuestProcess`, and how a session ends to `SessionEnding`, which `maw` shares.
    ///
    /// Every method is safe to call from any thread or task, and none blocks.
    public final class DistributionSession: Sendable {
        /// How a session ended.
        public enum Ending: Equatable, Sendable {
            /// The shell exited with this status.
            case exited(ExitStatus)
            /// The session could not open, or something other than its shell ended it: the
            /// machine stopped (`machineStopped`), the guest connection ended
            /// (`sessionConnectionEnded`), the daemon went away (`daemonConnectionLost`), or
            /// the agent failed (`guestAgentFailed`).
            case failed(MawError)
            /// `hangUp()` ended it. There is nothing to report.
            case hungUp
        }

        /// A session whose shell has started.
        public struct Started: Equatable, Sendable {
            /// The session's machine, which names the distribution as it is stored.
            public var info: SessionInfo
            /// The shell's process in the guest.
            public var processID: Int32
        }

        public typealias Connector = @Sendable () async throws(MawError) -> DaemonClient

        private struct State {
            var isOpening = false
            var client: DaemonClient?
            var process: GuestProcess?
            var size: TerminalSize
            var ending: Ending?
            var waiters: [CheckedContinuation<Ending, Never>] = []
        }

        private let distribution: DistroName?
        private let request: ExecRequest
        private let connect: Connector
        private let output: GuestAgentClient.OutputHandler
        private let input = InputForwarder()
        private let state: OSAllocatedUnfairLock<State>

        /// - Parameters:
        ///   - distribution: The distribution, or `nil` for the default one, which the daemon
        ///     resolves when the session opens.
        ///   - terminal: The terminal's size when the shell starts.
        ///   - locale: The locale the guest should use if it has it (`ExecRequest.locale`).
        ///   - programVersion: The app's version, for `TERM_PROGRAM_VERSION`.
        ///   - connect: Connects to the daemon. The unit tests connect to a scripted one.
        ///   - output: Receives the terminal's output, as `GuestAgentClient.exec` describes. It
        ///     may block, which slows the guest's writer down.
        public init(
            distribution: DistroName?, terminal: TerminalSize,
            locale: String? = DistributionSession.preferredLocale(), programVersion: String? = nil,
            connect: @escaping Connector = { () async throws(MawError) -> DaemonClient in
                try await DaemonClient.connect()
            },
            output: @escaping GuestAgentClient.OutputHandler
        ) {
            self.distribution = distribution
            request = ExecRequest(
                program: .loginShell, locale: locale,
                environment: Self.environment(programVersion: programVersion),
                terminal: terminal)
            self.connect = connect
            self.output = output
            state = OSAllocatedUnfairLock(initialState: State(size: terminal))
        }

        /// The terminal's identity, and nothing inherited from this process. `runuser -l`
        /// keeps these variables, because the agent passes every requested one.
        static func environment(programVersion: String?) -> [String: String] {
            var environment = [
                "TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "maw",
            ]
            environment["TERM_PROGRAM_VERSION"] = programVersion
            return environment
        }

        /// The Mac's language and region as a guest locale, as `maw` asks for it.
        public static func preferredLocale(_ locale: Locale = .current) -> String? {
            GuestLocale.preferred(
                languageCode: locale.language.languageCode?.identifier,
                regionCode: locale.region?.identifier)
        }

        // MARK: Opening

        /// Connects, opens the session, and starts the shell. Returns `nil` if the session
        /// ended before its shell started, with an error or through `hangUp()`;
        /// `waitForEnding()` says how. Call it once.
        public func open() async -> Started? {
            let isFirst = state.withLock { state in
                defer { state.isOpening = true }
                return !state.isOpening && state.ending == nil
            }
            guard isFirst else { return nil }

            let client: DaemonClient
            do {
                client = try await connect()
            } catch {
                end(.failed(error))
                return nil
            }
            guard adopt(client) else { return nil }
            let events = EventRelay(client.events)
            var request = request
            let session: DaemonSession
            let process: GuestProcess
            do {
                session = try await client.openSession(on: distribution.map(MachineID.distribution))
                guard state.withLock({ $0.ending == nil }) else {
                    session.agentConnection.close()
                    return nil
                }
                request.terminal = state.withLock { $0.size }
                process = try await session.agentClient().exec(request, output: output)
            } catch {
                end(.failed(error))
                return nil
            }
            guard adopt(process, startedAt: request.terminal) else { return nil }
            guard input.start(writingTo: process) else {
                end(.failed(.guestAgentFailed(reason: "could not start the input thread")))
                return nil
            }
            Task { await watch(process, events: events, machine: session.info.machine) }
            return Started(info: session.info, processID: process.pid)
        }

        /// Keeps `client` for the session, or closes it if the session has ended meanwhile.
        private func adopt(_ client: DaemonClient) -> Bool {
            let adopted = state.withLock { state in
                guard state.ending == nil else { return false }
                state.client = client
                return true
            }
            if !adopted {
                client.close()
            }
            return adopted
        }

        /// Keeps `process` for the session and gives it the terminal's size if it changed while
        /// the shell started, or hangs it up if the session has ended meanwhile. Sizes reach the
        /// process under the lock, so that the latest one is the last one sent.
        private func adopt(_ process: GuestProcess, startedAt size: TerminalSize?) -> Bool {
            let adopted = state.withLock { state in
                guard state.ending == nil else { return false }
                state.process = process
                if state.size != size {
                    process.resize(state.size)
                }
                return true
            }
            if !adopted {
                process.hangUp()
            }
            return adopted
        }

        // MARK: While open

        /// Queues typed keys or pasted text for the shell. Never blocks: a thread of the
        /// session's own hands them to `GuestProcess.write`, which blocks while its queue is
        /// full. Input sent while the session opens waits for the shell.
        public func send(_ bytes: some Collection<UInt8>) {
            input.append(bytes)
        }

        /// Gives the terminal a new size, now or, while the session opens, when the shell
        /// starts.
        public func resize(_ size: TerminalSize) {
            state.withLock { state in
                state.size = size
                state.process?.resize(size)
            }
        }

        /// The program in the foreground of the terminal (`GuestProcess.foregroundProgram`).
        /// A session whose shell has not started, or that has ended, answers `none`.
        public func foregroundProgram(within timeout: Duration) async -> ForegroundAnswer {
            guard let process = state.withLock({ $0.ending == nil ? $0.process : nil }) else {
                return .none
            }
            return await process.foregroundProgram(within: timeout)
        }

        /// Ends the session as closing a terminal window ends an ssh session: the guest's
        /// shell receives SIGHUP, and closing the daemon connection releases the lease at
        /// once, also while the session opens. The session ends as `hungUp`, unless it had
        /// already ended.
        public func hangUp() {
            end(.hungUp)
        }

        // MARK: Ending

        /// How the session ended, or `nil` while it has not.
        public var ending: Ending? {
            state.withLock { $0.ending }
        }

        /// Waits until the session has ended, and returns how.
        public func waitForEnding() async -> Ending {
            await withCheckedContinuation { continuation in
                let ending = state.withLock { state -> Ending? in
                    if state.ending == nil {
                        state.waiters.append(continuation)
                    }
                    return state.ending
                }
                if let ending {
                    continuation.resume(returning: ending)
                }
            }
        }

        /// Waits for the shell's exit or the daemon's event, whichever comes first. The lease
        /// ends at once; the ending is reported once the output before it has been delivered,
        /// which waits for an output handler that blocks.
        private func watch(_ process: GuestProcess, events: EventRelay, machine: MachineID) async {
            let first = await SessionEnding.first(process: process, events: events, signals: nil)
            guard self.ending == nil else { return }
            let result: Ending
            do throws(MawError) {
                switch try await first.outcome(events: events, machine: machine) {
                case .exited(let status):
                    result = .exited(status)
                case .signal:
                    // Not reached: the session watches no signals.
                    result = .hungUp
                }
            } catch {
                result = .failed(error)
            }
            // A daemon event can arrive before the guest connection ends.
            process.hangUp()
            state.withLock { $0.client }?.close()
            _ = try? await process.waitForExit()
            end(result)
        }

        /// Records the first ending, then hangs the shell up, releases the lease, stops the
        /// input thread, and wakes every waiter. Later endings change nothing.
        private func end(_ ending: Ending) {
            let settled = state.withLock {
                state -> (DaemonClient?, GuestProcess?, [CheckedContinuation<Ending, Never>])? in
                guard state.ending == nil else { return nil }
                state.ending = ending
                defer { state.waiters = [] }
                return (state.client, state.process, state.waiters)
            }
            guard let (client, process, waiters) = settled else { return }
            if case .failed(let error) = ending {
                Logger.client.debug(
                    "a distribution session ended: \(error.description, privacy: .public)")
            }
            input.finish()
            process?.hangUp()
            client?.close()
            for waiter in waiters {
                waiter.resume(returning: ending)
            }
        }
    }

    /// Input on its way to a guest process. `append` never blocks; a thread of its own hands
    /// the input to `GuestProcess.write`, which blocks while `GuestProcess.inputLimit` bytes
    /// are queued. What waits here is what the user typed or pasted.
    final class InputForwarder: @unchecked Sendable {
        private let lock = ConditionLock()
        private var pending: [UInt8] = []
        private var isFinished = false

        func append(_ bytes: some Collection<UInt8>) {
            lock.withLock {
                guard !isFinished, !bytes.isEmpty else { return }
                pending.append(contentsOf: bytes)
                lock.broadcast()
            }
        }

        /// Drops what is pending and stops the thread.
        func finish() {
            lock.withLock {
                isFinished = true
                pending = []
                lock.broadcast()
            }
        }

        /// Starts the thread that writes to `process` until it ends or `finish()`. Returns
        /// false if the thread could not start.
        func start(writingTo process: GuestProcess) -> Bool {
            startDetachedThread { [self] in
                while let bytes = next(), process.write(bytes) {}
                finish()
            }
        }

        private func next() -> [UInt8]? {
            lock.withLock {
                while pending.isEmpty && !isFinished {
                    lock.wait()
                }
                guard !isFinished else { return nil }
                defer { pending = [] }
                return pending
            }
        }
    }
#endif
