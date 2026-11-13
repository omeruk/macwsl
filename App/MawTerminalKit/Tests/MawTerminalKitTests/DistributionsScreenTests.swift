import AppKit
import MawClient
import MawCore
import MawXPC
import Testing

@testable import MawTerminalKit

/// The distributions screen against a fake daemon client: what it shows, its selection, and
/// its actions.
@MainActor
@Suite struct DistributionsScreenTests {
    typealias FakeHost = WindowModelTests.FakeHost

    let shell = CommandID.shellInDistribution
    let stop = CommandID.stopDistribution
    let setDefault = CommandID.setDefaultDistribution

    /// A window showing the distributions screen, once the daemon has answered. A window that
    /// is not `visible` reads the list; a visible one watches.
    func screen(_ daemon: FakeDaemonClient, visible: Bool = false) async -> (
        model: WindowModel, host: FakeHost, provider: DaemonDistributions, asked: () -> [Profile]
    ) {
        let provider = daemon.provider()
        let (model, host, asked) = WindowModelTests().window(distributions: provider)
        model.isWindowVisible = visible
        model.perform(.openDistributions)
        await provider.pending?.value
        if visible { _ = await waitUntil(seconds: 5) { provider.hasAnswer } }
        return (model, host, provider, asked)
    }

    /// Performs a command of the screen, and waits for its requests and the refresh after it.
    func perform(_ command: CommandID, in model: WindowModel, _ provider: DaemonDistributions)
        async
    {
        model.perform(command)
        await model.distributionAction?.value
        await provider.pending?.value
    }

    func rows(_ model: WindowModel) -> [DistributionInfo] {
        guard case .listed(let rows) = model.distributionListing else { return [] }
        return rows
    }

    func row(_ name: String, in model: WindowModel) -> DistributionInfo? {
        rows(model).first { $0.name == name }
    }

    func hintKeys(_ model: WindowModel) -> [String] {
        model.registry.hints(in: model.context).map(\.keys)
    }

    func text(_ error: MawError) -> String {
        runtimeErrorText(error).trimmingCharacters(in: .newlines)
    }

    // MARK: What the screen shows

    @Test func theFourStatesAndTheDefaultMarkerAreListedWithoutFigures() async {
        let daemon = FakeDaemonClient()
        daemon.install(
            ["Alpine-3.22", "Debian-13", "Fedora-43", "Ubuntu-24.04"],
            states: [.starting, .running, .stopping, .stopped], default: "Debian-13")
        let (model, _, _, _) = await screen(daemon)
        #expect(
            model.distributionListing
                == .listed([
                    DistributionInfo(name: "Alpine-3.22", state: .starting),
                    DistributionInfo(name: "Debian-13", state: .running, isDefault: true),
                    DistributionInfo(name: "Fedora-43", state: .stopping),
                    DistributionInfo(name: "Ubuntu-24.04", state: .stopped),
                ]))
        // The figures of phase 11c are empty, not placeholders.
        for row in rows(model) {
            #expect(row.memory == nil && row.cpu == nil && row.disk == nil)
            #expect(row.uptime == nil && row.kernel == nil)
            #expect(row.details.isEmpty && row.memoryHistory.isEmpty && row.memoryLimit == nil)
        }
    }

    @Test func theActionsFollowTheSelectedDistributionsState() async {
        let daemon = FakeDaemonClient()
        daemon.install(
            ["Alpine-3.22", "Debian-13", "Fedora-43", "Ubuntu-24.04"],
            states: [.starting, .running, .stopping, .stopped], default: "Debian-13")
        let (model, _, _, _) = await screen(daemon)
        let expected: [(name: String, stop: Bool, setDefault: Bool)] = [
            ("Alpine-3.22", true, true), ("Debian-13", true, false),
            ("Fedora-43", false, true), ("Ubuntu-24.04", false, true),
        ]
        for (name, canStop, canSetDefault) in expected {
            model.selectDistribution(name)
            #expect(model.isEnabled(shell), "\(name)")
            #expect(model.isEnabled(stop) == canStop, "\(name)")
            #expect(model.isEnabled(setDefault) == canSetDefault, "\(name)")
            let hints = model.registry.hints(in: model.context)
            #expect(hints.map(\.keys) == ["↩", "s", "d", "i", "esc"])
            #expect(hints.map(\.isEnabled) == [true, canStop, canSetDefault, false, true])
        }
        #expect(!model.isEnabled(.installDistribution))
    }

    /// The daemon cannot be reached: maw's message and suggestion, never the empty state.
    @Test func anUnreachableDaemonIsNotTheEmptyState() async throws {
        let daemon = FakeDaemonClient()
        daemon.install(["Ubuntu-24.04"], states: [.running])
        let error = MawError.daemonUnreachable(reason: "the connection was invalidated")
        daemon.connectFailure.withLock { $0 = error }
        let provider = daemon.provider()
        let (model, host, _) = WindowModelTests().window(distributions: provider)
        // Before the daemon has answered, the screen claims nothing.
        #expect(model.distributionListing == .waiting)
        model.perform(.openDistributions)
        #expect(model.distributionListing == .waiting)
        await provider.pending?.value

        #expect(model.distributionListing == .failed(runtimeErrorText(error)))
        let suggestion = try #require(error.recoverySuggestion)
        #expect(runtimeErrorText(error) == "maw: \(error.description)\n\(suggestion)\n")
        #expect(model.selectedDistribution == nil)
        for command in [shell, stop, setDefault] {
            #expect(!model.isEnabled(command))
            await perform(command, in: model, provider)
        }
        #expect(daemon.record.withLock { $0.requests }.isEmpty)
        #expect(hintKeys(model) == ["i", "esc"])

        // ⌘⇧L on the screen asks again.
        daemon.connectFailure.withLock { $0 = nil }
        model.perform(.openDistributions)
        await provider.pending?.value
        #expect(
            rows(model) == [
                DistributionInfo(name: "Ubuntu-24.04", state: .running, isDefault: true)
            ])

        // The daemon goes away before an action: the failure is reported, and the screen
        // says why instead of showing an empty list.
        daemon.connectFailure.withLock { $0 = error }
        await perform(stop, in: model, provider)
        #expect(host.failures == [["Ubuntu-24.04 could not be stopped.", text(error)]])
        #expect(model.distributionListing == .failed(runtimeErrorText(error)))
        #expect(daemon.record.withLock { $0.requests }.isEmpty)
    }

    @Test func anEmptyListIsTheEmptyState() async {
        let daemon = FakeDaemonClient()
        let (model, host, provider, _) = await screen(daemon)
        #expect(model.distributionListing == .listed([]))
        #expect(model.selectedDistribution == nil)
        model.moveDistributionSelection(by: 1)
        #expect(model.selectedDistribution == nil)
        let hints = model.registry.hints(in: model.context)
        #expect(hints.map(\.keys) == ["i", "esc"])
        #expect(hints[0].note == "arrives in a later version" && !hints[0].isEnabled)
        for command in [shell, stop, setDefault] {
            await perform(command, in: model, provider)
        }
        #expect(daemon.record.withLock { $0.requests }.isEmpty)
        #expect(host.failures.isEmpty)
    }

    // MARK: Selection

    @Test func theSelectionStaysOnItsDistributionAcrossRefreshes() async {
        let daemon = FakeDaemonClient()
        daemon.install(["Alpine-3.22", "Debian-13", "Ubuntu-24.04"])
        let (model, _, provider, _) = await screen(daemon)
        #expect(model.selectedDistribution?.name == "Alpine-3.22")
        model.moveDistributionSelection(by: -1)
        #expect(model.selectedDistribution?.name == "Alpine-3.22")
        for _ in 1...3 { model.moveDistributionSelection(by: 1) }
        #expect(model.selectedDistribution?.name == "Ubuntu-24.04")

        // Other distributions come and go, and its row and state change: it stays selected.
        daemon.install(
            ["Arch", "Debian-13", "Ubuntu-24.04", "Void"],
            states: [.stopped, .stopped, .running], default: "Void")
        await provider.refreshed()
        #expect(
            model.selectedDistribution == DistributionInfo(name: "Ubuntu-24.04", state: .running))
        model.moveDistributionSelection(by: -1)
        #expect(model.selectedDistribution?.name == "Debian-13")
        model.selectDistribution("Ubuntu-24.04")

        // While the daemon cannot be reached nothing is selected; afterwards it is again.
        daemon.connectFailure.withLock { $0 = .daemonUnreachable(reason: "test") }
        await provider.refreshed()
        #expect(model.selectedDistribution == nil)
        daemon.connectFailure.withLock { $0 = nil }
        await provider.refreshed()
        #expect(model.selectedDistribution?.name == "Ubuntu-24.04")

        // The selected distribution disappears: the first one is selected, and moves from
        // there.
        daemon.install(["Arch", "Debian-13", "Void"])
        await provider.refreshed()
        #expect(model.selectedDistribution?.name == "Arch")
        model.moveDistributionSelection(by: 1)
        #expect(model.selectedDistribution?.name == "Debian-13")
    }

    // MARK: Actions

    @Test func returnOpensATabInTheSelectedDistributionByItsStoredName() async {
        let daemon = FakeDaemonClient()
        daemon.install(["Debian-13", "Ubuntu-24.04"])
        let (model, _, provider, asked) = await screen(daemon)
        model.selectDistribution("Ubuntu-24.04")
        #expect(model.registry.command(forKey: .return, on: .distributions) == shell)
        await perform(shell, in: model, provider)
        // Not the default distribution's profile, which would follow a change of the default.
        #expect(asked().last == .distribution("Ubuntu-24.04"))
        #expect(model.focusedPane?.profile == .distribution("Ubuntu-24.04"))
        #expect(model.selectedTab?.screen == nil)
        #expect(model.focusedPane?.displayName == "Ubuntu-24.04")
        #expect(daemon.record.withLock { $0.requests }.isEmpty)
        // Back on the screen, the same distribution is selected.
        model.perform(.openDistributions)
        #expect(model.selectedDistribution?.name == "Ubuntu-24.04")
    }

    /// The machine starts with the tab's session, after ↩ has returned, so a list read at once
    /// would still say stopped. The list is read when the session's first output shows that
    /// it runs, and not for later output.
    @Test func aTabOpenedFromTheScreenRefreshesOnceItsSessionHasStarted() async throws {
        let daemon = FakeDaemonClient()
        daemon.install(["Ubuntu-24.04"])
        let (model, _, provider, _) = await screen(daemon)
        let lists = daemon.record.withLock { $0.lists }
        await perform(shell, in: model, provider)
        #expect(daemon.record.withLock { $0.lists } == lists)
        #expect(model.selectedDistribution?.state == .stopped)

        // The session opens, which starts the machine, and the shell prints its prompt.
        daemon.install(["Ubuntu-24.04"], states: [.running])
        let session = try #require(model.focusedPane?.session)
        session.delegate?.session(session, didReceive: ArraySlice("$ ".utf8))
        await provider.pending?.value
        #expect(daemon.record.withLock { $0.lists } == lists + 1)
        #expect(model.selectedDistribution?.state == .running)
        session.delegate?.session(session, didReceive: ArraySlice("ls\r\n".utf8))
        await provider.pending?.value
        #expect(daemon.record.withLock { $0.lists } == lists + 1)
    }

    /// Every way to the screen reads the list, not only its first opening: ⌘⇧L, a click on
    /// its tab, its number, the next and the previous tab, and the closing of the tab in
    /// front of it. Nothing is read while the screen stays selected or another tab is.
    @Test func theListIsReadWheneverTheScreenBecomesTheSelectedTab() async throws {
        let daemon = FakeDaemonClient()
        daemon.install(["Ubuntu-24.04"])
        let (model, _, provider, _) = await screen(daemon)
        let terminal = try #require(model.tabs.tabs.first { $0.screen == nil }?.id)
        let screenTab = try #require(model.tabs.tabs.first { $0.screen == .distributions }?.id)
        #expect(model.tabs.tabs.map(\.id) == [terminal, screenTab])

        let ways: [(String, @MainActor (WindowModel) -> Void)] = [
            ("⌘⇧L", { $0.perform(.openDistributions) }),
            ("a click on its tab", { $0.select(screenTab) }),
            ("⌘2", { $0.perform(.selectTab(2)) }),
            ("the next tab", { $0.perform(.nextTab) }),
            ("the previous tab", { $0.perform(.previousTab) }),
        ]
        var running = false
        for (name, way) in ways {
            // On another tab, the machine's state changes, and nothing is read.
            model.select(terminal)
            running.toggle()
            daemon.install(["Ubuntu-24.04"], states: [running ? .running : .stopped])
            await provider.pending?.value
            let lists = daemon.record.withLock { $0.lists }
            try? await Task.sleep(for: .milliseconds(50))
            #expect(daemon.record.withLock { $0.lists } == lists, "\(name)")

            way(model)
            #expect(model.selectedTab?.screen == .distributions, "\(name)")
            await provider.pending?.value
            #expect(daemon.record.withLock { $0.lists } == lists + 1, "\(name)")
            #expect(
                model.selectedDistribution?.state == (running ? .running : .stopped), "\(name)")
        }

        // A tab opened from the screen closes: the screen behind it is selected again.
        await perform(shell, in: model, provider)
        let opened = try #require(model.focusedPane?.id)
        daemon.install(["Ubuntu-24.04"], states: [.stopping])
        let lists = daemon.record.withLock { $0.lists }
        model.select(terminal)
        model.closePane(opened, confirm: false)
        #expect(await waitUntil(seconds: 5) { model.tabs.count == 2 })
        model.select(screenTab)
        await provider.pending?.value
        #expect(daemon.record.withLock { $0.lists } == lists + 1)
        #expect(model.selectedDistribution?.state == .stopping)
    }

    /// The settings offer each installed distribution as the new-tab profile, so opening them
    /// reads the list, also when nothing else has read it since the app started.
    @Test func openingTheSettingsReadsTheList() async {
        let daemon = FakeDaemonClient()
        daemon.install(["Ubuntu-24.04"])
        let provider = daemon.provider()
        let (model, _, _) = WindowModelTests().window(distributions: provider)
        #expect(daemon.record.withLock { $0.lists } == 0)
        model.perform(.openSettings)
        #expect(model.selectedTab?.screen == .settings)
        await provider.pending?.value
        #expect(daemon.record.withLock { $0.lists } == 1)
        #expect(model.profiles.contains(.distribution("Ubuntu-24.04")))
    }

    @Test func dMakesTheSelectedDistributionTheDefaultAndRefreshes() async {
        let daemon = FakeDaemonClient()
        daemon.install(["Debian-13", "Ubuntu-24.04"])
        let (model, host, provider, _) = await screen(daemon)
        // The default needs no request.
        await perform(setDefault, in: model, provider)
        #expect(daemon.record.withLock { $0.requests }.isEmpty)

        model.selectDistribution("Ubuntu-24.04")
        let lists = daemon.record.withLock { $0.lists }
        #expect(model.registry.command(forKey: .character("d"), on: .distributions) == setDefault)
        await perform(setDefault, in: model, provider)
        let record = daemon.record.withLock { $0 }
        #expect(record.requests == ["setDefault Ubuntu-24.04"])
        #expect(record.lists == lists + 1)
        #expect(record.connectsOnMain == 0 && record.connects == record.closes)
        #expect(
            rows(model) == [
                DistributionInfo(name: "Debian-13", state: .stopped),
                DistributionInfo(name: "Ubuntu-24.04", state: .stopped, isDefault: true),
            ])
        #expect(model.selectedDistribution?.name == "Ubuntu-24.04")
        #expect(!model.isEnabled(setDefault))
        #expect(host.failures.isEmpty && host.questions.isEmpty)
    }

    /// The question counts every session that the daemon's status reports for the machine,
    /// whoever opened it. Without one, nothing is asked.
    @Test(arguments: [0, 1, 2])
    func stoppingAsksFirstOnlyWhenSessionsAreOpenAndSaysHowMany(count: Int) async {
        let daemon = FakeDaemonClient()
        daemon.install(["Debian-13", "Ubuntu-24.04"], states: [.running, .running])
        daemon.sessions.withLock { $0 = ["Debian-13": 7, "Ubuntu-24.04": count] }
        let (model, host, provider, _) = await screen(daemon)
        // The window's only tab is a local shell: none of the sessions is the app's.
        model.selectDistribution("Ubuntu-24.04")
        host.answer = true
        let lists = daemon.record.withLock { $0.lists }
        #expect(model.registry.command(forKey: .character("s"), on: .distributions) == stop)
        await perform(stop, in: model, provider)

        let details = [
            "", "1 session is open in it and will be ended.",
            "2 sessions are open in it and will be ended.",
        ]
        if count == 0 {
            #expect(host.questions.isEmpty)
        } else {
            #expect(host.questions.map(\.message) == ["Stop Ubuntu-24.04?"])
            #expect(host.questions.map(\.detail) == [details[count]])
            #expect(host.questions.map(\.confirmTitle) == ["Stop"])
        }
        let record = daemon.record.withLock { $0 }
        #expect(record.requests == ["status", "terminate Ubuntu-24.04"])
        #expect(record.lists > lists)
        #expect(record.connectsOnMain == 0 && record.connects == record.closes)
        #expect(row("Ubuntu-24.04", in: model)?.state == .stopped)
        #expect(row("Debian-13", in: model)?.state == .running)
        #expect(model.selectedDistribution?.name == "Ubuntu-24.04")
        #expect(host.failures.isEmpty)
    }

    @Test func aStopThatIsNotConfirmedSendsNoStop() async {
        let daemon = FakeDaemonClient()
        daemon.install(["Ubuntu-24.04"], states: [.running])
        daemon.sessions.withLock { $0 = ["Ubuntu-24.04": 3] }
        let (model, host, provider, _) = await screen(daemon)
        await perform(stop, in: model, provider)
        #expect(host.questions.map(\.detail) == ["3 sessions are open in it and will be ended."])
        #expect(daemon.record.withLock { $0.requests } == ["status"])
        #expect(row("Ubuntu-24.04", in: model)?.state == .running)
        #expect(host.failures.isEmpty)
        // It can be asked for again.
        host.answer = true
        await perform(stop, in: model, provider)
        #expect(
            daemon.record.withLock { $0.requests } == [
                "status", "status", "terminate Ubuntu-24.04",
            ])
        #expect(row("Ubuntu-24.04", in: model)?.state == .stopped)
    }

    @Test func aSecondStopWhileTheFirstAsksIsIgnored() async {
        let daemon = FakeDaemonClient()
        daemon.install(["Ubuntu-24.04"], states: [.running])
        daemon.sessions.withLock { $0 = ["Ubuntu-24.04": 1] }
        let (model, host, provider, _) = await screen(daemon)
        host.answer = true
        host.delay = .milliseconds(200)
        model.perform(stop)
        model.perform(stop)
        await perform(stop, in: model, provider)
        #expect(host.questions.count == 1)
        #expect(daemon.record.withLock { $0.requests } == ["status", "terminate Ubuntu-24.04"])
    }

    /// The requests run off the main actor, so the screen stays in use while the guest shuts
    /// down: the watch shows the machine stopping, the selection moves, and another action is
    /// carried out. The stop sends no list request.
    @Test func theScreenStaysInUseWhileAStopTakesItsSeconds() async {
        let daemon = FakeDaemonClient()
        daemon.install(["Debian-13", "Ubuntu-24.04"], states: [.running, .running])
        daemon.holdsStops.withLock { $0 = true }
        let (model, host, provider, _) = await screen(daemon, visible: true)
        func shown(_ name: String) -> DistributionInfo? {
            row(name, in: model).map {
                DistributionInfo(name: $0.name, state: $0.state, isDefault: $0.isDefault)
            }
        }
        model.selectDistribution("Ubuntu-24.04")
        model.perform(stop)
        let stopping = model.distributionAction
        #expect(
            await waitUntil(seconds: 5) { row("Ubuntu-24.04", in: model)?.state == .stopping })
        #expect(model.selectedDistribution?.name == "Ubuntu-24.04")
        #expect(!model.isEnabled(stop))

        model.moveDistributionSelection(by: -1)
        #expect(model.selectedDistribution?.name == "Debian-13")
        model.moveDistributionSelection(by: 1)
        await perform(setDefault, in: model, provider)
        #expect(
            daemon.record.withLock { $0.requests } == [
                "status", "terminate Ubuntu-24.04", "setDefault Ubuntu-24.04",
            ])
        #expect(
            await waitUntil(seconds: 5) {
                shown("Ubuntu-24.04")
                    == DistributionInfo(name: "Ubuntu-24.04", state: .stopping, isDefault: true)
            })

        daemon.holdsStops.withLock { $0 = false }
        await stopping?.value
        #expect(
            await waitUntil(seconds: 5) {
                shown("Ubuntu-24.04")
                    == DistributionInfo(name: "Ubuntu-24.04", state: .stopped, isDefault: true)
            })
        #expect(model.selectedDistribution?.name == "Ubuntu-24.04")
        let watching = provider.watch
        model.shutDown()
        await watching?.value
        let record = daemon.record.withLock { $0 }
        #expect(record.lists == 0)
        #expect(record.connectsOnMain == 0 && record.connects == record.closes)
        #expect(host.failures.isEmpty && host.questions.isEmpty)
    }

    @Test func aDistributionThatIsAlreadyStoppedIsNotStoppedAgain() async {
        let daemon = FakeDaemonClient()
        daemon.install(["Ubuntu-24.04"], states: [.running])
        let (model, host, provider, _) = await screen(daemon)
        // The machine stops by itself after the list was read: the stop asks nothing, fails
        // with nothing, and the list says stopped.
        daemon.install(["Ubuntu-24.04"])
        #expect(model.isEnabled(stop))
        await perform(stop, in: model, provider)
        #expect(daemon.record.withLock { $0.requests } == ["status", "terminate Ubuntu-24.04"])
        #expect(host.questions.isEmpty && host.failures.isEmpty)
        #expect(row("Ubuntu-24.04", in: model)?.state == .stopped)
        // Once the list says so, `s` sends nothing.
        #expect(!model.isEnabled(stop))
        await perform(stop, in: model, provider)
        #expect(daemon.record.withLock { $0.requests }.count == 2)
    }

    @Test func anActionThatFailsIsReportedAsMawWordsItAndTheListIsReadAgain() async throws {
        let daemon = FakeDaemonClient()
        daemon.install(["Debian-13", "Ubuntu-24.04"], states: [.running, .running])
        let (model, host, provider, _) = await screen(daemon)
        model.selectDistribution("Ubuntu-24.04")
        let missing = MawError.distributionNotInstalled(try DistroName("Ubuntu-24.04"))
        let lost = MawError.daemonConnectionLost(during: "terminating the distribution")
        daemon.requestFailures.withLock { $0 = ["setDefault": missing, "terminate": lost] }

        var lists = daemon.record.withLock { $0.lists }
        await perform(setDefault, in: model, provider)
        #expect(
            host.failures == [
                ["Ubuntu-24.04 could not be made the default distribution.", text(missing)]
            ])
        #expect(text(missing).hasPrefix("maw: No distribution named 'Ubuntu-24.04' is installed."))
        #expect(daemon.record.withLock { $0.lists } == lists + 1)
        // The daemon answered the list, so the screen shows it, with the default unchanged.
        #expect(row("Debian-13", in: model)?.isDefault == true)
        #expect(model.selectedDistribution?.name == "Ubuntu-24.04")

        // The status is read, and the stop fails.
        lists = daemon.record.withLock { $0.lists }
        await perform(stop, in: model, provider)
        #expect(host.failures.last == ["Ubuntu-24.04 could not be stopped.", text(lost)])
        #expect(daemon.record.withLock { $0.lists } > lists)
        #expect(row("Ubuntu-24.04", in: model)?.state == .running)

        // The status cannot be read: nothing is asked, and no stop is sent.
        daemon.requestFailures.withLock { $0 = ["status": lost] }
        await perform(stop, in: model, provider)
        #expect(host.failures.count == 3 && host.questions.isEmpty)
        #expect(
            daemon.record.withLock { $0.requests }.filter { $0.hasPrefix("terminate") }.count == 1)

        // A failure does not keep a later stop from running.
        daemon.requestFailures.withLock { $0 = [:] }
        await perform(stop, in: model, provider)
        #expect(row("Ubuntu-24.04", in: model)?.state == .stopped)
        #expect(host.failures.count == 3)
    }
}
