#if os(macOS)
    import Foundation
    import MawCore
    import MawProtocol
    import MawVirtualization
    import MawXPC
    import os

    /// A `MachineHandle` backed by a real virtual machine.
    public final class VirtualMachineHandle: MachineHandle {
        /// How long `start()` waits for the guest agent after the virtual machine starts.
        static let agentReadyTimeout = Duration.seconds(30)
        /// How long `stop()` waits for the guest after each request to power off.
        static let stopTimeout = Duration.seconds(5)
        /// How long the connection for a session's `dialBack` request may take.
        static let connectTimeout = Duration.seconds(5)
        /// How long `sample()` waits for the connection, and then for the reply.
        static let sampleTimeout = Duration.seconds(1)
        /// How long `start()` waits for another virtual machine to release the disk.
        static let diskReleaseTimeout = Duration.seconds(10)

        public let machine: MachineID
        public let unexpectedStops: AsyncStream<String>
        public var cpuCount: Int { settings.cpuCount }
        public var memoryBytes: UInt64 { settings.memorySize.bytes }
        public var kernelRelease: String? { boot.withLock { $0.kernelRelease } }
        public var bootMilliseconds: UInt64? { boot.withLock { $0.milliseconds } }

        /// The share of the home directory, if the machine has one and its guest agent reported
        /// it mounted when it started. The Mac's path is the daemon's own, never the guest's.
        public var macShare: SharedDirectory? {
            guard boot.withLock({ $0.macShareMounted }),
                let share = settings.directoryShares.first(where: { $0.tag == MacShare.tag })
            else { return nil }
            return SharedDirectory(
                macPath: Self.displayPath(share.url), linuxPath: MacShare.linuxPath)
        }

        /// The distribution's `localhost` forwarding while its machine runs; `nil` before the
        /// agent answers, after the machine stops, and for the initramfs machine.
        public var forwarding: PortForwarding? {
            forwarder.withLock { $0 }?.forwarding
        }

        /// A directory's path without a trailing `/`, such as `/Users/ayse`.
        static func displayPath(_ url: URL) -> String {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }

        private let virtualMachine: VirtualMachine
        private let settings: VMConfiguration
        private let stopContinuation: AsyncStream<String>.Continuation
        private let stopRequested = OSAllocatedUnfairLock(initialState: false)
        /// Set by `stopForwarding()`: the machine is stopping or has stopped, by request or
        /// not, and no forwarder may start.
        private let forwardingEnded = OSAllocatedUnfairLock(initialState: false)
        private let boot = OSAllocatedUnfairLock(
            initialState: (
                kernelRelease: String?.none, milliseconds: UInt64?.none, macShareMounted: false
            ))
        private let log: DaemonLog
        /// For the measurements only: `sample()` sends `info` instead (`mawd serve
        /// --sample-with-info`).
        private let samplesWithInfo: Bool
        /// The ports that every distribution forwards; `nil` turns forwarding off, as for the
        /// initramfs machine and in tests.
        private let forwardedPorts: ForwardedPortRegistry?
        private let forwardingChanged: @Sendable () -> Void
        private let forwarder = OSAllocatedUnfairLock<PortForwarder?>(initialState: nil)
        /// The Mac's resolver for the distribution's DNS; `nil` turns DNS through the Mac off,
        /// as for the initramfs machine, in tests, and with `mawd serve --without-dns`.
        private let dnsResolver: (any SystemDNSResolving)?
        private let relay = OSAllocatedUnfairLock<DNSRelay?>(initialState: nil)

        public init(
            machine: MachineID, configuration: VMConfiguration, log: DaemonLog = DaemonLog(),
            samplesWithInfo: Bool = false, forwardedPorts: ForwardedPortRegistry? = nil,
            forwardingChanged: @escaping @Sendable () -> Void = {},
            dnsResolver: (any SystemDNSResolving)? = nil
        ) throws(MawError) {
            self.machine = machine
            self.dnsResolver = dnsResolver
            self.log = log
            self.samplesWithInfo = samplesWithInfo
            self.forwardedPorts = forwardedPorts
            self.forwardingChanged = forwardingChanged
            settings = configuration.clamped(to: .host)
            virtualMachine = try VirtualMachine(name: machine.name, configuration: configuration)
            (unexpectedStops, stopContinuation) = AsyncStream.makeStream(of: String.self)
        }

        /// The factory for the daemon's machines: the initramfs machine, and one machine per
        /// installed distribution, which boots its disk with systemd (decision record 0013) and
        /// mounts `macHome` at `/mnt/mac` (decision record 0021). `macHome` is `nil` only for
        /// the measurements (`mawd serve --without-mac-share`).
        public static func factory(
            kernelDirectory: URL, logDirectory: URL, store: DistributionStore, log: DaemonLog,
            canRunVirtualMachines: Bool, samplesWithInfo: Bool = false,
            macHome: URL?, forwardedPorts: ForwardedPortRegistry? = nil,
            forwardingChanged: @escaping @Sendable () -> Void = {},
            dnsResolver: (any SystemDNSResolving)? = nil
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
                        configuration, disk: store.paths.diskImage(for: name), metadata: metadata,
                        macHome: macHome)
                }
                return try VirtualMachineHandle(
                    machine: machine, configuration: configuration, log: log,
                    samplesWithInfo: samplesWithInfo, forwardedPorts: forwardedPorts,
                    forwardingChanged: forwardingChanged,
                    dnsResolver: machine == .initramfs ? nil : dnsResolver)
            }
        }

        /// A distribution's machine: its disk as the root file system, NAT networking with its
        /// MAC address, every CPU and half the memory, the clock set from the Mac's, and
        /// `macHome`, read-write, as the share that the initramfs mounts at `/mnt/mac`, with
        /// its path on the kernel command line (`maw.home`) for `mawpath`.
        static func distributionConfiguration(
            _ base: VMConfiguration, disk: URL, metadata: DistroMetadata, macHome: URL?,
            now: Date = Date()
        ) -> VMConfiguration {
            var configuration = base
            let resources = VMConfiguration.distributionResources()
            configuration.cpuCount = resources.cpuCount
            configuration.memorySize = resources.memorySize
            configuration.disks = [.init(url: disk)]
            configuration.network = .nat(macAddress: metadata.macAddress)
            var arguments = "maw.root=/dev/vda maw.clock=\(Int(now.timeIntervalSince1970))"
            if let macHome {
                configuration.directoryShares = [.init(url: macHome, tag: MacShare.tag)]
                arguments += " \(MacShare.commandLineArgument)"
                // For mawpath. A home directory too long to encode is left out, and mawpath
                // then says that it is not known.
                if let home = MacShare.homeCommandLineArgument(displayPath(macHome)) {
                    arguments += " \(home)"
                }
            }
            configuration.commandLine = VMConfiguration.commandLine(appending: arguments)
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
            let info: AgentInfo
            do throws(MawError) {
                try await virtualMachine.start()
                watchForUnexpectedStops()
                info = try await waitForAgent(rootCheck: rootCheck)
            } catch {
                rootCheck?.cancel()
                throw error
            }
            rootCheck?.cancel()
            let milliseconds = (ContinuousClock.now - started).milliseconds
            boot.withLock {
                $0 = (
                    ForegroundAnswer.displayableName(info.kernelRelease),
                    UInt64(max(0, milliseconds)),
                    info.macShareMounted
                )
            }
            log.notice("\(machine): agent ready after \(milliseconds) ms")
            if settings.directoryShares.contains(where: { $0.tag == MacShare.tag }) {
                log.notice(
                    info.macShareMounted
                        ? "\(machine): \(MacShare.linuxPath) is mounted"
                        : "\(machine): \(MacShare.linuxPath) is not mounted; its console log says why"
                )
            }
            await startDNS()
            await startForwarding()
        }

        /// Starts the distribution's DNS through the Mac before forwarding, so that the channel
        /// is open for the boot's first query. The relay opens its channel on a task of its own.
        private func startDNS() async {
            guard case .distribution = machine, let dnsResolver,
                !forwardingEnded.withLock({ $0 })
            else { return }
            let virtualMachine = self.virtualMachine
            let started = DNSRelay(
                machine: machine,
                environment: DNSRelay.Environment(
                    openChannel: { () throws(MawError) -> OwnedDescriptor in
                        try await virtualMachine.openSessionConnection(
                            connectTimeout: Self.connectTimeout)
                    }, resolver: dnsResolver),
                log: log, console: { virtualMachine.noteInConsole($0) })
            relay.withLock { $0 = started }
            await started.start()
            if forwardingEnded.withLock({ $0 }) {
                await stopDNS()
            }
        }

        private func stopDNS() async {
            let running = relay.withLock { current in
                defer { current = nil }
                return current
            }
            await running?.stop()
        }

        /// Starts the distribution's `localhost` forwarding, off the path of every session:
        /// the forwarder opens its channel on a task of its own.
        private func startForwarding() async {
            guard case .distribution = machine, let forwardedPorts,
                !forwardingEnded.withLock({ $0 })
            else { return }
            let virtualMachine = self.virtualMachine
            let started = PortForwarder(
                machine: machine,
                environment: PortForwarder.Environment(
                    openChannel: { () throws(MawError) -> OwnedDescriptor in
                        try await virtualMachine.openSessionConnection(
                            connectTimeout: Self.connectTimeout)
                    }, gate: virtualMachine.forwardingGate),
                registry: forwardedPorts, log: log, changed: forwardingChanged)
            forwarder.withLock { $0 = started }
            await started.start()
            // A stop that began meanwhile, requested or not, may have found no forwarder to
            // end: `stopForwarding()` sets the flag before it looks for one.
            if forwardingEnded.withLock({ $0 }) {
                await stopForwarding()
            }
        }

        /// Ends forwarding before the machine stops, so that its ports are free on the Mac at
        /// once and every forwarded connection is reset.
        private func stopForwarding() async {
            forwardingEnded.withLock { $0 = true }
            let running = forwarder.withLock { current in
                defer { current = nil }
                return current
            }
            await running?.stop()
        }

        public func openSessionConnection() async throws(MawError) -> OwnedDescriptor {
            try await virtualMachine.openSessionConnection(connectTimeout: Self.connectTimeout)
        }

        public func sample() async throws(MawError) -> GuestSample {
            let client = virtualMachine.agentClient(
                connectTimeout: Self.sampleTimeout, replyTimeout: Self.sampleTimeout)
            guard !samplesWithInfo else {
                // The cost of a request without reading the guest's figures; no figure results.
                _ = try await client.info()
                throw .guestAgentFailed(reason: "sample: replaced by info for a measurement")
            }
            return try await client.sample()
        }

        public func stop() async -> String {
            stopRequested.withLock { $0 = true }
            await stopForwarding()
            await stopDNS()
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
            await stopForwarding()
            await stopDNS()
            await virtualMachine.forceStop(reason: reason)
            stopContinuation.finish()
        }

        /// Reports a stop that `stop()` did not cause.
        private func watchForUnexpectedStops() {
            Task { [self, virtualMachine, stopRequested, stopContinuation] in
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
                await stopForwarding()
                await stopDNS()
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

        /// Retries `info` until the agent answers, the machine stops, or the deadline passes, and
        /// returns the agent's answer.
        private func waitForAgent(
            rootCheck: Task<RootFileSystemCheck?, Never>?
        ) async throws(MawError) -> AgentInfo {
            let deadline = ContinuousClock.now + Self.agentReadyTimeout
            let client = virtualMachine.agentClient(connectTimeout: .milliseconds(250))
            while true {
                do throws(MawError) {
                    return try await client.info()
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
