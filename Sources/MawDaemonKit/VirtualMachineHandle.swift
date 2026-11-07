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
        /// How long the connection for a session's `dialBack` request may take.
        static let connectTimeout = Duration.seconds(5)
        /// How long `start()` waits for another virtual machine to release the disk.
        static let diskReleaseTimeout = Duration.seconds(10)

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

        /// The factory for the daemon's machines: the initramfs machine, and one machine per
        /// installed distribution, which boots its disk with systemd (decision record 0013).
        public static func factory(
            kernelDirectory: URL, logDirectory: URL, store: DistributionStore, log: DaemonLog,
            canRunVirtualMachines: Bool
        ) -> MachineFactory {
            { (machine: MachineID) throws(MawError) -> any MachineHandle in
                guard canRunVirtualMachines else {
                    throw .virtualizationEntitlementMissing
                }
                let guest = try GuestFiles(directory: kernelDirectory)
                var configuration = VMConfiguration(
                    kernelURL: guest.kernelURL,
                    initramfsURL: guest.initramfsURL,
                    consoleLogURL: MawPaths.consoleLogFile(
                        forMachineNamed: machine.name, in: logDirectory))
                if case .distribution(let name) = machine {
                    guard let metadata = try store.metadata(for: name), metadata.name == name else {
                        throw .distributionNotInstalled(name)
                    }
                    configuration = distributionConfiguration(
                        configuration, disk: store.paths.diskImage(for: name), metadata: metadata)
                }
                return try VirtualMachineHandle(
                    machine: machine, configuration: configuration, log: log)
            }
        }

        /// A distribution's machine: its disk as the root file system, NAT networking with its
        /// MAC address, every CPU and half the memory, and the clock set from the Mac's.
        static func distributionConfiguration(
            _ base: VMConfiguration, disk: URL, metadata: DistroMetadata,
            now: Date = Date()
        ) -> VMConfiguration {
            var configuration = base
            let resources = VMConfiguration.distributionResources()
            configuration.cpuCount = resources.cpuCount
            configuration.memorySize = resources.memorySize
            configuration.disks = [.init(url: disk)]
            configuration.network = .nat(macAddress: metadata.macAddress)
            configuration.commandLine = VMConfiguration.commandLine(
                appending: "maw.root=/dev/vda maw.clock=\(Int(now.timeIntervalSince1970))")
            return configuration
        }

        public func start() async throws(MawError) {
            let started = ContinuousClock.now
            // Two machines must never write one disk. Virtualization.framework refuses a
            // locked disk with an unhelpful error, so wait for, or name, the other holder.
            for disk in settings.disks where !disk.isReadOnly {
                if DiskImage.isLocked(disk.url) {
                    log.notice(
                        "\(machine): waiting for another virtual machine to release its disk")
                }
                try await DiskImage.waitUntilUnlocked(disk.url, timeout: Self.diskReleaseTimeout)
            }
            let rootCheck = watchRootFileSystemCheck()
            do throws(MawError) {
                try await virtualMachine.start()
                watchForUnexpectedStops()
                try await waitForAgent(rootCheck: rootCheck)
            } catch {
                rootCheck?.cancel()
                throw error
            }
            rootCheck?.cancel()
            log.notice(
                "\(machine): agent ready after \((ContinuousClock.now - started).milliseconds) ms")
        }

        public func openSessionConnection() async throws(MawError) -> OwnedDescriptor {
            try await virtualMachine.openSessionConnection(connectTimeout: Self.connectTimeout)
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

        /// Stops the machine at once, without asking the guest.
        public func forceStop(reason: String) async {
            stopRequested.withLock { $0 = true }
            await virtualMachine.forceStop(reason: reason)
            stopContinuation.finish()
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

        /// On a distribution's machine, follows the console until systemd starts, and returns
        /// the root file system check that the initramfs reported, if any.
        ///
        /// Nothing else reads a distribution machine's console lines. Cancelling the task ends
        /// the line stream, which no one needs once the agent has answered.
        private func watchRootFileSystemCheck() -> Task<RootFileSystemCheck?, Never>? {
            guard case .distribution = machine else { return nil }
            return Task { [lines = virtualMachine.consoleLines] in
                var scanner = RootFileSystemCheckScanner()
                for await line in lines {
                    scanner.read(line)
                    if scanner.isFinished { break }
                }
                return scanner.check
            }
        }

        /// The error for a guest that powered off before its agent answered: a failed root file
        /// system check if the initramfs reported one, and otherwise the error of guest files
        /// that report none, which also covers older ones.
        static func powerOffBeforeAgent(
            machine: MachineID, rootCheck: RootFileSystemCheck?, diskImage: URL?,
            consoleLog: URL
        ) -> MawError {
            if case .distribution(let name) = machine, let rootCheck, !rootCheck.allowsBoot,
                let diskImage
            {
                return .rootFileSystemCheckFailed(
                    distribution: name, e2fsckStatus: rootCheck.e2fsckStatus,
                    diskImage: diskImage.path(percentEncoded: false),
                    consoleLog: consoleLog.path(percentEncoded: false))
            }
            return .vmFailed(reason: "the guest powered off before its agent answered")
        }

        /// Retries `info` until the agent answers, the machine stops, or the deadline passes.
        private func waitForAgent(
            rootCheck: Task<RootFileSystemCheck?, Never>?
        ) async throws(MawError) {
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
                        // The console has passed on every line once the machine has stopped,
                        // and the watcher has read them all.
                        await virtualMachine.waitUntilStopped()
                        throw Self.powerOffBeforeAgent(
                            machine: machine, rootCheck: await rootCheck?.value,
                            diskImage: settings.disks.first?.url,
                            consoleLog: virtualMachine.consoleLogURL)
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
