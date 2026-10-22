#if os(macOS)
    import Foundation
    import MawCore

    /// The XPC interface between `mawd` and its clients. docs/daemon.md specifies it.
    ///
    /// Every message is an XPC dictionary with a fixed `interfaceVersion` key and a JSON body
    /// (see `InterfaceCoding`). The client's first request on every connection is `hello`.
    public enum DaemonInterface {
        /// Incremented on every change to the messages below, their fields, or their meaning.
        public static let version: UInt32 = 1

        /// The LaunchAgent label, which is also the name of the daemon's Mach service.
        public static let defaultLabel = "dev.maw.mawd"

        /// Selects another label for clients, so that the integration tests can run against a
        /// daemon of their own. Not for users.
        public static let labelEnvironmentVariable = "MAW_DAEMON_LABEL"

        /// The label clients use: `MAW_DAEMON_LABEL` if set, otherwise `defaultLabel`.
        public static func label(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> String {
            if let label = environment[labelEnvironmentVariable], !label.isEmpty {
                return label
            }
            return defaultLabel
        }
    }

    /// Client to daemon.
    public enum DaemonRequest: Codable, Equatable, Sendable {
        /// The first request on a connection. `clientVersion` is the client's `MawVersion`.
        case hello(clientVersion: String)
        /// Starts the machine if needed and opens a connection to its guest agent. The reply
        /// carries the connection's descriptor. The session lasts until this XPC connection
        /// closes.
        case openSession(MachineID)
        case status
        /// Stops every machine and ends their sessions.
        case shutdown

        /// How the request is named in error messages.
        public var displayName: String {
            switch self {
            case .hello: "the version check"
            case .openSession: "opening a session"
            case .status: "the status request"
            case .shutdown: "the shutdown request"
            }
        }
    }

    /// Daemon to client: the reply to a request.
    public enum DaemonReply: Codable, Equatable, Sendable {
        case welcome(DaemonInfo)
        /// The guest agent connection travels next to the body, as an XPC descriptor.
        case sessionOpened(SessionInfo)
        case status(DaemonStatus)
        case shutdownComplete(ShutdownSummary)
        case failure(MawError)
    }

    /// Daemon to client, without a request.
    public enum DaemonEvent: Codable, Equatable, Sendable {
        /// The session's machine stopped. The guest agent connection closes with it.
        case sessionEnded(SessionEnded)
    }

    public struct DaemonInfo: Codable, Equatable, Sendable {
        public var version: String
        public var processID: Int32
        public var interfaceVersion: UInt32

        public init(version: String, processID: Int32, interfaceVersion: UInt32) {
            self.version = version
            self.processID = processID
            self.interfaceVersion = interfaceVersion
        }
    }

    public struct SessionInfo: Codable, Equatable, Sendable {
        public var sessionID: UInt64
        public var machine: MachineID

        public init(sessionID: UInt64, machine: MachineID) {
            self.sessionID = sessionID
            self.machine = machine
        }
    }

    public struct SessionEnded: Codable, Equatable, Sendable {
        public var sessionID: UInt64
        public var machine: MachineID
        /// Why the machine stopped, for example `maw --shutdown was run`.
        public var reason: String

        public init(sessionID: UInt64, machine: MachineID, reason: String) {
            self.sessionID = sessionID
            self.machine = machine
            self.reason = reason
        }
    }

    public struct DaemonStatus: Codable, Equatable, Sendable {
        public var daemon: DaemonInfo
        public var uptimeMilliseconds: UInt64
        /// Whether the daemon is signed with the virtualization entitlement.
        public var canRunVirtualMachines: Bool
        /// Machines that are starting, running, or stopping. Stopped machines are omitted.
        public var machines: [MachineStatus]

        public init(
            daemon: DaemonInfo, uptimeMilliseconds: UInt64, canRunVirtualMachines: Bool,
            machines: [MachineStatus]
        ) {
            self.daemon = daemon
            self.uptimeMilliseconds = uptimeMilliseconds
            self.canRunVirtualMachines = canRunVirtualMachines
            self.machines = machines
        }
    }

    public struct MachineStatus: Codable, Equatable, Sendable {
        public enum State: String, Codable, Equatable, Sendable {
            case starting, running, stopping
        }

        public var machine: MachineID
        public var state: State
        /// Time since the machine started running; `nil` while it starts.
        public var uptimeMilliseconds: UInt64?
        public var cpuCount: Int
        public var memoryBytes: UInt64
        public var sessionCount: Int

        public init(
            machine: MachineID, state: State, uptimeMilliseconds: UInt64?, cpuCount: Int,
            memoryBytes: UInt64, sessionCount: Int
        ) {
            self.machine = machine
            self.state = state
            self.uptimeMilliseconds = uptimeMilliseconds
            self.cpuCount = cpuCount
            self.memoryBytes = memoryBytes
            self.sessionCount = sessionCount
        }
    }

    public struct ShutdownSummary: Codable, Equatable, Sendable {
        public var stoppedMachines: [MachineID]
        public var endedSessions: Int

        public init(stoppedMachines: [MachineID], endedSessions: Int) {
            self.stoppedMachines = stoppedMachines
            self.endedSessions = endedSessions
        }
    }
#endif
