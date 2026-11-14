#if os(macOS)
    import Darwin
    import Foundation
    import MawCore
    import MawProtocol
    import MawXPC
    import os

    /// Serves the daemon's XPC interface (docs/daemon.md): one task per client connection,
    /// which handles that connection's requests in order and releases its session leases when
    /// the connection closes.
    public final class DaemonService<C: Clock>: Sendable where C.Duration == Duration {
        /// Why sessions end on `shutdown`; shown to their clients.
        static var shutdownReason: String { "maw --shutdown was run" }
        /// Why sessions end on `terminate`; shown to their clients.
        static var terminateReason: String { "maw --terminate was run" }
        /// Why sessions end on `unregister`; shown to their clients.
        static var unregisterReason: String { "maw --unregister was run" }

        public let registry: MachineRegistry<C>
        public let lifetime: DaemonLifetime<C>
        /// The installed distributions, which resolve the names and the default.
        public let store: DistributionStore?
        public let installer: Installer?
        /// Samples the figures for `watchDistributions`.
        public let sampler: FigureSampler<C>?
        /// The names that installations, exports, and removals hold, shared with the installer
        /// and the registry.
        public let operations: DistributionOperations
        /// Where the machines' console logs are, whose distribution logs a removal deletes.
        /// `nil` in unit tests that have none.
        private let logDirectory: URL?
        private let clock: C
        private let started: C.Instant
        private let info: DaemonInfo
        private let canRunVirtualMachines: Bool
        private let log: DaemonLog
        /// Every connection's running installation, so that the daemon can cancel them all when
        /// it stops. An installation that finishes before it is registered is remembered in
        /// `finished` until then.
        private let installations = OSAllocatedUnfairLock(
            initialState: (running: [UUID: Task<Bool, Never>](), finished: Set<UUID>()))

        public init(
            clock: C, registry: MachineRegistry<C>, lifetime: DaemonLifetime<C>,
            canRunVirtualMachines: Bool, store: DistributionStore? = nil,
            installer: Installer? = nil, sampler: FigureSampler<C>? = nil,
            operations: DistributionOperations = DistributionOperations(),
            logDirectory: URL? = nil, log: DaemonLog = DaemonLog()
        ) {
            self.clock = clock
            self.operations = operations
            self.logDirectory = logDirectory
            self.sampler = sampler
            self.registry = registry
            self.lifetime = lifetime
            self.store = store
            self.installer = installer
            self.canRunVirtualMachines = canRunVirtualMachines
            self.log = log
            started = clock.now
            info = DaemonInfo(
                version: MawVersion.current, processID: getpid(),
                interfaceVersion: DaemonInterface.version)
        }

        /// Serves every peer the listener accepts, until it is cancelled.
        public func serve(_ listener: XPCServiceListener) async {
            await lifetime.begin()
            await withDiscardingTaskGroup { group in
                for await peer in listener.peers {
                    group.addTask { await self.serve(peer) }
                }
            }
        }

        /// Handles one connection until it closes.
        func serve(_ peer: XPCConnection) async {
            await lifetime.clientConnected()
            let processID = peer.peerProcessID
            var greeted = false
            var leases: [Lease] = []
            // This connection's installation; at most one at a time.
            var installation: (id: UUID, task: Task<Bool, Never>)?
            // Whether this connection watches the distributions, and its outstanding request.
            var watching = false
            var watch: Task<Void, Never>?
            let watchPending = OSAllocatedUnfairLock(initialState: false)

            for await event in peer.events {
                guard case .message(let message) = event else {
                    if case .invalidated = event { break }
                    continue
                }
                let reply: DaemonReply
                var descriptor: OwnedDescriptor?
                do throws(MawError) {
                    let request = try InterfaceCoding.decode(
                        DaemonRequest.self, from: message, as: .daemon)
                    let isHello = if case .hello = request { true } else { false }
                    guard greeted || isHello else {
                        throw .daemonProtocolError(
                            reason: "the first request on a connection must be hello")
                    }
                    switch request {
                    case .hello(let clientVersion):
                        greeted = true
                        if clientVersion != MawVersion.current {
                            log.notice(
                                "process \(processID) runs maw \(clientVersion); "
                                    + "this daemon is \(MawVersion.current)")
                        }
                        reply = .welcome(info)
                    case .openSession(let requested):
                        let machine = try resolve(requested)
                        let (lease, connection) = try await registry.openSession(on: machine) {
                            lease, reason in
                            Self.notify(peer, that: lease, ended: reason)
                        }
                        leases.append(lease)
                        descriptor = connection
                        log.notice("\(machine): session \(lease.id) opened by process \(processID)")
                        reply = .sessionOpened(SessionInfo(sessionID: lease.id, machine: machine))
                    case .status:
                        reply = .status(await status())
                    case .shutdown:
                        log.notice("shutdown requested by process \(processID)")
                        reply = .shutdownComplete(
                            await registry.shutdown(reason: Self.shutdownReason))
                    case .install(let request):
                        guard let installer else {
                            throw .notImplemented(feature: "--install", phase: "05")
                        }
                        if let installation, isRunning(installation.id) {
                            throw .daemonProtocolError(
                                reason: "this connection is already installing a distribution")
                        }
                        installation = startInstallation(
                            request, with: installer, replyingTo: message, on: peer)
                        continue
                    case .checkInstall(let distribution, let name):
                        guard let installer else {
                            throw .notImplemented(feature: "--install", phase: "05")
                        }
                        try await installer.check(distribution: distribution, name: name)
                        reply = .installPossible
                    case .cancel:
                        var wasCancelled = false
                        if let installation, isRunning(installation.id) {
                            log.notice("process \(processID) cancelled its installation")
                            installation.task.cancel()
                            // An installation that had already registered the distribution
                            // finishes regardless, and reports it as installed.
                            wasCancelled = !(await installation.task.value)
                        }
                        installation = nil
                        reply = .cancelled(wasRunning: wasCancelled)
                    case .listDistributions:
                        reply = .distributions(await distributions())
                    case .setDefault(let requested):
                        let name = try installedName(requested)
                        try refuseDuringRemoval(name)
                        try store?.setDefaultDistribution(name)
                        await sampler?.distributionsChanged()
                        log.notice("process \(processID) made \(name) the default distribution")
                        reply = .defaultSet(name)
                    case .terminate(let requested):
                        let name = try installedName(requested)
                        try refuseDuringRemoval(name)
                        let machine = MachineID.distribution(name)
                        log.notice("\(machine): terminate requested by process \(processID)")
                        reply = .terminated(
                            await registry.terminate(machine, reason: Self.terminateReason))
                    case .watchDistributions(let after):
                        guard let sampler else {
                            throw .notImplemented(
                                feature: "watching the distributions", phase: "11c")
                        }
                        guard !watchPending.withLock({ $0 }) else {
                            throw .daemonProtocolError(
                                reason: "this connection already waits for a distribution snapshot")
                        }
                        // A connection's first watch is answered at once: its `after` may come from
                        // an earlier daemon process, whose sequence numbers this one does not know.
                        let after = watching ? after : 0
                        if !watching {
                            watching = true
                            log.notice("process \(processID) started watching the distributions")
                            await sampler.addWatcher()
                        }
                        watchPending.withLock { $0 = true }
                        // On a task of its own, so that this loop still sees the connection close.
                        watch = Task {
                            guard let snapshot = await sampler.snapshot(after: after) else {
                                return
                            }
                            watchPending.withLock { $0 = false }
                            self.send(
                                .distributionSnapshot(snapshot), to: message, on: peer,
                                descriptor: nil)
                        }
                        continue
                    case .checkUnregister(let requested):
                        let name = try installedName(requested)
                        try operations.check(name, for: .removal)
                        reply = .unregisterPossible(name)
                    case .unregister(let requested):
                        reply = .unregistered(try await unregister(requested, for: processID))
                    case .checkExport, .export:
                        throw .notImplemented(feature: "--export", phase: "06b")
                    }
                } catch {
                    reply = .failure(error)
                }
                send(reply, to: message, on: peer, descriptor: descriptor)
                descriptor?.close()
            }

            watch?.cancel()
            if watching, let sampler {
                await sampler.removeWatcher()
                log.notice("process \(processID) stopped watching the distributions")
            }
            if let installation, isRunning(installation.id) {
                // The client went away: the installation stops and removes its traces.
                log.notice(
                    "process \(processID) closed its connection; cancelling its installation")
                installation.task.cancel()
                _ = await installation.task.value
            }
            for lease in leases {
                await registry.release(lease)
            }
            if !leases.isEmpty {
                log.notice(
                    "process \(processID) closed its connection; released \(leases.count) "
                        + (leases.count == 1 ? "session" : "sessions"))
            }
            await lifetime.clientDisconnected()
        }

        /// The machine a session runs on: the requested one, or the default distribution's.
        func resolve(_ requested: MachineID?) throws(MawError) -> MachineID {
            if case .distribution(let name) = requested, store != nil {
                // The machine must carry the stored spelling, or one disk would get two machines.
                return .distribution(try installedName(name))
            }
            if let requested {
                return requested
            }
            guard let name = store?.defaultDistribution() else {
                throw .noDistributionInstalled
            }
            return .distribution(name)
        }

        /// The stored spelling of the installed distribution that `name` names without regard
        /// to case. Without a store, nothing is installed.
        func installedName(_ name: DistroName) throws(MawError) -> DistroName {
            guard let metadata = try store?.installedDistribution(named: name) else {
                throw .distributionNotInstalled(name)
            }
            return metadata.name
        }

        /// Throws `distributionBusy` while a removal holds `name`: every request that names a
        /// distribution being removed fails until the removal is done.
        private func refuseDuringRemoval(_ name: DistroName) throws(MawError) {
            if operations.operation(on: name) == .removal {
                throw .distributionBusy(name, operation: .removal)
            }
        }

        // MARK: Removal

        /// Removes the installed distribution that `requested` names (docs/daemon.md,
        /// "Removing a distribution"): stops its machine, ending its sessions with
        /// `unregisterReason`, moves its directory into the staging directory, which is the
        /// moment it stops being installed, clears the default if `state.json` names it,
        /// deletes its logs, and then the moved directory. Nothing after the move is undone or
        /// interrupted; a directory that the daemon could not delete is removed at its next
        /// start.
        func unregister(_ requested: DistroName, for processID: Int32) async throws(MawError)
            -> UnregisterSummary
        {
            let name = try installedName(requested)
            guard let store else { throw .distributionNotInstalled(requested) }
            let claim = try operations.claim(name, for: .removal)
            defer { operations.release(claim) }
            log.notice("\(name): removal requested by process \(processID)")
            let defaultBefore = store.defaultDistribution()

            let machine = MachineID.distribution(name)
            let stopped = await registry.terminate(machine, reason: Self.unregisterReason)
            let moved: URL
            do throws(MawError) {
                moved = try store.moveForRemoval(name)
            } catch {
                log.error("\(name): removal for process \(processID) failed: \(error.description)")
                throw error
            }
            // From here on the distribution is not installed.
            do throws(MawError) {
                try store.clearDefaultDistribution(ifItNames: name)
            } catch {
                log.error("\(name): the default could not be cleared: \(error.description)")
            }
            if let logDirectory {
                for file in MawPaths.distributionLogFiles(for: name, in: logDirectory) {
                    removeLog(file, of: name)
                }
            }
            store.removeStagingDirectory(moved)
            let leftOver = FileManager.default.fileExists(atPath: moved.path(percentEncoded: false))
            await sampler?.distributionsChanged()

            let defaultAfter = store.defaultDistribution()
            let newDefault = defaultBefore == name ? defaultAfter : nil
            log.notice(
                "\(name): removed for process \(processID); "
                    + (stopped.wasRunning
                        ? "its machine was stopped and \(stopped.endedSessions) "
                            + (stopped.endedSessions == 1 ? "session" : "sessions") + " ended"
                        : "its machine was not running")
                    + (leftOver ? "; \(moved.lastPathComponent) is removed at the next start" : "")
                    + (newDefault.map { "; \($0) is now the default" } ?? ""))
            return UnregisterSummary(
                name: name, newDefault: newDefault, endedSessions: stopped.endedSessions)
        }

        /// Deletes one of a removed distribution's logs. A log that does not exist is not an
        /// error; one that cannot be deleted is logged and left.
        private func removeLog(_ file: URL, of name: DistroName) {
            let path = file.path(percentEncoded: false)
            guard unlink(path) == 0 || errno == ENOENT else {
                log.error(
                    "\(name): \(file.lastPathComponent) could not be deleted: "
                        + SystemError("unlink").description)
                return
            }
        }

        /// Every installed distribution with its machine's state, and the default.
        func distributions() async -> DistributionList {
            guard let store else {
                return DistributionList(distributions: [], defaultDistribution: nil)
            }
            var states: [DistroName: DistributionState] = [:]
            for machine in await registry.status() {
                guard case .distribution(let name) = machine.machine else { continue }
                states[name] = DistributionState(machine.state)
            }
            let entries = store.installed().map {
                DistributionEntry(name: $0.name, state: states[$0.name] ?? .stopped)
            }
            return DistributionList(
                distributions: entries, defaultDistribution: store.defaultDistribution())
        }

        /// Runs an installation on a task of its own, so that this connection can still cancel
        /// it, and replies to `request` when it ends.
        private func startInstallation(
            _ install: InstallRequest, with installer: Installer, replyingTo request: XPCObject,
            on peer: XPCConnection
        ) -> (id: UUID, task: Task<Bool, Never>) {
            let id = UUID()
            let task = Task {
                defer {
                    installations.withLock {
                        if $0.running.removeValue(forKey: id) == nil {
                            $0.finished.insert(id)
                        }
                    }
                }
                let reply: DaemonReply
                do throws(MawError) {
                    let summary = try await installer.install(install) { progress in
                        if let object = try? InterfaceCoding.encode(
                            DaemonEvent.installProgress(progress))
                        {
                            peer.send(object)
                        }
                    }
                    reply = .installed(summary)
                } catch {
                    reply = .failure(error)
                }
                self.send(reply, to: request, on: peer, descriptor: nil)
                guard case .installed = reply else { return false }
                await self.sampler?.distributionsChanged()
                return true
            }
            installations.withLock {
                if $0.finished.remove(id) == nil {
                    $0.running[id] = task
                }
            }
            return (id, task)
        }

        /// Whether the installation `id` has not finished yet.
        private func isRunning(_ id: UUID) -> Bool {
            installations.withLock { $0.running[id] != nil }
        }

        /// Cancels every installation and waits until each has removed its traces.
        public func cancelInstallations() async {
            let running = installations.withLock { Array($0.running.values) }
            for task in running {
                task.cancel()
            }
            for task in running {
                _ = await task.value
            }
        }

        func status() async -> DaemonStatus {
            DaemonStatus(
                daemon: info,
                uptimeMilliseconds: UInt64(max(0, started.duration(to: clock.now).milliseconds)),
                canRunVirtualMachines: canRunVirtualMachines,
                machines: await registry.status())
        }

        private func send(
            _ reply: DaemonReply, to request: XPCObject, on peer: XPCConnection,
            descriptor: OwnedDescriptor?
        ) {
            do throws(MawError) {
                if let object = try InterfaceCoding.encodeReply(
                    to: request, reply, descriptor: descriptor?.rawValue)
                {
                    peer.send(object)
                }
            } catch {
                log.error("a reply could not be encoded: \(error.description)")
            }
        }

        private static func notify(_ peer: XPCConnection, that lease: Lease, ended reason: String) {
            let event = DaemonEvent.sessionEnded(
                SessionEnded(sessionID: lease.id, machine: lease.machine, reason: reason))
            if let object = try? InterfaceCoding.encode(event) {
                peer.send(object)
            }
        }
    }
#endif
