import AppKit
import MawClient
import MawCore
import MawXPC
import Testing
import os

@testable import MawTerminalKit

/// A sleep that waits until the test opens it, and records each delay it was asked for. A
/// cancelled sleep ends at once.
final class SleepGate: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(
        initialState: (delays: [Duration](), waiting: [UUID: CheckedContinuation<Void, Never>]()))

    var sleep: DaemonDistributions.Sleep {
        { [self] delay in
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    state.withLock {
                        $0.delays.append(delay)
                        $0.waiting[id] = continuation
                    }
                }
            } onCancel: {
                state.withLock { $0.waiting.removeValue(forKey: id) }?.resume()
            }
            try Task.checkCancellation()
        }
    }

    var delays: [Duration] { state.withLock { $0.delays } }
    var isWaiting: Bool { state.withLock { !$0.waiting.isEmpty } }

    func open() {
        let waiting = state.withLock {
            defer { $0.waiting = [:] }
            return $0.waiting
        }
        for continuation in waiting.values { continuation.resume() }
    }
}

/// A distribution in a snapshot, with the figures a test gives it.
func figures(
    _ name: String = "Ubuntu-24.04", state: DistributionState = .running, run: UInt64? = 1,
    sample: UInt64? = nil, memory: UInt64? = nil
) -> DistributionFigures {
    var figures = DistributionFigures(
        name: try! DistroName(name), state: state, defaultUser: "ayse",
        diskImagePath: "/Users/ayse/Library/Application Support/maw/distros/\(name)/disk.img")
    figures.diskAllocatedBytes = 2_362_232_012
    figures.diskSizeBytes = 274_877_906_944
    figures.kernelRelease = "6.18.57-maw"
    if state == .running {
        figures.run = run
        figures.sampleNumber = sample
        figures.memoryUsedBytes = memory
    }
    return figures
}

/// The provider's watch, its retries, and the memory history.
@MainActor
@Suite struct DistributionWatchTests {
    /// Two windows, kept alive so that their identifiers differ.
    let windows = (NSObject(), NSObject())
    var window: ObjectIdentifier { ObjectIdentifier(windows.0) }
    var other: ObjectIdentifier { ObjectIdentifier(windows.1) }

    func record(_ daemon: FakeDaemonClient) -> FakeDaemonClient.Record {
        daemon.record.withLock { $0 }
    }

    // MARK: One watch

    /// Every window that shows the screen shares one connection and one request stream; the
    /// last one to stop showing it closes the connection, and the next starts a new watch.
    @Test func oneWatchServesEveryWindowAndEndsWithTheLast() async {
        let daemon = FakeDaemonClient()
        daemon.publish([figures(sample: 1, memory: 412 << 20)])
        let provider = daemon.provider()
        provider.setScreenVisible(true, in: window)
        provider.setScreenVisible(true, in: other)
        provider.setScreenVisible(true, in: window)
        #expect(await waitUntil(seconds: 5) { provider.distributions.first?.memory == "412M" })
        #expect(record(daemon).watchingConnections == 1)
        #expect(record(daemon).connectsOnMain == 0)

        provider.setScreenVisible(false, in: window)
        #expect(provider.watch != nil)
        #expect(record(daemon).openWatchingConnections == 1)
        let watching = provider.watch
        provider.setScreenVisible(false, in: other)
        await watching?.value
        #expect(provider.watch == nil)
        #expect(record(daemon).openWatchingConnections == 0)
        #expect(record(daemon).connects == record(daemon).closes)
        // The figures and the history are forgotten; the rows keep their state.
        #expect(
            provider.distributions == [
                DistributionInfo(name: "Ubuntu-24.04", state: .running, isDefault: true)
            ])

        provider.setScreenVisible(true, in: other)
        #expect(await waitUntil(seconds: 5) { record(daemon).watchingConnections == 2 })
        // Each connection's watch starts from its first snapshot.
        #expect(
            await waitUntil(seconds: 5) { record(daemon).watches.filter { $0 == 0 }.count == 2 })
        provider.setScreenVisible(false, in: other)
    }

    /// While a screen is visible, the watch keeps the list current, so a refresh asks nothing.
    @Test func aRefreshAsksNothingWhileTheScreenIsVisible() async {
        let daemon = FakeDaemonClient()
        daemon.install(["Ubuntu-24.04"])
        let provider = daemon.provider()
        provider.setScreenVisible(true, in: window)
        #expect(await waitUntil(seconds: 5) { provider.hasAnswer })
        provider.refresh()
        #expect(provider.pending == nil)
        #expect(record(daemon).lists == 0)
        provider.setScreenVisible(false, in: window)
        await provider.refreshed()
        #expect(record(daemon).lists == 1)
    }

    /// A list asked for before the watch started does not replace the watch's figures.
    @Test func aListThatArrivesDuringAWatchIsNotApplied() async {
        let daemon = FakeDaemonClient()
        daemon.install(["Ubuntu-24.04"], states: [.running])
        daemon.delay.withLock { $0 = .milliseconds(100) }
        daemon.publish([figures(sample: 1, memory: 1 << 30)])
        let provider = daemon.provider()
        provider.refresh()
        provider.setScreenVisible(true, in: window)
        await provider.pending?.value
        #expect(await waitUntil(seconds: 5) { provider.distributions.first?.memory != nil })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(provider.distributions.first?.memory == "1.0G")
        provider.setScreenVisible(false, in: window)
    }

    // MARK: Retries

    /// While the daemon cannot be reached, the error stays shown, and the attempts wait 1, 2,
    /// 4, 8, 16, then 30 seconds; a connection that delivered two snapshots starts the delays
    /// again from the first.
    @Test func retriesWithAGrowingDelayWhileTheErrorStaysShown() async throws {
        let daemon = FakeDaemonClient()
        let error = MawError.daemonUnreachable(reason: "the connection was invalidated")
        daemon.connectFailure.withLock { $0 = error }
        let gate = SleepGate()
        let provider = daemon.provider(sleep: gate.sleep)
        provider.setScreenVisible(true, in: window)
        let expected: [Duration] = [1, 2, 4, 8, 16, 30, 30].map { .seconds($0) }
        for attempt in 1...expected.count {
            #expect(await waitUntil(seconds: 5) { gate.delays.count == attempt && gate.isWaiting })
            #expect(record(daemon).connects == attempt)
            #expect(provider.failure == error && provider.distributions.isEmpty)
            #expect(provider.hasAnswer)
            if attempt < expected.count { gate.open() }
        }
        #expect(gate.delays == expected)

        daemon.connectFailure.withLock { $0 = nil }
        daemon.publish([figures(sample: 1, memory: 1 << 20)])
        gate.open()
        #expect(await waitUntil(seconds: 5) { provider.failure == nil })
        #expect(provider.distributions.map(\.name) == ["Ubuntu-24.04"])
        daemon.publish([figures(sample: 2, memory: 2 << 20)])
        #expect(
            await waitUntil(seconds: 5) { provider.distributions.first?.memoryHistory.count == 2 })

        let lost = MawError.daemonConnectionLost(during: "watchDistributions")
        daemon.watchFailure.withLock { $0 = lost }
        #expect(await waitUntil(seconds: 5) { gate.delays.count == expected.count + 1 })
        #expect(gate.delays.last == .seconds(1))
        #expect(provider.failure == lost && provider.distributions.isEmpty)

        // Hiding the screen stops the attempts; showing it starts again from the shortest.
        let watching = provider.watch
        provider.setScreenVisible(false, in: window)
        await watching?.value
        let connects = record(daemon).connects
        gate.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(record(daemon).connects == connects)
        provider.setScreenVisible(true, in: window)
        #expect(await waitUntil(seconds: 5) { gate.delays.count == expected.count + 2 })
        #expect(gate.delays.last == .seconds(1))
        provider.setScreenVisible(false, in: window)
    }

    /// A daemon that answers once and then fails does not reset the delays.
    @Test func oneSnapshotThenAFailureKeepsTheDelayGrowing() async {
        let daemon = FakeDaemonClient()
        let gate = SleepGate()
        let provider = daemon.provider(sleep: gate.sleep)
        daemon.connectFailure.withLock { $0 = .daemonUnreachable(reason: "test") }
        provider.setScreenVisible(true, in: window)
        #expect(await waitUntil(seconds: 5) { gate.delays.count == 1 && gate.isWaiting })
        daemon.connectFailure.withLock { $0 = nil }
        daemon.publish([figures(sample: 1, memory: 1 << 20)])
        gate.open()
        #expect(await waitUntil(seconds: 5) { provider.failure == nil })
        daemon.watchFailure.withLock { $0 = .daemonConnectionLost(during: "watchDistributions") }
        #expect(await waitUntil(seconds: 5) { gate.delays.count == 2 && gate.isWaiting })
        #expect(gate.delays == [.seconds(1), .seconds(2)])
        provider.setScreenVisible(false, in: window)
    }

    /// While the attempts wait, a refresh (⌘⇧L on the screen, or an action) tries again at
    /// once, from the shortest delay.
    @Test func aRefreshTriesAgainAtOnceWhileTheAttemptsWait() async {
        let daemon = FakeDaemonClient()
        let gate = SleepGate()
        let provider = daemon.provider(sleep: gate.sleep)
        daemon.connectFailure.withLock { $0 = .daemonUnreachable(reason: "test") }
        provider.setScreenVisible(true, in: window)
        for attempt in 1...3 {
            #expect(await waitUntil(seconds: 5) { gate.delays.count == attempt && gate.isWaiting })
            if attempt < 3 { gate.open() }
        }
        #expect(gate.delays.last == .seconds(4))
        provider.refresh()
        #expect(await waitUntil(seconds: 5) { record(daemon).connects == 4 })
        #expect(await waitUntil(seconds: 5) { gate.delays.count == 4 })
        #expect(gate.delays.last == .seconds(1))
        #expect(record(daemon).lists == 0)
        daemon.connectFailure.withLock { $0 = nil }
        daemon.install(["Ubuntu-24.04"])
        provider.refresh()
        #expect(await waitUntil(seconds: 5) { provider.failure == nil && provider.hasAnswer })
        // While the watch answers, a refresh asks nothing.
        let connects = record(daemon).connects
        provider.refresh()
        #expect(record(daemon).connects == connects && record(daemon).lists == 0)
        provider.setScreenVisible(false, in: window)
    }

    /// A watch that ends while it fails reads the list once, so that the profiles of every
    /// window do not keep the failure.
    @Test func aWatchThatEndsWhileItFailsReadsTheList() async {
        let daemon = FakeDaemonClient()
        daemon.install(["Ubuntu-24.04"])
        daemon.watchFailure.withLock { $0 = .daemonConnectionLost(during: "watchDistributions") }
        let gate = SleepGate()
        let provider = daemon.provider(sleep: gate.sleep)
        provider.setScreenVisible(true, in: window)
        #expect(await waitUntil(seconds: 5) { provider.failure != nil && gate.isWaiting })
        daemon.watchFailure.withLock { $0 = nil }
        provider.setScreenVisible(false, in: window)
        await provider.pending?.value
        #expect(record(daemon).lists == 1)
        #expect(provider.failure == nil && provider.distributions.map(\.name) == ["Ubuntu-24.04"])
    }

    // MARK: History

    func history(_ snapshots: [DistributionFigures]) -> [UInt64?] {
        var history = MemoryHistory()
        for figures in snapshots { history.record(figures) }
        return history.values
    }

    @Test func aSampleAddsOneBarAndTheSameSampleNone() {
        #expect(
            history([
                figures(sample: 1, memory: 10), figures(sample: 1, memory: 10),
                figures(sample: 2, memory: 20),
            ]) == [10, 20])
        // A snapshot before the first sample adds nothing.
        #expect(history([figures(sample: nil)]).isEmpty)
    }

    /// A sample whose memory could not be read keeps its slot, empty.
    @Test func aFailedSampleAddsAnEmptyBar() {
        #expect(
            history([
                figures(sample: 1, memory: 10), figures(sample: 2, memory: nil),
                figures(sample: 3, memory: 30),
            ]) == [10, nil, 30])
    }

    /// The first number seen adds one bar, whatever its value.
    @Test func theFirstNumberOfAWatchAddsOneBar() {
        #expect(history([figures(sample: 7, memory: 70)]) == [70])
    }

    @Test func aJumpAddsEmptySlotsWithinTheLimit() {
        #expect(
            history([figures(sample: 1, memory: 10), figures(sample: 4, memory: 40)])
                == [10, nil, nil, 40])
        let far = history([figures(sample: 1, memory: 10), figures(sample: 100, memory: 99)])
        #expect(far.count == DaemonDistributions.historyLength)
        #expect(far.last == 99 && far.dropLast().allSatisfy { $0 == nil })
    }

    @Test func keepsTheLast40Samples() {
        let values = history((1...50).map { figures(sample: UInt64($0), memory: UInt64($0)) })
        #expect(values == (11...50).map { UInt64($0) })
    }

    /// A new run, and a machine that leaves the running state, start from nothing.
    @Test func aNewRunOrAStopStartsAgain() {
        #expect(
            history([
                figures(run: 1, sample: 1, memory: 10), figures(run: 1, sample: 2, memory: 20),
                figures(run: 2, sample: 5, memory: 50),
            ]) == [50])
        #expect(
            history([
                figures(sample: 1, memory: 10), figures(state: .stopping),
                figures(sample: 2, memory: 20),
            ]) == [20])
    }

    /// A watch that stops and starts again in the same run starts its history from its first
    /// number, without the bars of the earlier watch.
    @Test func aNewWatchInTheSameRunStartsTheHistoryAgain() async {
        let daemon = FakeDaemonClient()
        daemon.publish([figures(sample: 1, memory: 10)])
        let provider = daemon.provider()
        provider.setScreenVisible(true, in: window)
        daemon.publish([figures(sample: 2, memory: 20)])
        #expect(
            await waitUntil(seconds: 5) { provider.distributions.first?.memoryHistory.last == 20 })
        let watching = provider.watch
        provider.setScreenVisible(false, in: window)
        await watching?.value
        #expect(provider.distributions.first?.memoryHistory == [])
        daemon.publish([figures(sample: 5, memory: 50)])
        provider.setScreenVisible(true, in: window)
        #expect(
            await waitUntil(seconds: 5) { provider.distributions.first?.memoryHistory == [50] })
        provider.setScreenVisible(false, in: window)
    }

    // MARK: Rows

    @Test func theFourStates() {
        func row(_ state: DistributionState) -> DistributionInfo {
            var running = figures(state: state, sample: 2, memory: 412 << 20)
            if state == .running {
                running.cpuPercent = 0.4
                running.uptimeMilliseconds = 8_040_000
                running.bootMilliseconds = 271
                running.ipv4Address = "192.168.64.3"
                running.hostMemoryBytes = 710 << 20
                running.memoryLimitBytes = 8 << 30
            }
            return DaemonDistributions.make(
                running, isDefault: state == .running, history: [412 << 20],
                home: "/Users/ayse")
        }
        let image = "~/Library/Application Support/maw/distros/Ubuntu-24.04/disk.img"
        let running = row(.running)
        #expect(running.memory == "412M" && running.cpu == "0.4%")
        #expect(running.disk == "2.2G/256G" && running.uptime == "2h 14m")
        #expect(running.kernel == "6.18.57-maw")
        #expect(
            running.details == [
                .init("default", "yes", role: .positive), .init("user", "ayse"),
                .init("ip", "192.168.64.3", role: .number), .init("disk image", image),
                .init("boot", "271 ms to agent", role: .timing),
                .init("host memory", "710M", role: .number),
            ])
        #expect(running.memoryHistory == [412 << 20] && running.memoryLimit == 8 << 30)
        for state in [DistributionState.starting, .stopping, .stopped] {
            let row = row(state)
            #expect(row.state.rawValue == state.rawValue)
            #expect(row.memory == nil && row.cpu == nil && row.uptime == nil)
            #expect(row.disk == "2.2G/256G" && row.kernel == "6.18.57-maw")
            #expect(
                row.details == [
                    .init("default", "no", role: .muted), .init("user", "ayse"),
                    .init("disk image", image),
                ])
            #expect(row.memoryHistory.isEmpty && row.memoryLimit == nil)
        }
    }

    /// A figure that the daemon did not report is left out, never a placeholder.
    @Test func unknownFiguresAreLeftOut() {
        var running = figures(sample: 1)
        running.diskSizeBytes = nil
        running.kernelRelease = nil
        let row = DaemonDistributions.make(running, isDefault: false, history: [nil], home: "/")
        #expect(row.memory == nil && row.cpu == nil && row.disk == nil && row.uptime == nil)
        #expect(row.kernel == nil)
        #expect(row.details.map(\.key) == ["default", "user", "disk image"])
        #expect(!MemoryChartBox.hasData(row))
        #expect(MemoryChartBox.caption(row) == "")
    }

    @Test func theFormats() {
        #expect(FigureFormat.bytes(512) == "512B")
        #expect(FigureFormat.bytes(412 << 20) == "412M")
        #expect(FigureFormat.bytes(1_288_490_189) == "1.2G")
        #expect(FigureFormat.bytes(256 << 30) == "256G")
        #expect(FigureFormat.bytes(8 << 30) == "8.0G")
        #expect(FigureFormat.bytes(1023 << 20 + 1000 << 10) == "1.0G")
        #expect(FigureFormat.percent(0.44) == "0.4%")
        #expect(FigureFormat.percent(9.96) == "10%")
        #expect(FigureFormat.percent(37.2) == "37%")
        #expect(FigureFormat.percent(180.4) == "180%")
        #expect(FigureFormat.uptime(37_900) == "37s")
        #expect(FigureFormat.uptime(41 * 60_000) == "41m")
        #expect(FigureFormat.uptime((2 * 60 + 14) * 60_000) == "2h 14m")
        #expect(FigureFormat.uptime((3 * 24 + 2) * 3_600_000 + 59_000) == "3d 2h")
        #expect(FigureFormat.path("/Users/ayse/a/disk.img", home: "/Users/ayse/") == "~/a/disk.img")
        #expect(
            FigureFormat.path("/Users/ayser/disk.img", home: "/Users/ayse")
                == "/Users/ayser/disk.img")
    }

    /// The caption names only the figures that are known.
    @Test func theCaptionWithoutUnknownFigures() {
        var row = DistributionInfo(name: "Ubuntu-24.04", state: .running)
        #expect(MemoryChartBox.caption(row) == "")
        row.memoryLimit = 8 << 30
        #expect(MemoryChartBox.caption(row) == "8.0G limit")
        row.memory = "412M"
        #expect(MemoryChartBox.caption(row) == "412M now · 8.0G limit")
        row.memoryLimit = nil
        #expect(MemoryChartBox.caption(row) == "412M now")
    }

    /// The chart has 40 slots, newest on the right, and appears once a sample has memory.
    @Test func theChartFillsFromTheRight() {
        let slots = MemoryChartBox.slots([nil, 5])
        #expect(slots.count == 40 && slots.suffix(2) == [nil, 5])
        #expect(slots.dropLast(2).allSatisfy { $0 == nil })
        #expect(!MemoryChartBox.hasData(DistributionInfo(name: "a", state: .running)))
        #expect(
            MemoryChartBox.hasData(
                DistributionInfo(name: "a", state: .running, memoryHistory: [nil, 5])))
    }

    // MARK: Windows

    /// A window shows the screen while the screen is its selected tab and the window is
    /// visible; the watch runs while any window shows it, as one stream.
    @Test func theWatchFollowsTheWindowsThatShowTheScreen() async {
        let daemon = FakeDaemonClient()
        daemon.install(["Ubuntu-24.04"], states: [.running])
        let provider = daemon.provider()
        let (first, _, _) = WindowModelTests().window(distributions: provider)
        let (second, _, _) = WindowModelTests().window(distributions: provider)
        func open() -> Int { record(daemon).openWatchingConnections }

        first.perform(.openDistributions)
        await provider.pending?.value
        // Selected but not visible: the list is read once, and nothing is watched.
        #expect(provider.watch == nil && record(daemon).lists == 1)
        first.isWindowVisible = true
        #expect(await waitUntil(seconds: 5) { open() == 1 })
        second.isWindowVisible = true
        second.perform(.openDistributions)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(record(daemon).watchingConnections == 1 && open() == 1)

        // Another tab in the first window, then the second window minimized or covered.
        first.perform(.back)
        #expect(provider.watch != nil)
        second.isWindowVisible = false
        #expect(await waitUntil(seconds: 5) { open() == 0 })
        #expect(provider.watch == nil)

        second.isWindowVisible = true
        #expect(await waitUntil(seconds: 5) { open() == 1 })
        #expect(record(daemon).watchingConnections == 2)
        // A window that closes stops showing the screen.
        second.shutDown()
        #expect(await waitUntil(seconds: 5) { open() == 0 })
        first.shutDown()
    }

    /// A minimized window, and one whose occlusion state is not visible, does not show the
    /// screen.
    @Test func aWindowIsVisibleOnlyWhenOnScreenAndNotMinimized() {
        #expect(TerminalWindowController.isVisible([.visible], miniaturized: false))
        #expect(!TerminalWindowController.isVisible([], miniaturized: false))
        #expect(!TerminalWindowController.isVisible([.visible], miniaturized: true))
        #expect(!TerminalWindowController.isVisible([], miniaturized: true))
    }

    /// While the daemon cannot be reached and the attempts go on, the screen shows maw's
    /// message and suggestion, as in phase 11b.
    @Test func theScreenShowsTheErrorWhileTheAttemptsGoOn() async {
        let daemon = FakeDaemonClient()
        let error = MawError.daemonNotInstalled(label: "dev.maw.mawd")
        daemon.connectFailure.withLock { $0 = error }
        let gate = SleepGate()
        let provider = daemon.provider(sleep: gate.sleep)
        let (model, _, _) = WindowModelTests().window(distributions: provider)
        model.isWindowVisible = true
        model.perform(.openDistributions)
        let shown = DistributionListing.failed(runtimeErrorText(error))
        for attempt in 1...3 {
            #expect(await waitUntil(seconds: 5) { gate.delays.count == attempt && gate.isWaiting })
            #expect(model.distributionListing == shown)
            gate.open()
            await Task.yield()
            #expect(model.distributionListing == shown)
        }
        model.shutDown()
    }

    /// The selection stays on its distribution while the snapshots change the rows.
    @Test func theSelectionStaysOnItsDistribution() async {
        let daemon = FakeDaemonClient()
        daemon.publish([figures("Alpine-3.22"), figures("Ubuntu-24.04")])
        let provider = daemon.provider()
        let (model, _, _) = WindowModelTests().window(distributions: provider)
        model.isWindowVisible = true
        model.perform(.openDistributions)
        #expect(await waitUntil(seconds: 5) { provider.distributions.count == 2 })
        model.selectDistribution("Ubuntu-24.04")
        daemon.publish(
            [
                figures("Alpine-3.22"), figures("Debian-13"),
                figures("Ubuntu-24.04", sample: 1, memory: 1 << 30),
            ], default: "Alpine-3.22")
        #expect(await waitUntil(seconds: 5) { provider.distributions.count == 3 })
        #expect(model.selectedDistribution?.name == "Ubuntu-24.04")
        #expect(model.selectedDistribution?.memory == "1.0G")
        model.shutDown()
    }
}
