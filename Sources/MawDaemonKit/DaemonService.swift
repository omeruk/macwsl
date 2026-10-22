#if os(macOS)
    import Darwin
    import MawCore
    import MawProtocol
    import MawXPC

    /// Serves the daemon's XPC interface (docs/daemon.md): one task per client connection,
    /// which handles that connection's requests in order and releases its session leases when
    /// the connection closes.
    public final class DaemonService<C: Clock>: Sendable where C.Duration == Duration {
        /// Why sessions end on `shutdown`; shown to their clients.
        static var shutdownReason: String { "maw --shutdown was run" }

        public let registry: MachineRegistry<C>
        public let lifetime: DaemonLifetime<C>
        private let clock: C
        private let started: C.Instant
        private let info: DaemonInfo
        private let canRunVirtualMachines: Bool
        private let log: DaemonLog

        public init(
            clock: C, registry: MachineRegistry<C>, lifetime: DaemonLifetime<C>,
            canRunVirtualMachines: Bool, log: DaemonLog = DaemonLog()
        ) {
            self.clock = clock
            self.registry = registry
            self.lifetime = lifetime
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
                    case .openSession(let machine):
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
                    }
                } catch {
                    reply = .failure(error)
                }
                send(reply, to: message, on: peer, descriptor: descriptor)
                descriptor?.close()
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
