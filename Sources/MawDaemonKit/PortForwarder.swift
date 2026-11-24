#if os(macOS)
    import CMawSystem
    import Darwin
    import MawCore
    import MawProtocol
    import MawVirtualization
    import MawXPC
    import os

    /// One running distribution's `localhost` forwarding
    /// (docs/decisions/0023-localhost-forwarding.md): it keeps the machine's forwarding channel
    /// open, binds a port on the Mac's 127.0.0.1 and ::1 for each port on which the guest
    /// listens, and relays each connection that the Mac makes to it through a connection that
    /// the agent dials. It ends with its machine.
    ///
    /// The rules:
    /// - A port is tried once, when the guest reports it. A port that was not forwarded is
    ///   tried again only when the guest reports it anew, after it went away, or after a
    ///   restart of the machine; a periodic retry could take the port while a Mac program
    ///   restarts on it.
    /// - A port below 1024 is never bound; a port that is busy on either loopback address, or
    ///   forwarded for another distribution, is forwarded on neither.
    /// - Nothing from the guest chooses an address: the daemon listens on 127.0.0.1 and ::1
    ///   only, and a `connect` names only a port that the guest reported.
    public actor PortForwarder {
        /// What the forwarder needs from its machine. Tests supply their own.
        public struct Environment: Sendable {
            /// Opens a connection that the agent dialed, positioned before its version
            /// exchange: `VirtualMachine.openSessionConnection`.
            public var openChannel: @Sendable () async throws(MawError) -> OwnedDescriptor
            /// Admits the connections that the agent dials for forwarded connections.
            public var gate: DialBackGate
            /// Binds a port on both loopback addresses.
            var bind: @Sendable (UInt16) -> Result<LoopbackListeners, LoopbackListeners.Failure>
            /// How long after a channel ends, or fails to open, the next one is opened.
            public var reopenDelay: Duration
            /// Open forwarded connections, those still waiting for the agent's dial included.
            public var maximumConnections: Int
            public var maximumPorts: Int

            public init(
                openChannel: @escaping @Sendable () async throws(MawError) -> OwnedDescriptor,
                gate: DialBackGate, reopenDelay: Duration = .seconds(1),
                maximumConnections: Int = AgentProtocol.maximumForwardedConnections,
                maximumPorts: Int = PortForwarding.maximumPorts
            ) {
                self.openChannel = openChannel
                self.gate = gate
                self.bind = { LoopbackListeners.bind(port: $0) }
                self.reopenDelay = reopenDelay
                self.maximumConnections = maximumConnections
                self.maximumPorts = maximumPorts
            }
        }

        /// How long the channel's version exchange and first message may take.
        static let channelOpenTimeout = Duration.seconds(5)
        /// Log lines about ports, per machine, per `logInterval`; the rest are counted.
        static let logLines = 20
        static let logInterval = Duration.seconds(10)

        public nonisolated let machine: MachineID
        private let environment: Environment
        private let registry: ForwardedPortRegistry
        private let log: DaemonLog
        private let changed: @Sendable () -> Void
        private let published = OSAllocatedUnfairLock(initialState: PortForwarding())

        private var isStopped = false
        private var link: ChannelLink?
        private var acceptor: LoopbackAcceptor?
        private var channelTask: Task<Void, Never>?
        private var acceptTask: Task<Void, Never>?
        /// The guest's listening ports, each with the family the agent connects over.
        private var families: [UInt16: ForwardingConnect.Family] = [:]
        private var forwarded: Set<UInt16> = []
        private var notForwarded: [UInt16: PortForwarding.Reason] = [:]
        private var nextID: UInt32 = 1
        private var waiting: [UInt32: DialBackGate.Pending] = [:]
        private var relays: [UInt32: ByteRelay] = [:]
        private var openConnections = 0
        private var logWindow: (start: ContinuousClock.Instant, lines: Int, suppressed: Int)?

        public init(
            machine: MachineID, environment: Environment, registry: ForwardedPortRegistry,
            log: DaemonLog, changed: @escaping @Sendable () -> Void
        ) {
            self.machine = machine
            self.environment = environment
            self.registry = registry
            self.log = log
            self.changed = changed
        }

        /// The forwarding as it stands, for the snapshot.
        public nonisolated var forwarding: PortForwarding {
            published.withLock { $0 }
        }

        /// The open forwarded connections; for tests.
        var connectionCount: Int { openConnections }

        // MARK: Lifetime

        /// Starts accepting and opens the channel, and keeps it open until `stop()`.
        public func start() {
            guard !isStopped, channelTask == nil else { return }
            do {
                let acceptor = try LoopbackAcceptor()
                self.acceptor = acceptor
                acceptTask = Task { [weak self] in
                    for await (connection, port) in acceptor.connections {
                        await self?.accepted(connection, on: port)
                    }
                }
            } catch {
                log.error("\(machine): forwarding cannot start: \(error)")
                return
            }
            channelTask = Task { [weak self] in
                await self?.keepChannelOpen()
            }
        }

        /// Ends forwarding: closes the channel and every listening socket, releases every port,
        /// and resets every forwarded connection.
        public func stop() {
            guard !isStopped else { return }
            isStopped = true
            channelTask?.cancel()
            link?.close()
            link = nil
            acceptor?.stop()
            for port in forwarded {
                registry.release(port, for: machine)
            }
            forwarded = []
            notForwarded = [:]
            families = [:]
            for pending in waiting.values {
                environment.gate.cancel(pending)
            }
            waiting = [:]
            for relay in relays.values {
                relay.abort()
            }
            publish()
        }

        private func keepChannelOpen() async {
            while !isStopped && !Task.isCancelled {
                if let ending = await runChannel() {
                    // Rate-limited with the port lines: a channel that keeps ending must not
                    // fill the log once a second.
                    note("the forwarding channel ended: \(ending)")
                }
                guard !isStopped else { return }
                try? await Task.sleep(for: environment.reopenDelay)
            }
        }

        /// Opens a channel and serves it until it ends. Returns why it ended, or `nil` when the
        /// forwarder stopped.
        private func runChannel() async -> String? {
            let descriptor: OwnedDescriptor
            do {
                descriptor = try await environment.openChannel()
            } catch {
                return isStopped ? nil : "it could not be opened: \(error.description)"
            }
            let connection: FrameConnection
            do {
                connection = try await runOnDedicatedThread {
                    () throws(ConnectionError) -> FrameConnection in
                    let connection = try FrameConnection(descriptor)
                    let version = try connection.exchangeVersions(
                        until: .now + Self.channelOpenTimeout,
                        thenSending: [.control(.forwarding)])
                    guard version == ProtocolVersion.current else {
                        throw .versionMismatch(local: ProtocolVersion.current, remote: version)
                    }
                    return connection
                }
            } catch {
                descriptor.close()
                return isStopped ? nil : "it could not be opened: \(error)"
            }
            let (endings, endingContinuation) = AsyncStream.makeStream(
                of: ChannelLink.Ending.self)
            let link: ChannelLink
            do {
                link = try ChannelLink(connection: connection) { ending in
                    endingContinuation.yield(ending)
                    endingContinuation.finish()
                }
            } catch {
                connection.descriptor.close()
                return "it could not be served: \(error)"
            }
            guard !isStopped else {
                link.close()
                return nil
            }
            self.link = link
            for await frame in link.frames {
                do throws(ProtocolViolation) {
                    let message: ControlMessage
                    do throws(FrameError) {
                        message = try frame.controlMessage()
                    } catch {
                        throw ProtocolViolation(reason: error.description)
                    }
                    try handle(message)
                } catch {
                    // Nothing that the agent sent after the violation is acted on.
                    link.close()
                    note("closing the forwarding channel: \(error.reason)")
                    break
                }
            }
            if self.link === link {
                self.link = nil
            }
            // The agent no longer answers `connect`s sent on this channel.
            for pending in waiting.values {
                environment.gate.cancel(pending)
            }
            var ending = ChannelLink.Ending.closed
            for await value in endings {
                ending = value
            }
            if isStopped { return nil }
            switch ending {
            case .closed: return "it was closed"
            case .failed(let reason): return reason
            }
        }

        struct ProtocolViolation: Error {
            var reason: String
        }

        private func handle(_ message: ControlMessage) throws(ProtocolViolation) {
            switch message {
            case .listeners(let listeners):
                guest(listeners)
            case .connectFailed(let id, _):
                // The reason comes from the guest; it is not logged.
                if let pending = waiting[id] {
                    environment.gate.cancel(pending)
                }
            case .error(let error):
                throw ProtocolViolation(reason: "the agent refused it: \(error.code.rawValue)")
            default:
                throw ProtocolViolation(reason: "unexpected \(message.name)")
            }
        }

        // MARK: Ports

        /// Applies a report of the guest's listeners: forwards the ports that are new, and
        /// releases those that are gone.
        func guest(_ listeners: [GuestListener]) {
            guard !isStopped else { return }
            var reported: [UInt16: ForwardingConnect.Family] = [:]
            for listener in listeners {
                switch listener.address {
                case .anyIPv4, .loopbackIPv4:
                    reported[listener.port] = .ipv4
                case .anyIPv6, .loopbackIPv6:
                    if reported[listener.port] == nil { reported[listener.port] = .ipv6 }
                }
            }
            let previous = Set(families.keys)
            families = reported
            for port in previous.subtracting(reported.keys).sorted() {
                release(port)
            }
            for port in Set(reported.keys).subtracting(previous).sorted() {
                forward(port)
            }
            publish()
        }

        private func forward(_ port: UInt16) {
            guard forwarded.count < environment.maximumPorts else {
                refuse(port, .limit)
                return
            }
            guard port >= LoopbackListeners.firstUnprivilegedPort else {
                refuse(port, .privilegedOnMac)
                return
            }
            if let owner = registry.claim(port, for: machine) {
                refuse(port, .forwardedForAnotherDistribution, detail: "by \(owner)")
                return
            }
            switch environment.bind(port) {
            case .success(let listeners):
                forwarded.insert(port)
                acceptor?.add(listeners, for: port)
                note("localhost:\(port) is forwarded")
            case .failure(let failure):
                registry.release(port, for: machine)
                if case .other(let family, let code) = failure {
                    refuse(
                        port, .bindFailed,
                        detail: "binding \(family) failed: \(SystemError.message(for: code)) "
                            + "(errno \(code))")
                } else {
                    refuse(port, failure.reason)
                }
            }
        }

        private func refuse(_ port: UInt16, _ reason: PortForwarding.Reason, detail: String = "") {
            notForwarded[port] = reason
            note(
                "port \(port) is not forwarded: \(reason.rawValue)"
                    + (detail.isEmpty ? "" : ", \(detail)"))
        }

        private func release(_ port: UInt16) {
            notForwarded[port] = nil
            guard forwarded.remove(port) != nil else { return }
            acceptor?.remove(port)
            registry.release(port, for: machine)
            note("localhost:\(port) is no longer forwarded")
        }

        private func publish() {
            let forwarding = PortForwarding(
                forwarded: forwarded.sorted(),
                notForwarded: notForwarded.sorted { $0.key < $1.key }.map {
                    PortForwarding.NotForwarded(port: $0.key, reason: $0.value)
                })
            let isNew = published.withLock { current in
                defer { current = forwarding }
                return current != forwarding
            }
            if isNew { changed() }
        }

        /// Logs a line about ports, at most `logLines` per `logInterval`, so that a guest that
        /// opens and closes listeners quickly cannot fill `mawd.log`.
        private func note(_ message: String) {
            let now = ContinuousClock.now
            var window = logWindow ?? (now, 0, 0)
            if now - window.start >= Self.logInterval {
                if window.suppressed > 0 {
                    log.notice(
                        "\(machine): \(window.suppressed) more forwarding lines were not logged")
                }
                window = (now, 0, 0)
            }
            if window.lines < Self.logLines {
                window.lines += 1
                log.notice("\(machine): \(message)")
            } else {
                window.suppressed += 1
            }
            logWindow = window
        }

        // MARK: Connections

        private func accepted(_ connection: OwnedDescriptor, on port: UInt16) {
            guard !isStopped, forwarded.contains(port), let family = families[port],
                let link, openConnections < environment.maximumConnections
            else {
                Self.reset(connection)
                return
            }
            let pending: DialBackGate.Pending
            do {
                pending = try environment.gate.expect()
            } catch {
                Self.reset(connection)
                return
            }
            let id = nextID
            nextID &+= 1
            waiting[id] = pending
            openConnections += 1
            link.send(
                .control(
                    .connect(
                        ForwardingConnect(
                            id: id, port: port, family: family, nonce: pending.nonce))))
            let gate = environment.gate
            Task { [weak self] in
                let guest = await gate.connection(for: pending)
                await self?.connected(id, mac: connection, guest: guest)
            }
        }

        private func connected(_ id: UInt32, mac: OwnedDescriptor, guest: OwnedDescriptor?) {
            waiting[id] = nil
            guard let guest, !isStopped else {
                guest?.close()
                Self.reset(mac)
                openConnections -= 1
                return
            }
            let relay = ByteRelay.start(mac, guest) { [weak self] _ in
                Task { await self?.relayEnded(id) }
            }
            if let relay {
                relays[id] = relay
            } else {
                openConnections -= 1
            }
        }

        private func relayEnded(_ id: UInt32) {
            relays[id] = nil
            openConnections -= 1
        }

        /// Closes the Mac's connection with a reset, so that its client sees it fail at once.
        static func reset(_ connection: OwnedDescriptor) {
            _ = maw_set_reset_on_close(connection.rawValue)
            connection.close()
        }
    }
#endif
