import AppKit
import Darwin
import MawClient
import MawCore
import MawXPC
import Testing
import os

@testable import MawTerminalKit

/// A daemon that answers `listDistributions` as the test sets it, carries out the screen's
/// requests on that list, answers `watchDistributions` with the snapshots that the test
/// publishes, and records each connection and request.
final class FakeDaemonClient: @unchecked Sendable {
    struct Record {
        var connects = 0
        var lists = 0
        var closes = 0
        /// Connections made on the main thread, which must not happen.
        var connectsOnMain = 0
        /// Every request other than a list, in order, such as `terminate Ubuntu-24.04`.
        var requests: [String] = []
        /// `watchDistributions` requests, with the `after` of each.
        var watches: [UInt64] = []
        /// Connections that sent `watchDistributions`, ever and still open.
        var watchingConnections = 0
        var openWatchingConnections = 0
    }

    /// The newest snapshot, which a watch waits for until its sequence is past `after`.
    let snapshot = OSAllocatedUnfairLock<DistributionSnapshot?>(initialState: nil)
    /// The list's snapshots while the test publishes none: the list and its sequence number.
    private let derived = OSAllocatedUnfairLock<(UInt64, DistributionList?)>(
        initialState: (0, nil))
    /// What `watchDistributions` throws, such as a lost daemon, or `nil` to answer.
    let watchFailure = OSAllocatedUnfairLock<MawError?>(initialState: nil)

    /// Publishes a snapshot with the next sequence number.
    func publish(_ distributions: [DistributionFigures], default name: String? = nil) {
        snapshot.withLock {
            $0 = DistributionSnapshot(
                sequence: ($0?.sequence ?? 0) + 1, distributions: distributions,
                defaultDistribution: (name ?? distributions.first?.name.rawValue).map {
                    try! DistroName($0)
                })
        }
    }

    /// The list as a snapshot without figures, with a new sequence number whenever it changed.
    private func listSnapshot() -> DistributionSnapshot? {
        guard case .success(let list) = answer.withLock({ $0 }) else { return nil }
        let sequence = derived.withLock {
            if $0.1 != list { $0 = ($0.0 + 1, list) }
            return $0.0
        }
        return DistributionSnapshot(
            sequence: sequence,
            distributions: list.distributions.map {
                DistributionFigures(
                    name: $0.name, state: $0.state, defaultUser: "user", diskImagePath: "/disk.img")
            }, defaultDistribution: list.defaultDistribution)
    }

    func watchDistributions(after: UInt64, on connection: FakeConnection) async throws(MawError)
        -> DistributionSnapshot
    {
        record.withLock { $0.watches.append(after) }
        if connection.startsWatching() {
            record.withLock {
                $0.watchingConnections += 1
                $0.openWatchingConnections += 1
            }
        }
        while true {
            if connection.isClosed { throw .daemonConnectionLost(during: "watchDistributions") }
            if let failure = watchFailure.withLock({ $0 }) { throw failure }
            if let current = snapshot.withLock({ $0 }) ?? listSnapshot(), current.sequence > after {
                return current
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    let record = OSAllocatedUnfairLock(initialState: Record())
    /// What connecting throws, such as an unreachable daemon, or `nil` to connect.
    let connectFailure = OSAllocatedUnfairLock<MawError?>(initialState: nil)
    let answer = OSAllocatedUnfairLock<Result<DistributionList, MawError>>(
        initialState: .success(DistributionList(distributions: [], defaultDistribution: nil)))
    /// How long each answer takes.
    let delay = OSAllocatedUnfairLock(initialState: Duration.zero)
    /// The sessions open in each distribution's machine, as `status` reports them.
    let sessions = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])
    /// What a request throws instead of being carried out, by its name: `status`,
    /// `setDefault`, or `terminate`.
    let requestFailures = OSAllocatedUnfairLock<[String: MawError]>(initialState: [:])
    /// While set, a machine that is asked to stop stays stopping.
    let holdsStops = OSAllocatedUnfairLock(initialState: false)

    /// Installed distributions, stopped unless `states` says otherwise, with `defaultName` or
    /// else the first as the default.
    func install(
        _ names: [String], states: [DistributionState] = [], default defaultName: String? = nil
    ) {
        let entries = names.enumerated().map { index, name in
            DistributionEntry(
                name: try! DistroName(name),
                state: states.indices.contains(index) ? states[index] : .stopped)
        }
        let defaultDistribution = defaultName.map { try! DistroName($0) } ?? entries.first?.name
        answer.withLock {
            $0 = .success(
                DistributionList(distributions: entries, defaultDistribution: defaultDistribution))
        }
    }

    func listDistributions() async throws(MawError) -> DistributionList {
        record.withLock { $0.lists += 1 }
        let delay = self.delay.withLock { $0 }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return try answer.withLock { $0 }.get()
    }

    func status() async throws(MawError) -> DaemonStatus {
        try received("status", "")
        let machines = sessions.withLock { $0 }.sorted { $0.key < $1.key }.map { name, count in
            MachineStatus(
                machine: .distribution(try! DistroName(name)), state: .running,
                uptimeMilliseconds: 1000, cpuCount: 2, memoryBytes: 1 << 30, sessionCount: count)
        }
        return DaemonStatus(
            daemon: DaemonInfo(version: "test", processID: 1, interfaceVersion: 1),
            uptimeMilliseconds: 1000, canRunVirtualMachines: true, machines: machines)
    }

    func setDefault(_ name: DistroName) async throws(MawError) -> DistroName {
        try received("setDefault", name.rawValue)
        answer.withLock {
            guard case .success(var list) = $0 else { return }
            list.defaultDistribution = name
            $0 = .success(list)
        }
        return name
    }

    /// The machine is stopping from the request on, and stopped once `holdsStops` is clear.
    func terminate(_ name: DistroName) async throws(MawError) -> TerminateSummary {
        try received("terminate", name.rawValue)
        let wasRunning = setState(of: name, to: .stopping) != .stopped
        while holdsStops.withLock({ $0 }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        setState(of: name, to: .stopped)
        let ended = sessions.withLock { $0.removeValue(forKey: name.rawValue) ?? 0 }
        return TerminateSummary(wasRunning: wasRunning, endedSessions: ended)
    }

    private func received(_ request: String, _ name: String) throws(MawError) {
        record.withLock { $0.requests.append(name.isEmpty ? request : "\(request) \(name)") }
        if let failure = requestFailures.withLock({ $0[request] }) { throw failure }
    }

    /// Sets a listed distribution's state, and returns the one it had. A stopped one stays so.
    @discardableResult
    private func setState(of name: DistroName, to state: DistributionState) -> DistributionState {
        answer.withLock {
            guard case .success(var list) = $0,
                let index = list.distributions.firstIndex(where: { $0.name == name })
            else { return .stopped }
            let previous = list.distributions[index].state
            if previous != .stopped { list.distributions[index].state = state }
            $0 = .success(list)
            return previous
        }
    }

    var connector: DaemonDistributions.Connector {
        { () async throws(MawError) -> any DaemonRequests in
            self.record.withLock {
                $0.connects += 1
                if pthread_main_np() != 0 { $0.connectsOnMain += 1 }
            }
            if let failure = self.connectFailure.withLock({ $0 }) { throw failure }
            return FakeConnection(self)
        }
    }

    /// A provider that asks this daemon, and has not asked yet.
    @MainActor func provider(sleep: DaemonDistributions.Sleep? = nil) -> DaemonDistributions {
        if let sleep { return DaemonDistributions(connect: connector, sleep: sleep) }
        return DaemonDistributions(connect: connector)
    }
}

/// One connection to the fake daemon. A held watch ends when it closes, as an XPC request does.
final class FakeConnection: DaemonRequests, @unchecked Sendable {
    let daemon: FakeDaemonClient
    private let state = OSAllocatedUnfairLock(initialState: (closed: false, watching: false))

    init(_ daemon: FakeDaemonClient) {
        self.daemon = daemon
    }

    var isClosed: Bool { state.withLock { $0.closed } }

    /// Whether this is the connection's first watch.
    func startsWatching() -> Bool {
        state.withLock {
            defer { $0.watching = true }
            return !$0.watching
        }
    }

    func listDistributions() async throws(MawError) -> DistributionList {
        try await daemon.listDistributions()
    }

    func status() async throws(MawError) -> DaemonStatus {
        try await daemon.status()
    }

    func setDefault(_ name: DistroName) async throws(MawError) -> DistroName {
        try await daemon.setDefault(name)
    }

    func terminate(_ name: DistroName) async throws(MawError) -> TerminateSummary {
        try await daemon.terminate(name)
    }

    func watchDistributions(after: UInt64) async throws(MawError) -> DistributionSnapshot {
        try await daemon.watchDistributions(after: after, on: self)
    }

    func close() {
        let (first, watching) = state.withLock {
            defer { $0.closed = true }
            return (!$0.closed, $0.watching)
        }
        daemon.record.withLock {
            $0.closes += 1
            if first, watching { $0.openWatchingConnections -= 1 }
        }
    }
}

extension DaemonDistributions {
    /// Refreshes and waits for the answer.
    func refreshed() async {
        refresh()
        await pending?.value
    }
}

@MainActor
@Suite struct DaemonDistributionsTests {
    @Test func eachRefreshConnectsListsAndClosesOffTheMainActor() async {
        let daemon = FakeDaemonClient()
        daemon.install(["Debian-13", "Ubuntu-24.04"], states: [.running, .stopping])
        let provider = daemon.provider()
        // Never polled: nothing is asked until a refresh.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(daemon.record.withLock { $0.connects } == 0)
        await provider.refreshed()
        await provider.refreshed()
        let record = daemon.record.withLock { $0 }
        #expect(record.connects == 2 && record.lists == 2 && record.closes == 2)
        #expect(record.connectsOnMain == 0)
        #expect(
            provider.distributions == [
                DistributionInfo(name: "Debian-13", state: .running, isDefault: true),
                DistributionInfo(name: "Ubuntu-24.04", state: .stopping),
            ])
        #expect(provider.failure == nil)
    }

    @Test func theDaemonsFourStatesAreKept() {
        for state in DistributionState.allCases {
            let entry = DistributionEntry(name: try! DistroName("Ubuntu-24.04"), state: state)
            let info = DaemonDistributions.make(entry: entry, isDefault: false)
            #expect(info.state.rawValue == state.rawValue)
            #expect(info.memory == nil && info.cpu == nil && info.kernel == nil)
        }
    }

    /// While the daemon cannot be reached, nothing is listed, and the error is kept for the
    /// screen.
    @Test func anUnreachableDaemonEmptiesTheListAndKeepsTheError() async {
        let daemon = FakeDaemonClient()
        daemon.install(["Ubuntu-24.04"])
        let provider = daemon.provider()
        await provider.refreshed()
        #expect(provider.distributions.map(\.name) == ["Ubuntu-24.04"])
        let error = MawError.daemonUnreachable(reason: "the connection was invalidated")
        daemon.connectFailure.withLock { $0 = error }
        await provider.refreshed()
        #expect(provider.distributions.isEmpty)
        #expect(provider.failure == error)
        let settings = Settings()
        #expect(
            settings.profiles(distributions: provider.distributions.map(\.name)).map(\.id) == [
                "default-distribution", "local",
            ])
        daemon.connectFailure.withLock { $0 = nil }
        await provider.refreshed()
        #expect(provider.failure == nil)
        #expect(provider.distributions.map(\.name) == ["Ubuntu-24.04"])
    }

    @Test func aFailedListClosesTheConnection() async {
        let daemon = FakeDaemonClient()
        daemon.answer.withLock { $0 = .failure(.daemonConnectionLost(during: "listDistributions")) }
        let provider = daemon.provider()
        await provider.refreshed()
        #expect(provider.failure == .daemonConnectionLost(during: "listDistributions"))
        #expect(daemon.record.withLock { $0.closes } == 1)
    }

    /// A refresh asked for while one runs follows it, so that the list is never older than
    /// the last request, and refreshes never run at once.
    @Test func aRefreshDuringARefreshFollowsIt() async {
        let daemon = FakeDaemonClient()
        daemon.delay.withLock { $0 = .milliseconds(100) }
        let provider = daemon.provider()
        provider.refresh()
        #expect(await waitUntil(seconds: 5) { daemon.record.withLock { $0.lists } == 1 })
        provider.refresh()
        provider.refresh()
        daemon.install(["Ubuntu-24.04"])
        await provider.pending?.value
        #expect(daemon.record.withLock { $0.lists } == 2)
        #expect(provider.distributions.map(\.name) == ["Ubuntu-24.04"])
    }

    // MARK: The menu bar

    /// Opening the new-tab menu refreshes the list; the items change in place once it
    /// arrives, so that an open menu shows them.
    @Test func theNewTabMenuRefreshesWhenItOpensAndUpdatesInPlace() async throws {
        _ = NSApplication.shared
        let daemon = FakeDaemonClient()
        daemon.install(["Debian-13", "Ubuntu-24.04"])
        let store = SettingsStore(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "maw-menu-\(UUID().uuidString).json"))
        let provider = daemon.provider()
        let controller = AppController(settingsStore: store, distributions: provider)
        let bar = MenuBuilder(registry: controller.currentRegistry, target: controller).build()
        let menu = try #require(
            bar.items.compactMap(\.submenu).first { $0.delegate === controller })
        func titles() -> [String] {
            menu.items.compactMap { item in
                guard let box = item.representedObject as? CommandBox,
                    case .newTab = box.id
                else { return nil }
                return item.title
            }
        }
        let local = store.settings.localShellProfile.paletteName
        #expect(titles() == ["New Tab", "New Tab: \(local)"])
        let others = menu.items.map(\.title).filter { !$0.hasPrefix("New Tab") }

        controller.menuWillOpen(NSMenu(title: "Edit"))
        #expect(daemon.record.withLock { $0.connects } == 0)
        controller.menuWillOpen(menu)
        await provider.pending?.value
        #expect(daemon.record.withLock { $0.connects } == 1)
        MenuBuilder(registry: controller.currentRegistry, target: controller)
            .replaceNewTabItems(in: menu)
        #expect(
            titles() == [
                "New Tab", "New Tab: Debian-13", "New Tab: Ubuntu-24.04", "New Tab: \(local)",
            ])
        #expect(menu.items.map(\.title).filter { !$0.hasPrefix("New Tab") } == others)
        #expect(menu.items.first { $0.title == "New Tab" }?.keyEquivalent == "t")
    }

    /// The item of ⌘T comes first, and the others keep the profiles' order: with a listed
    /// distribution as the new-tab profile, and with one that the list does not contain.
    @Test func theNewTabItemOfCommandTComesFirst() throws {
        _ = NSApplication.shared
        let profiles = Settings().profiles(distributions: ["Debian-13", "Ubuntu-24.04"])
        let local = Settings().localShellProfile.paletteName
        func titles(_ newTabProfile: Profile) throws -> [String] {
            let registry = CommandRegistry(profiles: profiles, newTabProfile: newTabProfile)
            let controller = AppController(
                settingsStore: SettingsStore(
                    fileURL: FileManager.default.temporaryDirectory
                        .appending(path: "maw-menu-\(UUID().uuidString).json")),
                distributions: FakeDaemonClient().provider())
            let menu = try #require(
                MenuBuilder(registry: registry, target: controller).build().items
                    .compactMap(\.submenu).first { $0.delegate === controller })
            return menu.items.compactMap { item in
                guard let box = item.representedObject as? CommandBox, box.id.isNewTab
                else { return nil }
                return item.keyEquivalent == "t" ? "⌘T \(item.title)" : item.title
            }
        }
        #expect(
            try titles(.distribution("Ubuntu-24.04")) == [
                "⌘T New Tab", "New Tab: default distribution", "New Tab: Debian-13",
                "New Tab: \(local)",
            ])
        #expect(
            try titles(.distribution("Fedora-42")) == [
                "⌘T New Tab", "New Tab: default distribution", "New Tab: Debian-13",
                "New Tab: Ubuntu-24.04", "New Tab: \(local)",
            ])
    }
}
