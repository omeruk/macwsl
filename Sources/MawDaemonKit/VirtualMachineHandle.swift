#if os(macOS)
    import Foundation
    import MawCore
    import MawProtocol
    import MawVirtualization
    import os

    /// A `MachineHandle` backed by a real virtual machine.
    public final class VirtualMachineHandle: MachineHandle {
        /// How long `start()` waits for the guest agent after the virtual machine starts.
        static let agentReadyTimeout = Duration.seconds(30)
        /// How long `stop()` waits for the guest after each request to power off.
        static let stopTimeout = Duration.seconds(5)
        /// How long a session's connection to a running agent may take.
        static let connectTimeout = Duration.seconds(5)

        public let machine: MachineID
        public let unexpectedStops: AsyncStream<String>
        public var cpuCount: Int { settings.cpuCount }
        public var memoryBytes: UInt64 { settings.memorySize.bytes }

        private let virtualMachine: VirtualMachine
        private let settings: VMConfiguration
        private let stopContinuation: AsyncStream<String>.Continuation
        private let stopRequested = OSAllocatedUnfairLock(initialState: false)
        private let log: DaemonLog

        public init(
            machine: MachineID, configuration: VMConfiguration, log: DaemonLog = DaemonLog()
        ) throws(MawError) {
            self.machine = machine
            self.log = log
            settings = configuration.clamped(to: .host)
            virtualMachine = try VirtualMachine(name: machine.name, configuration: configuration)
            (unexpectedStops, stopContinuation) = AsyncStream.makeStream(of: String.self)
        }

        /// The factory for the daemon's machines. Until phase 05 only the initramfs machine
        /// exists; a distribution has no disk to boot yet.
        public static func factory(
            kernelDirectory: URL, logDirectory: URL, log: DaemonLog,
            canRunVirtualMachines: Bool
        ) -> MachineFactory {
            { (machine: MachineID) throws(MawError) -> any MachineHandle in
                guard canRunVirtualMachines else {
                    throw .virtualizationEntitlementMissing
                }
                switch machine {
                case .initramfs:
                    break
                case .distribution(let name):
                    throw .distributionNotInstalled(name)
                }
                let guest = try GuestFiles(directory: kernelDirectory)
                let configuration = VMConfiguration(
                    kernelURL: guest.kernelURL,
                    initramfsURL: guest.initramfsURL,
                    consoleLogURL: logDirectory.appending(path: "\(machine.name).log"))
                return try VirtualMachineHandle(
                    machine: machine, configuration: configuration, log: log)
            }
        }

        public func start() async throws(MawError) {
            let started = ContinuousClock.now
            try await virtualMachine.start()
            watchForUnexpectedStops()
            try await waitForAgent()
            log.notice(
                "\(machine): agent ready after \((ContinuousClock.now - started).milliseconds) ms")
        }

        public func connectToAgent() async throws(MawError) -> OwnedDescriptor {
            try await virtualMachine.connectToAgent(timeout: Self.connectTimeout)
        }

        public func stop() async -> String {
            stopRequested.withLock { $0 = true }
            let description: String
            do {
                switch try await virtualMachine.stop(timeout: Self.stopTimeout) {
                case .alreadyStopped:
                    description = "it had already stopped"
                case .clean(let elapsed, let request):
                    description = "shutdown: clean after \(elapsed.milliseconds) ms via \(request)"
                case .forced(let elapsed):
                    description = "shutdown: forced after \(elapsed.milliseconds) ms"
                }
            } catch {
                description = "the stop failed: \(error.description)"
            }
            await virtualMachine.waitUntilStopped()
            stopContinuation.finish()
            return description
        }

        /// Reports a stop that `stop()` did not cause.
        private func watchForUnexpectedStops() {
            Task { [virtualMachine, stopRequested, stopContinuation] in
                var reason: String?
                for await state in virtualMachine.states {
                    switch state {
                    case .stopped:
                        reason = "the guest powered off"
                    case .error(let error):
                        reason = error.description
                    case .starting, .running, .stopping:
                        continue
                    }
                    break
                }
                if let reason, !stopRequested.withLock({ $0 }) {
                    stopContinuation.yield(reason)
                }
                stopContinuation.finish()
            }
        }

        /// Retries `info` until the agent answers, the machine stops, or the deadline passes.
        private func waitForAgent() async throws(MawError) {
            let deadline = ContinuousClock.now + Self.agentReadyTimeout
            let client = virtualMachine.agentClient(connectTimeout: .milliseconds(250))
            while true {
                do throws(MawError) {
                    _ = try await client.info()
                    return
                } catch {
                    let state = await virtualMachine.state
                    if case .error(let failure) = state {
                        throw failure
                    }
                    if state == .stopped {
                        throw .vmFailed(reason: "the guest powered off before its agent answered")
                    }
                    guard case .guestAgentUnavailable = error, ContinuousClock.now < deadline
                    else {
                        _ = await stop()
                        throw error
                    }
                }
            }
        }
    }
#endif
