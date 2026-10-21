import Foundation
import Observation

/// One installed Linux distribution, as the distributions screen shows it.
public struct DistributionInfo: Hashable, Sendable, Identifiable {
    public enum State: String, Hashable, Sendable {
        case running, stopped
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

/// Where the distributions screen reads distributions from. The daemon provides them in a
/// later phase; until then `NoDistributions` is the only implementation in the running app.
@MainActor
public protocol DistributionProvider: AnyObject, Observable {
    var distributions: [DistributionInfo] { get }
}

/// The provider for this phase: no distributions, so the screen shows its empty state. The app
/// never shows invented distributions; sample data exists only in previews and tests.
@MainActor
@Observable
public final class NoDistributions: DistributionProvider {
    public let distributions: [DistributionInfo] = []

    public init() {}
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
