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
    /// Memory in use at each of the last samples, oldest first, in bytes: at most
    /// `DaemonDistributions.historyLength`, one per sample. A sample whose memory could not be
    /// read is `nil`, so that the time axis stays correct.
    public var memoryHistory: [UInt64?]
    /// The machine's memory size, which the chart's bars are scaled to.
    public var memoryLimit: UInt64?

    public var id: String { name }

    public init(
        name: String, state: State, isDefault: Bool = false, memory: String? = nil,
        cpu: String? = nil, disk: String? = nil, uptime: String? = nil, kernel: String? = nil,
        details: [Detail] = [], memoryHistory: [UInt64?] = [], memoryLimit: UInt64? = nil
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

/// Where the profiles and the distributions screen read the installed distributions from, and
/// what carries out the screen's actions.
@MainActor
public protocol DistributionProvider: AnyObject, Observable {
    /// The distributions of the last answer, empty while there is none.
    var distributions: [DistributionInfo] { get }
    /// Why the last refresh failed, or `nil`.
    var failure: MawError? { get }
    /// Whether a refresh has been answered yet, with a list or a failure. Until then an empty
    /// list does not mean that nothing is installed.
    var hasAnswer: Bool { get }
    /// Asks for the list again, unless a window shows the distributions screen, whose watch
    /// keeps the list current. Returns at once; the properties change when the answer arrives.
    func refresh()
    /// Says whether `window` shows the distributions screen: its selected tab is the screen, and
    /// the window is neither minimized nor covered. While any window shows it, the provider
    /// follows the daemon with figures; while none does, it holds no connection.
    func setScreenVisible(_ visible: Bool, in window: ObjectIdentifier)
    /// The sessions open in the distribution's machine, of every client of the daemon, not only
    /// this app's tabs. 0 when its machine does not run.
    func openSessions(in name: String) async throws(MawError) -> Int
    /// Makes the distribution the default one.
    func setDefault(_ name: String) async throws(MawError)
    /// Stops the distribution's machine, which ends its sessions. Returns once it has stopped.
    /// It sends no other request: the screen's watch shows the machine stopping.
    func stop(_ name: String) async throws(MawError)
}

/// The requests that the app sends the daemon outside a session, so that tests can answer
/// them.
public protocol DaemonRequests: AnyObject, Sendable {
    func listDistributions() async throws(MawError) -> DistributionList
    func status() async throws(MawError) -> DaemonStatus
    func setDefault(_ name: DistroName) async throws(MawError) -> DistroName
    func terminate(_ name: DistroName) async throws(MawError) -> TerminateSummary
    func watchDistributions(after: UInt64) async throws(MawError) -> DistributionSnapshot
    func close()
}

extension DaemonClient: DaemonRequests {}

/// The installed distributions as the daemon reports them, shared by every window's profiles
/// and distributions screen.
///
/// While at least one window shows the distributions screen, it holds one connection and
/// repeats `watchDistributions`, which gives every state change at once and the figures after
/// each sample (docs/daemon.md, "Watching the distributions"). It keeps each running
/// distribution's memory history for the chart. When no window shows the screen, it closes
/// that connection, forgets the figures and the history, and asks for the list only when the
/// new-tab menu, the command palette, or the settings open, with a connection per request,
/// because a connection held open would keep the daemon from its idle exit. It never invents
/// data: while the daemon cannot be reached, the list is empty and `failure` says why.
@MainActor
@Observable
public final class DaemonDistributions: DistributionProvider {
    public typealias Connector = @Sendable () async throws(MawError) -> any DaemonRequests
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// The samples of the memory chart: 60 seconds at the daemon's interval of 1.5 seconds.
    public nonisolated static let historyLength = 40
    /// The waits between attempts to watch while the daemon cannot be reached; the last one
    /// repeats.
    static let retryDelays: [Duration] = [1, 2, 4, 8, 16, 30].map { .seconds($0) }

    public private(set) var distributions: [DistributionInfo] = []
    public private(set) var failure: MawError?
    public private(set) var hasAnswer = false

    @ObservationIgnored private let connect: Connector
    /// The refresh under way. Tests await it.
    @ObservationIgnored private(set) var pending: Task<Void, Never>?
    /// Set when a refresh is asked for while one is under way, so that another follows it.
    @ObservationIgnored private var refreshesAgain = false
    @ObservationIgnored private let sleep: Sleep
    /// The windows that show the distributions screen.
    @ObservationIgnored private var screens: Set<ObjectIdentifier> = []
    /// The watch while a window shows the screen. Tests await it.
    @ObservationIgnored private(set) var watch: Task<Void, Never>?
    /// Identifies the current watch, so that an answer to an earlier one is not applied.
    @ObservationIgnored private var watchNumber: UInt64 = 0
    @ObservationIgnored private var histories: [String: MemoryHistory] = [:]

    public init(
        connect: @escaping Connector = { () async throws(MawError) -> any DaemonRequests in
            try await DaemonClient.connect()
        },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.connect = connect
        self.sleep = sleep
    }

    public func refresh() {
        if watch != nil {
            // The watch keeps the list current. While it waits to try again, ⌘⇧L or an action
            // tries again at once, from the shortest delay.
            if failure != nil { startWatching() }
            return
        }
        guard pending == nil else {
            refreshesAgain = true
            return
        }
        pending = Task {
            repeat {
                refreshesAgain = false
                apply(
                    await Self.ask(connect) { client async throws(MawError) in
                        try await client.listDistributions()
                    })
            } while refreshesAgain
            pending = nil
        }
    }

    public func openSessions(in name: String) async throws(MawError) -> Int {
        let machine = MachineID.distribution(try DistroName(name))
        let status = try await Self.ask(connect) { client async throws(MawError) in
            try await client.status()
        }.get()
        return status.machines.first { $0.machine == machine }?.sessionCount ?? 0
    }

    public func setDefault(_ name: String) async throws(MawError) {
        let distribution = try DistroName(name)
        _ = try await Self.ask(connect) { client async throws(MawError) in
            try await client.setDefault(distribution)
        }.get()
    }

    public func stop(_ name: String) async throws(MawError) {
        let distribution = try DistroName(name)
        _ = try await Self.ask(connect) { client async throws(MawError) in
            try await client.terminate(distribution)
        }.get()
    }

    // MARK: Watching

    public func setScreenVisible(_ visible: Bool, in window: ObjectIdentifier) {
        let wasWatching = !screens.isEmpty
        if visible {
            screens.insert(window)
        } else {
            screens.remove(window)
        }
        if !wasWatching, !screens.isEmpty {
            startWatching()
        } else if wasWatching, screens.isEmpty {
            stopWatching()
        }
    }

    /// Watches until cancelled, in place of any earlier watch. After a failure it shows the
    /// error and tries again after each of `retryDelays`. A connection that delivered two
    /// snapshots starts the delays from the first again, so that a daemon that answers once and
    /// then fails each time is not asked every second.
    private func startWatching() {
        watch?.cancel()
        watchNumber += 1
        let number = watchNumber
        let received: @Sendable (DistributionSnapshot) async -> Void = { [weak self] snapshot in
            await self?.apply(snapshot, watch: number)
        }
        let failed: @Sendable (MawError) async -> Void = { [weak self] error in
            await self?.apply(error, watch: number)
        }
        watch = Task { [connect, sleep] in
            var failures = 0
            while !Task.isCancelled {
                let (error, snapshots) = await Self.follow(connect, received: received)
                guard let error, !Task.isCancelled else { return }
                await failed(error)
                if snapshots >= 2 { failures = 0 }
                let delay = Self.retryDelays[min(failures, Self.retryDelays.count - 1)]
                failures += 1
                try? await sleep(delay)
            }
        }
    }

    /// Closes the watch's connection, and forgets the figures and the history, so that a
    /// later watch never shows a gap as data. The rows keep their state until the next answer.
    private func stopWatching() {
        watch?.cancel()
        watch = nil
        watchNumber += 1
        histories = [:]
        let rows = distributions.map {
            DistributionInfo(name: $0.name, state: $0.state, isDefault: $0.isDefault)
        }
        if rows != distributions { distributions = rows }
        // The profiles of every window would otherwise keep the watch's failure, and no list.
        if failure != nil { refresh() }
    }

    /// Connects and repeats `watchDistributions` until it fails or the task is cancelled, and
    /// closes the connection. Returns the failure, `nil` when cancelled, and how many snapshots
    /// arrived.
    @concurrent
    nonisolated static func follow(
        _ connect: Connector, received: @Sendable (DistributionSnapshot) async -> Void
    ) async -> (MawError?, Int) {
        let client: any DaemonRequests
        do {
            client = try await connect()
        } catch {
            return (error, 0)
        }
        let closer = Closer(client)
        defer { closer.close() }
        return await withTaskCancellationHandler {
            var after: UInt64 = 0
            var snapshots = 0
            while !Task.isCancelled {
                do throws(MawError) {
                    let snapshot = try await client.watchDistributions(after: after)
                    after = snapshot.sequence
                    snapshots += 1
                    await received(snapshot)
                } catch {
                    return (Task.isCancelled ? nil : error, snapshots)
                }
            }
            return (nil, snapshots)
        } onCancel: {
            // A held `watchDistributions` returns only when its connection closes.
            closer.close()
        }
    }

    /// Closes a client once, from whichever of the watch and its cancellation comes first.
    private final class Closer: Sendable {
        let client: any DaemonRequests
        let closed = OSAllocatedUnfairLock(initialState: false)

        init(_ client: any DaemonRequests) {
            self.client = client
        }

        func close() {
            let first = closed.withLock { closed in
                let first = !closed
                closed = true
                return first
            }
            if first { client.close() }
        }
    }

    private func apply(_ snapshot: DistributionSnapshot, watch number: UInt64) {
        guard number == watchNumber else { return }
        if !hasAnswer { hasAnswer = true }
        if failure != nil { failure = nil }
        var kept: [String: MemoryHistory] = [:]
        let rows = snapshot.distributions.map { figures in
            let name = figures.name.rawValue
            var history = histories[name] ?? MemoryHistory()
            history.record(figures)
            kept[name] = history
            return Self.make(
                figures, isDefault: figures.name == snapshot.defaultDistribution,
                history: history.values)
        }
        histories = kept
        if rows != distributions { distributions = rows }
    }

    /// The daemon could not be watched: the list is empty and the error stays shown while
    /// the attempts go on.
    private func apply(_ error: MawError, watch number: UInt64) {
        guard number == watchNumber else { return }
        Logger.app.info(
            "The distributions could not be watched: \(error.description, privacy: .public)")
        if !hasAnswer { hasAnswer = true }
        histories = [:]
        if !distributions.isEmpty { distributions = [] }
        if failure != error { failure = error }
    }

    /// Connects, sends what `request` sends, and closes again. Never on the main actor, because
    /// the connection runs `launchctl print` synchronously.
    @concurrent
    nonisolated static func ask<Answer: Sendable>(
        _ connect: Connector,
        _ request: @Sendable (any DaemonRequests) async throws(MawError) -> Answer
    ) async -> Result<Answer, MawError> {
        do {
            let client = try await connect()
            defer { client.close() }
            return .success(try await request(client))
        } catch {
            return .failure(error)
        }
    }

    private func apply(_ result: Result<DistributionList, MawError>) {
        // The watch's snapshots are newer, and carry the figures.
        guard watch == nil else { return }
        if !hasAnswer { hasAnswer = true }
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

    /// A row from the daemon's list: its name, state, and default marker, without figures.
    static func make(entry: DistributionEntry, isDefault: Bool) -> DistributionInfo {
        DistributionInfo(
            name: entry.name.rawValue, state: .init(entry.state), isDefault: isDefault)
    }

    /// A row from a snapshot, as "The four states" of the phase 11c prompt describes it: DISK,
    /// KERNEL, and the details `default`, `user`, and `disk image` in every state; the other
    /// figures, the details `ip`, `boot`, and `host memory`, and the history only while it runs.
    /// A figure that the daemon did not report is left out.
    static func make(
        _ figures: DistributionFigures, isDefault: Bool, history: [UInt64?],
        home: String = NSHomeDirectory()
    ) -> DistributionInfo {
        var row = make(
            entry: DistributionEntry(name: figures.name, state: figures.state),
            isDefault: isDefault)
        let running = figures.state == .running
        if let allocated = figures.diskAllocatedBytes, let size = figures.diskSizeBytes {
            row.disk = "\(FigureFormat.bytes(allocated))/\(FigureFormat.bytes(size))"
        }
        row.kernel = figures.kernelRelease
        row.details = [
            .init("default", isDefault ? "yes" : "no", role: isDefault ? .positive : .muted),
            .init("user", figures.defaultUser),
        ]
        if running, let address = figures.ipv4Address {
            row.details.append(.init("ip", address, role: .number))
        }
        row.details.append(
            .init("disk image", FigureFormat.path(figures.diskImagePath, home: home)))
        guard running else { return row }
        row.memory = figures.memoryUsedBytes.map(FigureFormat.bytes)
        row.cpu = figures.cpuPercent.map(FigureFormat.percent)
        row.uptime = figures.uptimeMilliseconds.map(FigureFormat.uptime)
        if let boot = figures.bootMilliseconds {
            row.details.append(.init("boot", "\(boot) ms to agent", role: .timing))
        }
        if let host = figures.hostMemoryBytes {
            row.details.append(.init("host memory", FigureFormat.bytes(host), role: .number))
        }
        row.memoryHistory = history
        row.memoryLimit = figures.memoryLimitBytes
        return row
    }
}

extension DistributionInfo.State {
    init(_ state: DistributionState) {
        self =
            switch state {
            case .starting: .starting
            case .running: .running
            case .stopping: .stopping
            case .stopped: .stopped
            }
    }
}

/// One running distribution's memory in use, one value per sample, for the chart.
struct MemoryHistory: Equatable {
    private(set) var values: [UInt64?] = []
    private var run: UInt64?
    /// The last sample number seen, `nil` before the first.
    private var lastSample: UInt64?

    /// Adds the snapshot's sample, if it is a new one. The first number seen adds one value,
    /// whatever its number; after that, a jump of k adds k−1 empty values before it, so that
    /// a sample the app missed keeps its slot. A new run, and a distribution that does not run,
    /// start again from nothing.
    mutating func record(_ figures: DistributionFigures) {
        guard figures.state == .running, let run = figures.run else {
            self = MemoryHistory()
            return
        }
        if run != self.run { self = MemoryHistory(run: run) }
        guard let number = figures.sampleNumber else { return }
        if let lastSample, number <= lastSample {
            // The same sample again; a smaller number starts the count again.
            guard number < lastSample else { return }
            values = []
        } else if let lastSample {
            let missed = min(number - lastSample - 1, UInt64(DaemonDistributions.historyLength))
            values += Array(repeating: nil, count: Int(missed))
        }
        values.append(figures.memoryUsedBytes)
        values = Array(values.suffix(DaemonDistributions.historyLength))
        lastSample = number
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
