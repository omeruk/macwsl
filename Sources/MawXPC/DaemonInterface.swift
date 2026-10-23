#if os(macOS)
    import Foundation
    import MawCore

    /// The XPC interface between `mawd` and its clients. docs/daemon.md specifies it.
    ///
    /// Every message is an XPC dictionary with a fixed `interfaceVersion` key and a JSON body
    /// (see `InterfaceCoding`). The client's first request on every connection is `hello`.
    public enum DaemonInterface {
        /// Incremented on every change to the messages below, their fields, or their meaning.
        public static let version: UInt32 = 2

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
        /// Starts the machine if needed and opens a connection to its guest agent. `nil` means
        /// the default distribution's machine. The reply carries the connection's descriptor.
        /// The session lasts until this XPC connection closes.
        case openSession(MachineID?)
        case status
        /// Stops every machine and ends their sessions.
        case shutdown
        /// Installs a distribution. The daemon sends `installProgress` events while it works and
        /// replies when the installation has finished, failed, or been cancelled. It cancels
        /// the installation if this XPC connection closes.
        case install(InstallRequest)
        /// Checks what can be checked about an installation without its account: that the
        /// distribution is in the catalog, that the name is free and not being installed, and
        /// that the volume has room. `maw --install` asks before it asks for the account, so
        /// that nobody types a password for an installation that cannot start; `install`
        /// checks the same again.
        case checkInstall(distribution: String?, name: DistroName?)
        /// Cancels this connection's installation. Replied to once its traces are removed, or once
        /// it has finished if it had already registered the distribution.
        case cancelInstall

        /// How the request is named in error messages.
        public var displayName: String {
            switch self {
            case .hello: "the version check"
            case .openSession: "opening a session"
            case .status: "the status request"
            case .shutdown: "the shutdown request"
            case .install: "the installation"
            case .checkInstall: "checking the installation"
            case .cancelInstall: "cancelling the installation"
            }
        }
    }

    /// A value that must not appear in logs, descriptions, or error messages, such as a
    /// password. It is encoded as the plain value only where a message carries it.
    public struct Secret: Codable, Equatable, Sendable, CustomStringConvertible,
        CustomDebugStringConvertible, CustomReflectable
    {
        public let value: String

        public init(_ value: String) {
            self.value = value
        }

        public init(from decoder: any Decoder) throws {
            value = try decoder.singleValueContainer().decode(String.self)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }

        public var description: String { "<redacted>" }
        public var debugDescription: String { "<redacted>" }
        public var customMirror: Mirror { Mirror(self, children: [:]) }
    }

    public struct InstallRequest: Codable, Equatable, Sendable {
        /// A catalog name or alias; `nil` installs the catalog's recommended entry.
        public var distribution: String?
        /// The name to install it under; `nil` is the catalog entry's name.
        public var name: DistroName?
        /// The new account's name, validated by the client and again by the daemon.
        public var user: String
        public var password: Secret
        /// The Mac's language and region, such as `tr_TR.UTF-8`, generated in the guest if it
        /// supports it.
        public var locale: String?

        public init(
            distribution: String?, name: DistroName? = nil, user: String, password: Secret,
            locale: String?
        ) {
            self.distribution = distribution
            self.name = name
            self.user = user
            self.password = password
            self.locale = locale
        }
    }

    /// The steps of an installation, in order. `download` and `verify` are the only ones
    /// that a cached image skips; `verify` runs for every installation.
    public enum InstallStep: String, Codable, Equatable, Sendable, CaseIterable {
        case download
        case verify
        case prepare
        case format
        case extract
        case configure
        case finish
        case start
    }

    public enum InstallProgress: Codable, Equatable, Sendable {
        case started(InstallStep)
        case finished(InstallStep, milliseconds: UInt64)
        /// Sent at most a few times a second while `download` runs.
        case download(DownloadProgress)
    }

    public struct DownloadProgress: Codable, Equatable, Sendable {
        public var receivedBytes: UInt64
        public var totalBytes: UInt64
        /// The recent rate, or 0 while it is not known yet.
        public var bytesPerSecond: UInt64
        /// The bytes that were already in the cache from an earlier, interrupted download.
        public var resumedFromBytes: UInt64

        public init(
            receivedBytes: UInt64, totalBytes: UInt64, bytesPerSecond: UInt64,
            resumedFromBytes: UInt64
        ) {
            self.receivedBytes = receivedBytes
            self.totalBytes = totalBytes
            self.bytesPerSecond = bytesPerSecond
            self.resumedFromBytes = resumedFromBytes
        }
    }

    public struct InstallSummary: Codable, Equatable, Sendable {
        public var name: DistroName
        public var displayName: String
        public var defaultUser: String
        /// Whether it became the default distribution.
        public var isDefault: Bool
        public var milliseconds: UInt64

        public init(
            name: DistroName, displayName: String, defaultUser: String, isDefault: Bool,
            milliseconds: UInt64
        ) {
            self.name = name
            self.displayName = displayName
            self.defaultUser = defaultUser
            self.isDefault = isDefault
            self.milliseconds = milliseconds
        }
    }

    /// Daemon to client: the reply to a request.
    public enum DaemonReply: Codable, Equatable, Sendable {
        case welcome(DaemonInfo)
        /// The guest agent connection travels next to the body, as an XPC descriptor.
        case sessionOpened(SessionInfo)
        case status(DaemonStatus)
        case shutdownComplete(ShutdownSummary)
        case installed(InstallSummary)
        /// The reply to `checkInstall`: nothing known prevents the installation.
        case installPossible
        /// The reply to `cancelInstall`. `wasRunning` is true if an installation was stopped and
        /// its traces removed, and false if nothing was being installed or the installation had
        /// already registered the distribution and finished.
        case installCancelled(wasRunning: Bool)
        case failure(MawError)
    }

    /// Daemon to client, without a request.
    public enum DaemonEvent: Codable, Equatable, Sendable {
        /// The session's machine stopped. The guest agent connection closes with it.
        case sessionEnded(SessionEnded)
        /// The installation that this connection requested moved on.
        case installProgress(InstallProgress)
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
