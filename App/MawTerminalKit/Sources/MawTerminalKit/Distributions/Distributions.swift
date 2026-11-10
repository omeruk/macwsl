import Foundation
import MawClient
import MawCore
import MawXPC
import Observation
import os

/// One installed Linux distribution, as the distributions screen shows it.
public struct DistributionInfo: Hashable, Sendable, Identifiable {
    /// The state of the distribution's machine, as the daemon reports it.
    public enum State: String, Hashable, Sendable {
        case starting, running, stopping, stopped
    }

    /// A `key value` row in the details box. `role` picks the color, as in
    /// `Distributions.dc.html`.
    public struct Detail: Hashable, Sendable {
        public enum Role: Hashable, Sendable {
            case plain, muted, positive, number, link, timing
        }

        public var key: String
        public var value: String
        public var role: Role

        public init(_ key: String, _ value: String, role: Role = .plain) {
            self.key = key
            self.value = value
            self.role = role
        }
    }

    public var name: String
    public var state: State
    public var isDefault: Bool
    public var memory: String?
    public var cpu: String?
    public var disk: String?
    public var uptime: String?
    public var kernel: String?
    public var details: [Detail]
    /// Memory use over the last 60 seconds, oldest first, in bytes.
    public var memoryHistory: [UInt64]
    public var memoryLimit: UInt64?

    public var id: String { name }

    public init(
        name: String, state: State, isDefault: Bool = false, memory: String? = nil,
        cpu: String? = nil, disk: String? = nil, uptime: String? = nil, kernel: String? = nil,
        details: [Detail] = [], memoryHistory: [UInt64] = [], memoryLimit: UInt64? = nil
    ) {
        self.name = name
        self.state = state
        self.isDefault = isDefault
        self.memory = memory
        self.cpu = cpu
        self.disk = disk
        self.uptime = uptime
        self.kernel = kernel
        self.details = details
        self.memoryHistory = memoryHistory
        self.memoryLimit = memoryLimit
    }
}

/// Where the profiles and the distributions screen read the installed distributions from.
@MainActor
public protocol DistributionProvider: AnyObject, Observable {
    /// The distributions of the last answer, empty while there is none.
    var distributions: [DistributionInfo] { get }
    /// Why the last refresh failed, or `nil`.
    var failure: MawError? { get }
    /// Asks for the list again. Returns at once; the properties change when the answer
    /// arrives.
    func refresh()
}

/// The requests that the app sends the daemon outside a session, so that tests can answer
/// them.
public protocol DaemonRequests: AnyObject, Sendable {
    func listDistributions() async throws(MawError) -> DistributionList
    func close()
}

extension DaemonClient: DaemonRequests {}

/// The installed distributions as the daemon reports them, shared by every window's profiles
/// and distributions screen.
///
/// Each refresh connects, sends `listDistributions`, and closes again, because a connection
/// held open would keep the daemon from its idle exit. It refreshes only when asked to (when
/// the new-tab menu, the command palette, or the distributions screen opens) and never polls.
/// It never invents data: while the daemon cannot be reached, the list is empty and `failure`
/// says why.
@MainActor
@Observable
public final class DaemonDistributions: DistributionProvider {
    public typealias Connector = @Sendable () async throws(MawError) -> any DaemonRequests

    public private(set) var distributions: [DistributionInfo] = []
    public private(set) var failure: MawError?

    @ObservationIgnored private let connect: Connector
    /// The refresh under way. Tests await it.
    @ObservationIgnored private(set) var pending: Task<Void, Never>?
    /// Set when a refresh is asked for while one is under way, so that another follows it.
    @ObservationIgnored private var refreshesAgain = false

    public init(
        connect: @escaping Connector = { () async throws(MawError) -> any DaemonRequests in
            try await DaemonClient.connect()
        }
    ) {
        self.connect = connect
    }

    public func refresh() {
        guard pending == nil else {
            refreshesAgain = true
            return
        }
        pending = Task {
            repeat {
                refreshesAgain = false
                apply(await Self.list(connect))
            } while refreshesAgain
            pending = nil
        }
    }

    /// Connects, asks for the list, and closes again. Never on the main actor, because the
    /// connection runs `launchctl print` synchronously.
    @concurrent
    nonisolated static func list(_ connect: Connector) async -> Result<DistributionList, MawError> {
        do {
            let client = try await connect()
            defer { client.close() }
            return .success(try await client.listDistributions())
        } catch {
            return .failure(error)
        }
    }

    private func apply(_ result: Result<DistributionList, MawError>) {
        switch result {
        case .success(let list):
            let made = list.distributions.map { entry in
                Self.make(entry: entry, isDefault: entry.name == list.defaultDistribution)
            }
            if made != distributions { distributions = made }
            if failure != nil { failure = nil }
        case .failure(let error):
            Logger.app.info(
                "The distributions could not be listed: \(error.description, privacy: .public)")
            if !distributions.isEmpty { distributions = [] }
            if failure != error { failure = error }
        }
    }

    /// A row of the screen from the daemon's entry: its name, state, and default marker. The
    /// figures stay empty until phase 11c.
    static func make(entry: DistributionEntry, isDefault: Bool) -> DistributionInfo {
        let state: DistributionInfo.State =
            switch entry.state {
            case .starting: .starting
            case .running: .running
            case .stopping: .stopping
            case .stopped: .stopped
            }
        return DistributionInfo(name: entry.name.rawValue, state: state, isDefault: isDefault)
    }
}

/// The host summary on the right of the distributions table's border: memory, CPU cores, and
/// the macOS version, from real system values.
public struct HostSummary: Hashable, Sendable {
    public var physicalMemory: UInt64
    public var processorCount: Int
    /// The macOS version as major, minor, and patch numbers.
    public var macOSVersion: [Int]

    public init(physicalMemory: UInt64, processorCount: Int, macOSVersion: [Int]) {
        self.physicalMemory = physicalMemory
        self.processorCount = processorCount
        self.macOSVersion = macOSVersion
    }

    public static var current: HostSummary {
        let info = ProcessInfo.processInfo
        let version = info.operatingSystemVersion
        return HostSummary(
            physicalMemory: info.physicalMemory, processorCount: info.processorCount,
            macOSVersion: [version.majorVersion, version.minorVersion, version.patchVersion])
    }

    /// `16 GB · 10 cores · macOS 27.0`. Memory is in binary gigabytes, as About This Mac
    /// reports it. A patch version of 0 is left out, as macOS writes its own version.
    public var description: String {
        let gigabytes = Double(physicalMemory) / Double(1 << 30)
        let memory = String(format: "%.0f GB", gigabytes.rounded())
        let cores = processorCount == 1 ? "1 core" : "\(processorCount) cores"
        var parts = macOSVersion + Array(repeating: 0, count: max(0, 2 - macOSVersion.count))
        if parts.count > 2, parts[2] == 0 {
            parts = Array(parts.prefix(2))
        }
        return "\(memory) · \(cores) · macOS \(parts.map(String.init).joined(separator: "."))"
    }
}
