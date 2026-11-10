import AppKit
import Darwin
import MawClient
import MawCore
import MawXPC
import Testing
import os

@testable import MawTerminalKit

/// A daemon that answers `listDistributions` as the test sets it, and records each connection.
final class FakeDaemonClient: DaemonRequests, @unchecked Sendable {
    struct Record {
        var connects = 0
        var lists = 0
        var closes = 0
        /// Connections made on the main thread, which must not happen.
        var connectsOnMain = 0
    }

    let record = OSAllocatedUnfairLock(initialState: Record())
    /// What connecting throws, such as an unreachable daemon, or `nil` to connect.
    let connectFailure = OSAllocatedUnfairLock<MawError?>(initialState: nil)
    let answer = OSAllocatedUnfairLock<Result<DistributionList, MawError>>(
        initialState: .success(DistributionList(distributions: [], defaultDistribution: nil)))
    /// How long each answer takes.
    let delay = OSAllocatedUnfairLock(initialState: Duration.zero)

    /// Installed distributions, all stopped, with the first as the default.
    func install(_ names: [String], states: [DistributionState] = []) {
        let entries = names.enumerated().map { index, name in
            DistributionEntry(
                name: try! DistroName(name),
                state: states.indices.contains(index) ? states[index] : .stopped)
        }
        answer.withLock {
            $0 = .success(
                DistributionList(distributions: entries, defaultDistribution: entries.first?.name))
        }
    }

    func listDistributions() async throws(MawError) -> DistributionList {
        record.withLock { $0.lists += 1 }
        let delay = self.delay.withLock { $0 }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return try answer.withLock { $0 }.get()
    }

    func close() {
        record.withLock { $0.closes += 1 }
    }

    var connector: DaemonDistributions.Connector {
        { () async throws(MawError) -> any DaemonRequests in
            self.record.withLock {
                $0.connects += 1
                if pthread_main_np() != 0 { $0.connectsOnMain += 1 }
            }
            if let failure = self.connectFailure.withLock({ $0 }) { throw failure }
            return self
        }
    }

    /// A provider that asks this daemon, and has not asked yet.
    @MainActor func provider() -> DaemonDistributions {
        DaemonDistributions(connect: connector)
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
}
