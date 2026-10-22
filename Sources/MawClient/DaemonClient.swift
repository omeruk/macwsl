#if os(macOS)
    import Foundation
    import MawCore
    import MawProtocol
    import MawXPC
    import os

    /// A connection to `mawd`. It checks the interface version on connecting and maps every
    /// failure to a `MawError`. It has no AppKit dependency, so that the terminal app can use
    /// it as well as the command line.
    ///
    /// A session opened through a client lasts until the client is closed or its process
    /// exits: the daemon ties each session lease to the XPC connection that opened it.
    public final class DaemonClient: Sendable {
        /// What the daemon tells the client without being asked.
        public enum Event: Sendable, Equatable {
            /// A session's machine stopped.
            case sessionEnded(SessionEnded)
            /// This connection's installation moved on.
            case installProgress(InstallProgress)
            /// The daemon exited or closed the connection.
            case connectionLost
        }

        public let label: String
        /// The daemon's reply to `hello`.
        public let daemon: DaemonInfo
        /// Every event, in order. Finishes when the connection ends.
        public let events: AsyncStream<Event>

        private let connection: XPCConnection
        private let state: OSAllocatedUnfairLock<ConnectionState>

        private init(
            label: String, daemon: DaemonInfo, connection: XPCConnection,
            events: AsyncStream<Event>, state: OSAllocatedUnfairLock<ConnectionState>
        ) {
            self.label = label
            self.daemon = daemon
            self.connection = connection
            self.events = events
            self.state = state
        }

        deinit {
            connection.cancel()
        }

        /// Connects to the daemon's Mach service, which makes launchd start it if it is not
        /// running, and exchanges `hello`.
        ///
        /// - Parameter checkSignature: Whether to check first that this process is signed
        ///   as the daemon requires (see `PeerRequirement`).
        public static func connect(
            label: String = DaemonInterface.label(), paths: MawPaths = MawPaths(),
            checkSignature: Bool = true
        ) async throws(MawError) -> DaemonClient {
            if checkSignature {
                try PeerRequirement.checkCurrentProcess()
            }
            return try await connect(
                over: XPCConnection(machService: label), label: label, paths: paths)
        }

        /// Connects over `connection`, which is not active yet. The unit tests pass a
        /// connection to an anonymous listener.
        public static func connect(
            over connection: XPCConnection, label: String, paths: MawPaths = MawPaths()
        ) async throws(MawError) -> DaemonClient {
            let (events, continuation) = AsyncStream.makeStream(of: Event.self)
            let state = OSAllocatedUnfairLock(initialState: ConnectionState())
            Task {
                for await event in connection.events {
                    switch event {
                    case .message(let message):
                        switch try? InterfaceCoding.decode(
                            DaemonEvent.self, from: message, as: .client)
                        {
                        case .sessionEnded(let ended):
                            continuation.yield(.sessionEnded(ended))
                        case .installProgress(let progress):
                            continuation.yield(.installProgress(progress))
                        case nil:
                            break
                        }
                    case .interrupted, .invalidated:
                        // After an interruption, libxpc would send the next request to a new
                        // daemon process, which knows neither this client nor its sessions.
                        // The connection ends here instead.
                        let wasClosed = state.withLock { state in
                            defer { state.isLost = true }
                            return state.isClosed || state.isLost
                        }
                        connection.cancel()
                        if !wasClosed {
                            continuation.yield(.connectionLost)
                        }
                    }
                }
                continuation.finish()
            }
            connection.activate()

            let hello = DaemonRequest.hello(clientVersion: MawVersion.current)
            let message = try InterfaceCoding.encode(hello)
            let reply: DaemonReply
            switch await connection.request(message) {
            case .success(let object):
                reply = try InterfaceCoding.decode(DaemonReply.self, from: object, as: .client)
            case .failure(.invalidated):
                connection.cancel()
                throw unavailable(label: label, paths: paths)
            case .failure(.interrupted):
                connection.cancel()
                throw .daemonUnreachable(reason: "it exited before it answered")
            }
            switch reply {
            case .welcome(let info):
                return DaemonClient(
                    label: label, daemon: info, connection: connection, events: events,
                    state: state)
            case .failure(let error):
                connection.cancel()
                throw error
            default:
                connection.cancel()
                throw .daemonProtocolError(reason: "the reply to hello is not welcome")
            }
        }

        /// Why the first message found no service: the LaunchAgent is not installed or not
        /// loaded, or launchd refused the connection.
        static func unavailable(label: String, paths: MawPaths) -> MawError {
            let plist = paths.launchAgentFile(label: label).path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: plist), Launchctl.isLoaded(label) else {
                return .daemonNotInstalled(label: label)
            }
            return .daemonUnreachable(reason: "launchd refused the connection to \(label)")
        }

        // MARK: Requests

        /// Starts the machine if needed and returns a connection to its guest agent. `nil` is the
        /// default distribution's machine. The session lasts until this client is closed.
        public func openSession(on machine: MachineID?) async throws(MawError) -> DaemonSession {
            let request = DaemonRequest.openSession(machine)
            let (reply, object) = try await send(request)
            guard case .sessionOpened(let info) = reply else {
                throw .daemonProtocolError(reason: "the reply to openSession is not sessionOpened")
            }
            guard let descriptor = InterfaceCoding.descriptor(in: object) else {
                throw .daemonProtocolError(reason: "sessionOpened carries no descriptor")
            }
            return DaemonSession(info: info, agentConnection: descriptor)
        }

        public func status() async throws(MawError) -> DaemonStatus {
            guard case .status(let status) = try await send(.status).reply else {
                throw .daemonProtocolError(reason: "the reply to status is not status")
            }
            return status
        }

        /// Stops every machine and ends their sessions.
        public func shutdown() async throws(MawError) -> ShutdownSummary {
            guard case .shutdownComplete(let summary) = try await send(.shutdown).reply else {
                throw .daemonProtocolError(reason: "the reply to shutdown is not shutdownComplete")
            }
            return summary
        }

        /// Installs a distribution and returns when it is installed. `events` carries its
        /// progress meanwhile. Closing the client, or `cancelInstall()`, cancels it.
        public func install(_ request: InstallRequest) async throws(MawError) -> InstallSummary {
            guard case .installed(let summary) = try await send(.install(request)).reply else {
                throw .daemonProtocolError(reason: "the reply to install is not installed")
            }
            return summary
        }

        /// Cancels this client's installation and returns once the daemon has removed its
        /// traces. Returns whether one was running.
        @discardableResult
        public func cancelInstall() async throws(MawError) -> Bool {
            guard case .installCancelled(let wasRunning) = try await send(.cancelInstall).reply
            else {
                throw .daemonProtocolError(
                    reason: "the reply to cancelInstall is not installCancelled")
            }
            return wasRunning
        }

        /// Closes the connection, which ends its sessions.
        public func close() {
            state.withLock { $0.isClosed = true }
            connection.cancel()
        }

        private func send(_ request: DaemonRequest) async throws(MawError) -> (
            reply: DaemonReply, object: XPCObject
        ) {
            let message = try InterfaceCoding.encode(request)
            guard !state.withLock({ $0.isLost || $0.isClosed }),
                case .success(let object) = await connection.request(message)
            else {
                throw .daemonConnectionLost(during: request.displayName)
            }
            let reply = try InterfaceCoding.decode(DaemonReply.self, from: object, as: .client)
            if case .failure(let error) = reply {
                throw error
            }
            return (reply, object)
        }

        // MARK: Without connecting

        /// Whether the daemon runs, judged by its lock, without starting it.
        public static func isRunning(
            label: String = DaemonInterface.label(), paths: MawPaths = MawPaths()
        ) -> Bool {
            DaemonLock.isHeld(at: paths.daemonLockFile(label: label))
        }

        /// Whether the LaunchAgent's plist exists.
        public static func isInstalled(
            label: String = DaemonInterface.label(), paths: MawPaths = MawPaths()
        ) -> Bool {
            FileManager.default.fileExists(
                atPath: paths.launchAgentFile(label: label).path(percentEncoded: false))
        }
    }

    struct ConnectionState {
        /// Set by `close()`, so that the event task does not report the closing as a loss.
        var isClosed = false
        /// Set when the daemon exits or closes the connection.
        var isLost = false
    }

    /// A session opened by `DaemonClient.openSession(on:)`.
    public struct DaemonSession: Sendable {
        public let info: SessionInfo
        /// The connection to the guest agent, for `GuestAgentClient`.
        public let agentConnection: OwnedDescriptor

        /// A client for the guest agent that runs one request over `agentConnection`.
        public func agentClient() -> GuestAgentClient {
            let connection = agentConnection
            return GuestAgentClient(guestName: info.machine.name) { () throws(MawError) in
                guard connection.rawValue >= 0 else {
                    throw .guestAgentFailed(reason: "the session's connection was already used")
                }
                return OwnedDescriptor(connection.take())
            }
        }
    }
#endif
