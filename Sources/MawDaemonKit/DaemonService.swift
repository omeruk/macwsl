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

        public let registry: MachineRegistry<C>
        public let lifetime: DaemonLifetime<C>
        /// The installed distributions, which resolve the default for a session.
        public let store: DistributionStore?
        public let installer: Installer?
        private let clock: C
        private let started: C.Instant
        private let info: DaemonInfo
        private let canRunVirtualMachines: Bool
        private let log: DaemonLog
        /// Every connection's running installation, so that the daemon can cancel them all when
        /// it stops. An installation that finishes before it is registered is remembered in
        /// `finished` until then.
        private let installations = OSAllocatedUnfairLock(
            initialState: (running: [UUID: Task<Void, Never>](), finished: Set<UUID>()))

        public init(
            clock: C, registry: MachineRegistry<C>, lifetime: DaemonLifetime<C>,
            canRunVirtualMachines: Bool, store: DistributionStore? = nil,
            installer: Installer? = nil, log: DaemonLog = DaemonLog()
        ) {
            self.clock = clock
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
            var installation: (id: UUID, task: Task<Void, Never>)?

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
                    case .cancelInstall:
                        let wasRunning = installation.map { isRunning($0.id) } ?? false
                        if let installation, wasRunning {
                            log.notice("process \(processID) cancelled its installation")
                            installation.task.cancel()
                            await installation.task.value
                        }
                        installation = nil
                        reply = .installCancelled(wasRunning: wasRunning)
                    }
                } catch {
                    reply = .failure(error)
                }
                send(reply, to: message, on: peer, descriptor: descriptor)
                descriptor?.close()
            }

            if let installation, isRunning(installation.id) {
                // The client went away: the installation stops and removes its traces.
                log.notice(
                    "process \(processID) closed its connection; cancelling its installation")
                installation.task.cancel()
                await installation.task.value
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
            if let requested {
                return requested
            }
            guard let name = store?.defaultDistribution() else {
                throw .noDistributionInstalled
            }
            return .distribution(name)
        }

        /// Runs an installation on a task of its own, so that this connection can still cancel
        /// it, and replies to `request` when it ends.
        private func startInstallation(
            _ install: InstallRequest, with installer: Installer, replyingTo request: XPCObject,
            on peer: XPCConnection
        ) -> (id: UUID, task: Task<Void, Never>) {
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
                await task.value
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
