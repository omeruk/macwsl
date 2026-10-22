#if os(macOS)
    import Dispatch
    import Foundation
    import MawCore
    import MawProtocol
    import Virtualization
    import os

    /// One Linux virtual machine.
    ///
    /// The actor's executor is the serial dispatch queue that its `VZVirtualMachine` was created
    /// with. Virtualization.framework requires every call to come from that queue, and actor
    /// isolation guarantees exactly that: every isolated method runs on the queue, and the
    /// framework's completion handlers and delegate callbacks arrive on it too.
    /// docs/decisions/0004-vm-actor-executor.md records the design.
    ///
    /// An instance boots once. To boot again, create a new instance.
    public actor VirtualMachine {
        public enum State: Sendable, Equatable {
            case stopped
            case starting
            case running
            case stopping
            case error(MawError)
        }

        /// How `stop(timeout:)` ended.
        public enum StopOutcome: Sendable, Equatable {
            /// The virtual machine was not running.
            case alreadyStopped
            /// The guest powered off after being asked to.
            case clean(after: Duration, via: StopRequest)
            /// The guest did not stop in time, or could not be asked to, and was stopped forcibly.
            case forced(after: Duration)
        }

        /// How the guest was asked to power off.
        public enum StopRequest: Sendable, Equatable, CustomStringConvertible {
            /// The guest agent's `shutdown` request.
            case agent
            /// Virtualization.framework's `requestStop()`, used when the agent cannot be reached.
            case stopRequest
            /// The guest powered off on its own while a request was outstanding.
            case guest

            public var description: String {
                switch self {
                case .agent: "the guest agent"
                case .stopRequest: "a stop request"
                case .guest: "the guest itself"
                }
            }
        }

        /// How long `stop(timeout:)` waits for a connection to the agent, which is normally
        /// already listening.
        static let agentShutdownConnectTimeout = Duration.seconds(1)
        /// How long `stop(timeout:)` waits for the agent to acknowledge `shutdown`.
        static let agentShutdownReplyTimeout = Duration.seconds(2)
        /// How often `connectToAgent(timeout:)` retries while the agent is not listening yet.
        static let agentConnectRetryInterval = Duration.milliseconds(20)

        /// Where the console's output goes besides the console log, and where its input comes
        /// from. With neither, the console is only logged.
        public struct ConsoleIO: Sendable {
            public var input: FileHandle?
            public var output: FileHandle?

            public init(input: FileHandle? = nil, output: FileHandle? = nil) {
                self.input = input
                self.output = output
            }
        }

        public nonisolated let name: String
        public nonisolated let configuration: VMConfiguration
        /// Every state change, in order. Finishes after the final `stopped` or `error` state.
        /// Bounded: a consumer that falls more than 32 changes behind loses the oldest.
        public nonisolated let states: AsyncStream<State>
        /// Lines of guest console output. Bounded; see `Console` for the back-pressure policy.
        public nonisolated var consoleLines: AsyncStream<String> { console.lines }
        public nonisolated var consoleLogURL: URL { console.logURL }

        public private(set) var state: State = .stopped

        private let queue: DispatchSerialQueue
        private let console: Console
        private let stateContinuation: AsyncStream<State>.Continuation
        private var machine: VZVirtualMachine?
        private var delegate: Delegate?
        private var hasStarted = false
        private var stopWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
        private let logger = Logger.virtualization

        public nonisolated var unownedExecutor: UnownedSerialExecutor {
            queue.asUnownedSerialExecutor()
        }

        public init(
            name: String,
            configuration: VMConfiguration,
            consoleIO: ConsoleIO = ConsoleIO(),
            consoleLineBufferLimit: Int = 1_000
        ) throws(MawError) {
            self.name = name
            self.configuration = configuration
            self.queue = DispatchSerialQueue(label: "dev.maw.vm.\(name)")
            self.console = try Console(
                logURL: configuration.consoleLogURL,
                output: consoleIO.output,
                input: consoleIO.input,
                lineBufferLimit: consoleLineBufferLimit)
            (states, stateContinuation) = AsyncStream.makeStream(
                of: State.self, bufferingPolicy: .bufferingNewest(32))
        }

        // MARK: Starting

        /// Boots the virtual machine. Returns once Virtualization.framework reports it running.
        public func start() async throws(MawError) {
            guard !hasStarted else {
                throw .vmStartFailed(reason: "this virtual machine has already been started once")
            }
            hasStarted = true
            guard VZVirtualMachine.isSupported else {
                throw finish(
                    .virtualizationUnavailable(
                        reason: "Virtualization.framework reports that it is not supported"))
            }

            let attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: console.toGuest.fileHandleForReading,
                fileHandleForWriting: console.fromGuest.fileHandleForWriting)
            let virtualizationConfiguration: VZVirtualMachineConfiguration
            do {
                virtualizationConfiguration = try configuration.makeVirtualizationConfiguration(
                    consoleAttachment: attachment)
            } catch {
                throw finish(error)
            }

            transition(to: .starting)
            console.start()
            let settings = configuration.clamped(to: .host)
            console.note(
                "starting \(name): \(settings.cpuCount) CPUs, \(settings.memorySize) memory, "
                    + "command line \"\(configuration.commandLine)\"")

            let machine = VZVirtualMachine(configuration: virtualizationConfiguration, queue: queue)
            let (events, eventContinuation) = AsyncStream.makeStream(of: Delegate.Event.self)
            let delegate = Delegate(events: eventContinuation)
            machine.delegate = delegate
            self.machine = machine
            self.delegate = delegate

            // Delegate callbacks arrive on the queue, outside any task. They are forwarded
            // through `events` and handled here, in order, isolated to the actor.
            Task {
                for await event in events {
                    handle(event)
                }
            }

            do {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, any Error>) in
                    machine.start { result in continuation.resume(with: result) }
                }
            } catch {
                throw finish(VirtualizationErrors.map(error, during: .start))
            }
            if state == .starting {
                transition(to: .running)
            }
        }

        // MARK: Stopping

        /// Stops the virtual machine, trying each of these in turn until the guest has stopped:
        ///
        /// 1. the guest agent's `shutdown` request, then up to `timeout` for the guest to power
        ///    off;
        /// 2. `requestStop()`, then up to `timeout` again;
        /// 3. a forced stop.
        ///
        /// The console log records which step stopped the guest, and why earlier steps did not.
        @discardableResult
        public func stop(timeout: Duration) async throws(MawError) -> StopOutcome {
            guard machine != nil, state == .running || state == .starting else {
                return .alreadyStopped
            }
            let clock = ContinuousClock()
            let start = clock.now
            transition(to: .stopping)

            // 1. The agent.
            var reasons: [String] = []
            do {
                try await agentClient(connectTimeout: Self.agentShutdownConnectTimeout)
                    .shutdown()
                if await waitForStop(timeout: timeout) {
                    return noteCleanStop(after: clock.now - start, via: .agent)
                }
                reasons.append(
                    "the guest did not stop within \(timeout.milliseconds) ms of the agent's "
                        + "acknowledgement")
            } catch {
                reasons.append("the agent could not be asked: \(error.description)")
            }
            guard let machine = self.machine else {
                return noteCleanStop(after: clock.now - start, via: .guest)
            }

            // 2. Virtualization.framework's stop request.
            var requested = false
            if machine.canRequestStop {
                do {
                    try machine.requestStop()
                    requested = true
                } catch {
                    reasons.append("the stop request failed: \(error.localizedDescription)")
                }
            } else {
                reasons.append("the virtual machine cannot accept a stop request")
            }
            if requested {
                if await waitForStop(timeout: timeout) {
                    console.note(
                        "shutdown: the agent was not used: \(reasons.joined(separator: "; "))")
                    return noteCleanStop(after: clock.now - start, via: .stopRequest)
                }
                reasons.append(
                    "the guest did not stop within \(timeout.milliseconds) ms of the stop request")
            }
            guard let machine = self.machine else {
                return noteCleanStop(after: clock.now - start, via: .guest)
            }

            // 3. Forced.
            let why = reasons.joined(separator: "; ")
            do {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, any Error>) in
                    machine.stop { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            } catch {
                throw finish(VirtualizationErrors.map(error, during: .stop))
            }
            let elapsed = clock.now - start
            console.note("shutdown: forced after \(elapsed.milliseconds) ms; \(why)")
            logger.notice(
                "\(self.name, privacy: .public): forced shutdown; \(why, privacy: .public)")
            didStop(.stopped)
            return .forced(after: elapsed)
        }

        /// Stops the virtual machine at once, without asking the guest, for a machine whose
        /// work is being thrown away, such as a cancelled installation's. Does nothing if it
        /// is not running.
        public func forceStop(reason: String) async {
            guard let machine, state == .running || state == .stopping else { return }
            let stopped: Bool = await withCheckedContinuation { continuation in
                machine.stop { error in
                    continuation.resume(returning: error == nil)
                }
            }
            guard stopped, self.machine != nil else { return }
            console.note("shutdown: forced at once because \(reason)")
            didStop(.stopped)
        }

        private func noteCleanStop(after elapsed: Duration, via request: StopRequest)
            -> StopOutcome
        {
            console.note("shutdown: clean after \(elapsed.milliseconds) ms via \(request)")
            return .clean(after: elapsed, via: request)
        }

        // MARK: Guest agent

        /// Opens a connection to the guest agent on vsock port `AgentProtocol.vsockPort`. While
        /// the agent is not listening yet, retries every 20 ms until `timeout` has passed.
        ///
        /// Returns the connection as a plain descriptor, which the caller owns. It does not
        /// depend on this instance, so that it can be handed to another process.
        public func connectToAgent(timeout: Duration) async throws(MawError)
            -> OwnedDescriptor
        {
            let deadline = ContinuousClock.now + timeout
            var lastFailure = "no attempt was made"
            while true {
                guard let machine, state == .running || state == .stopping,
                    let device = machine.socketDevices.first as? VZVirtioSocketDevice
                else {
                    throw .guestAgentUnavailable(reason: "the virtual machine is not running")
                }
                switch await connect(device, port: AgentProtocol.vsockPort, until: deadline) {
                case .success(let descriptor):
                    return OwnedDescriptor(descriptor)
                case .failure(let failure):
                    lastFailure = failure.reason
                }
                if ContinuousClock.now >= deadline {
                    throw .guestAgentUnavailable(
                        reason: "no connection to vsock port \(AgentProtocol.vsockPort) within "
                            + "\(timeout.milliseconds) ms; the last attempt failed: \(lastFailure)")
                }
                try? await Task.sleep(for: Self.agentConnectRetryInterval)
            }
        }

        /// A client for the guest agent whose connections come from `connectToAgent`.
        public nonisolated func agentClient(
            connectTimeout: Duration, replyTimeout: Duration = .seconds(10)
        ) -> GuestAgentClient {
            GuestAgentClient(replyTimeout: replyTimeout) { [self] () throws(MawError) in
                try await connectToAgent(timeout: connectTimeout)
            }
        }

        fileprivate struct ConnectFailure: Error {
            var reason: String
        }

        /// One connection attempt. Gives up at `deadline`, because the framework's completion
        /// handler may not run until the guest's vsock driver answers. A connection that
        /// arrives after that is closed. Isolated, because the device may only be used on the
        /// virtual machine's queue.
        private func connect(
            _ device: VZVirtioSocketDevice, port: UInt32, until deadline: ContinuousClock.Instant
        ) async -> Result<Int32, ConnectFailure> {
            let attempt = ConnectAttempt()
            return await withCheckedContinuation { continuation in
                attempt.setContinuation(continuation)
                device.connect(toPort: port) { result in
                    switch result {
                    case .success(let connection):
                        // The connection object closes its descriptor when it is closed or
                        // released; the caller gets a duplicate of its own.
                        let descriptor = dup(connection.fileDescriptor)
                        let code = errno
                        connection.close()
                        if descriptor < 0 {
                            attempt.resume(
                                .failure(
                                    ConnectFailure(reason: "dup: \(SystemError.message(for: code))")
                                ))
                        } else if !attempt.resume(.success(descriptor)) {
                            close(descriptor)
                        }
                    case .failure(let error):
                        attempt.resume(.failure(ConnectFailure(reason: error.localizedDescription)))
                    }
                }
                Task {
                    try? await Task.sleep(until: deadline)
                    attempt.resume(
                        .failure(ConnectFailure(reason: "the connection attempt timed out")))
                }
            }
        }

        /// Waits until the virtual machine has stopped and the console has passed on all output.
        public func waitUntilStopped() async {
            if machine != nil {
                _ = await waitForStop(timeout: nil)
            }
            await console.waitUntilDrained()
        }

        // MARK: State

        private func handle(_ event: Delegate.Event) {
            guard machine != nil else { return }
            switch event {
            case .guestDidStop:
                console.note("the guest powered off")
                didStop(.stopped)
            case .stoppedWithError(let error):
                console.note("the virtual machine stopped with an error: \(error.description)")
                didStop(.error(error))
            }
        }

        /// Enters a final state, wakes everyone waiting for the stop, and releases the machine.
        private func didStop(_ finalState: State) {
            transition(to: finalState)
            for waiter in stopWaiters.values {
                waiter.resume(returning: true)
            }
            stopWaiters.removeAll()
            machine?.delegate = nil
            machine = nil
            delegate?.events.finish()
            delegate = nil
            stateContinuation.finish()
            console.closeGuestSide()
        }

        /// Records a failure that ends this instance and returns it for throwing.
        private func finish(_ error: MawError) -> MawError {
            console.note("error: \(error.description)")
            if machine != nil {
                didStop(.error(error))
            } else {
                transition(to: .error(error))
                stateContinuation.finish()
                console.closeGuestSide()
            }
            return error
        }

        private func transition(to newState: State) {
            state = newState
            stateContinuation.yield(newState)
        }

        /// Waits until the machine stops, up to `timeout`. Returns whether it stopped.
        private func waitForStop(timeout: Duration?) async -> Bool {
            guard machine != nil else { return true }
            let id = UUID()
            if let timeout {
                Task {
                    try? await Task.sleep(for: timeout)
                    stopWaiters.removeValue(forKey: id)?.resume(returning: false)
                }
            }
            return await withCheckedContinuation { continuation in
                stopWaiters[id] = continuation
            }
        }
    }

    /// Resumes a connection attempt's continuation once: with the connection, the failure, or
    /// the timeout, whichever comes first.
    private final class ConnectAttempt: Sendable {
        private let state = OSAllocatedUnfairLock<
            CheckedContinuation<Result<Int32, VirtualMachine.ConnectFailure>, Never>?
        >(initialState: nil)

        func setContinuation(
            _ continuation: CheckedContinuation<Result<Int32, VirtualMachine.ConnectFailure>, Never>
        ) {
            state.withLock { $0 = continuation }
        }

        /// Returns false if the attempt had already been resumed.
        @discardableResult
        func resume(_ result: Result<Int32, VirtualMachine.ConnectFailure>) -> Bool {
            guard let continuation = state.withLock({ $0.take() }) else { return false }
            continuation.resume(returning: result)
            return true
        }
    }

    /// Receives Virtualization.framework callbacks on the virtual machine's queue and forwards
    /// them to the actor.
    private final class Delegate: NSObject, VZVirtualMachineDelegate {
        enum Event: Sendable {
            case guestDidStop
            case stoppedWithError(MawError)
        }

        let events: AsyncStream<Event>.Continuation

        init(events: AsyncStream<Event>.Continuation) {
            self.events = events
        }

        func guestDidStop(_ virtualMachine: VZVirtualMachine) {
            events.yield(.guestDidStop)
        }

        func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
            events.yield(.stoppedWithError(VirtualizationErrors.map(error, during: .run)))
        }
    }

#endif
