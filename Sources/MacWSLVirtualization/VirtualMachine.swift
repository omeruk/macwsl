#if os(macOS)
    import Dispatch
    import Foundation
    import MacWSLCore
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
            case error(MacWSLError)
        }

        /// How `stop(timeout:)` ended.
        public enum StopOutcome: Sendable, Equatable {
            /// The virtual machine was not running.
            case alreadyStopped
            /// The guest powered off after the stop request.
            case clean(after: Duration)
            /// The guest did not stop in time, or could not be asked to, and was stopped forcibly.
            case forced(after: Duration)
        }

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
        ) throws(MacWSLError) {
            self.name = name
            self.configuration = configuration
            self.queue = DispatchSerialQueue(label: "dev.macwsl.vm.\(name)")
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
        public func start() async throws(MacWSLError) {
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

        /// Stops the virtual machine. First asks the guest to power off (`requestStop()`); if it
        /// has not stopped within `timeout`, stops it forcibly and records that in the console
        /// log.
        @discardableResult
        public func stop(timeout: Duration) async throws(MacWSLError) -> StopOutcome {
            guard let machine, state == .running || state == .starting else {
                return .alreadyStopped
            }
            let clock = ContinuousClock()
            let start = clock.now
            transition(to: .stopping)

            var requested = false
            if machine.canRequestStop {
                do {
                    try machine.requestStop()
                    requested = true
                } catch {
                    logger.notice("\(self.name, privacy: .public): stop request failed: \(error)")
                }
            }
            if requested, await waitForStop(timeout: timeout) {
                let elapsed = clock.now - start
                console.note("shutdown: clean after \(elapsed.milliseconds) ms")
                return .clean(after: elapsed)
            }
            guard self.machine != nil else {
                // The guest stopped on its own while the request was outstanding.
                return .clean(after: clock.now - start)
            }

            let why =
                requested
                ? "the guest did not stop within \(timeout.milliseconds) ms of the stop request"
                : "the guest could not be asked to stop"
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
        private func finish(_ error: MacWSLError) -> MacWSLError {
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

    /// Receives Virtualization.framework callbacks on the virtual machine's queue and forwards
    /// them to the actor.
    private final class Delegate: NSObject, VZVirtualMachineDelegate {
        enum Event: Sendable {
            case guestDidStop
            case stoppedWithError(MacWSLError)
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
