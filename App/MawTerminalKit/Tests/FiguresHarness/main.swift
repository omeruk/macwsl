import AppKit
import Darwin
import Foundation
import MawCore
import MawTerminalKit

// The terminal app's measurements of phase 11c (prompts/11c-distribution-figures.md, "Speed
// targets" and "Limits on cost"), in-process: real windows that show the distributions screen,
// with the app's provider and window code, against the daemon that MAW_DAEMON_LABEL names.
// Tests/mawdTests/AppFigureMeasurements.swift runs it through scripts/measure-figures.sh, which
// builds it and signs it as the app (dev.maw.app); nothing installs it. It refuses to run
// without MAW_DAEMON_LABEL, so that it never watches the installed daemon. Each run makes one
// measurement and prints its results on lines that start with "value: ", and then "done".
//
// Usage:
//   maw-figures-harness first-figures <distribution>
//   maw-figures-harness state-change <distribution> <maw>
//   maw-figures-harness cost <distribution>
//   maw-figures-harness windows <count>

/// The app's provider, which notes when a window first shows the screen.
@MainActor
final class TimedProvider: DistributionProvider {
    let base = DaemonDistributions()
    private(set) var shownAt: ContinuousClock.Instant?

    var distributions: [DistributionInfo] { base.distributions }
    var failure: MawError? { base.failure }
    var hasAnswer: Bool { base.hasAnswer }
    func refresh() { base.refresh() }

    func setScreenVisible(_ visible: Bool, in window: ObjectIdentifier) {
        if visible, shownAt == nil { shownAt = .now }
        base.setScreenVisible(visible, in: window)
    }

    func openSessions(in name: String) async throws(MawError) -> Int {
        try await base.openSessions(in: name)
    }

    func setDefault(_ name: String) async throws(MawError) {
        try await base.setDefault(name)
    }

    func stop(_ name: String) async throws(MawError) {
        try await base.stop(name)
    }
}

struct HarnessFailure: Error, CustomStringConvertible {
    var description: String
}

@MainActor
struct Harness {
    let provider = TimedProvider()
    let store: SettingsStore

    init() {
        // Settings of its own, whose new tab is the local shell, so that a window opens no
        // Linux session.
        let file = FileManager.default.temporaryDirectory
            .appending(path: "maw-figures-harness-\(getpid()).json")
        store = SettingsStore(fileURL: file)
        store.update { $0.defaultProfile = "local" }
        try? FileManager.default.removeItem(at: file)
    }

    /// A window on screen, at `offset` steps from the first so that each stays partly visible.
    func window(offset: Int = 0) async throws -> (NSWindowController, WindowModel) {
        let (controller, model) = makeTerminalWindow(settingsStore: store, distributions: provider)
        guard let window = controller.window else { throw HarnessFailure(description: "no window") }
        window.setFrameAutosaveName("")
        window.setFrame(
            NSRect(x: 80 + offset * 60, y: 80 + offset * 60, width: 1100, height: 700),
            display: true)
        // Above other apps' windows: an app started from a shell is not made active (macOS 14
        // and later), and its window would be covered, and so not visible, behind theirs.
        window.level = .floating
        controller.showWindow(nil)
        window.orderFrontRegardless()
        try await until("the window is visible", within: .seconds(10)) { model.isWindowVisible }
        return (controller, model)
    }

    func row(_ name: String) -> DistributionInfo? {
        provider.distributions.first { $0.name == name }
    }

    /// Checks `condition` every millisecond until it holds.
    func until(
        _ what: String, within timeout: Duration, _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw HarnessFailure(description: "\(what) did not happen within \(timeout)")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    static func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return String(format: "%.3f", Double(seconds) * 1e3 + Double(attoseconds) / 1e15)
    }

    /// From the screen becoming visible to the first DISK, UPTIME, KERNEL, and MEMORY of a
    /// running distribution, and to its first CPU.
    func firstFigures(_ name: String) async throws {
        let (_, model) = try await window()
        model.perform(.openDistributions)
        try await until("the first figures", within: .seconds(10)) {
            guard let row = row(name) else { return false }
            return row.disk != nil && row.uptime != nil && row.kernel != nil && row.memory != nil
        }
        let figures = ContinuousClock.now
        try await until("the first CPU figure", within: .seconds(10)) { row(name)?.cpu != nil }
        let cpu = ContinuousClock.now
        guard let shown = provider.shownAt else {
            throw HarnessFailure(description: "the screen was never shown")
        }
        print("value: first-figures \(Self.milliseconds(figures - shown))")
        print("value: first-cpu \(Self.milliseconds(cpu - shown))")
    }

    /// From just before `maw --terminate` runs to the provider's new state.
    func stateChange(_ name: String, maw: String) async throws {
        let (_, model) = try await window()
        model.perform(.openDistributions)
        try await until("the running state", within: .seconds(10)) {
            row(name)?.state == .running && row(name)?.memory != nil
        }
        let terminate = Process()
        terminate.executableURL = URL(filePath: maw)
        terminate.arguments = ["--terminate", name]
        terminate.standardOutput = FileHandle.nullDevice
        let start = ContinuousClock.now
        try terminate.run()
        try await until("the new state", within: .seconds(10)) { row(name)?.state != .running }
        let changed = ContinuousClock.now
        print("value: state-change \(Self.milliseconds(changed - start))")
        while terminate.isRunning { try await Task.sleep(for: .milliseconds(50)) }
    }

    /// The app's CPU time over 60 seconds with the screen visible and one distribution running,
    /// then over 60 seconds with another tab selected, in percent of one core.
    func cost(_ name: String) async throws {
        let (_, model) = try await window()
        model.perform(.openDistributions)
        try await until("the first CPU figure", within: .seconds(10)) { row(name)?.cpu != nil }
        try await Task.sleep(for: .seconds(5))
        let shown = try await cpu(over: .seconds(60))
        model.perform(.back)
        try await Task.sleep(for: .seconds(5))
        let hidden = try await cpu(over: .seconds(60))
        print("value: cost-shown \(String(format: "%.4f", shown))")
        print("value: cost-hidden \(String(format: "%.4f", hidden))")
        print("value: cost-above-hidden \(String(format: "%.4f", shown - hidden))")
    }

    func cpu(over duration: Duration) async throws -> Double {
        func used() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        let (before, start) = (used(), ContinuousClock.now)
        try await Task.sleep(for: duration)
        let elapsed = ContinuousClock.now - start
        let seconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return (used() - before) / seconds * 100
    }

    /// `count` windows show the screen, then none does. The daemon's log must name this
    /// process once as starting and once as stopping to watch.
    func windows(_ count: Int) async throws {
        var windows: [(NSWindowController, WindowModel)] = []
        for offset in 0..<count {
            let window = try await window(offset: offset)
            window.1.perform(.openDistributions)
            windows.append(window)
        }
        try await until("an answer", within: .seconds(10)) { provider.hasAnswer }
        let visible = windows.filter { $0.1.isWindowVisible }.count
        try await Task.sleep(for: .seconds(3))
        for (_, model) in windows {
            model.perform(.back)
        }
        try await Task.sleep(for: .seconds(3))
        print("value: windows-visible \(visible)")
        print("value: pid \(getpid())")
    }
}

@MainActor
func run(_ arguments: [String]) async -> Int32 {
    guard let label = ProcessInfo.processInfo.environment["MAW_DAEMON_LABEL"], !label.isEmpty,
        label != "dev.maw.mawd"
    else {
        FileHandle.standardError.write(
            Data("maw-figures-harness: MAW_DAEMON_LABEL must name the test daemon\n".utf8))
        return 64
    }
    let harness = Harness()
    let words = Array(arguments.dropFirst())
    do {
        switch (words.first, words.count) {
        case ("first-figures", 2): try await harness.firstFigures(words[1])
        case ("state-change", 3): try await harness.stateChange(words[1], maw: words[2])
        case ("cost", 2): try await harness.cost(words[1])
        case ("windows", 2) where Int(words[1]) != nil:
            try await harness.windows(Int(words[1]) ?? 1)
        default:
            FileHandle.standardError.write(Data("maw-figures-harness: unknown arguments\n".utf8))
            return 64
        }
    } catch {
        FileHandle.standardError.write(Data("maw-figures-harness: \(error)\n".utf8))
        return 1
    }
    return 0
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
Task { @MainActor in
    let status = await run(CommandLine.arguments)
    // The last line, which tells the caller that it has read every value.
    print("done")
    fflush(stdout)
    exit(status)
}
application.activate()
application.run()
