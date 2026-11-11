import AppKit
import MawClient
import MawCore
import MawProtocol
import Testing

@testable import MawTerminalKit

/// The window model's close and quit questions, its splits, and ⌘T, against fake sessions.
@MainActor
@Suite struct WindowModelTests {
    /// A session whose foreground answer comes at once, late, or never.
    final class FakeSession: TerminalSession {
        enum Answer {
            case now(ForegroundReport)
            case after(Duration, ForegroundReport)
            case never
        }

        let id = UUID()
        let displayName: String
        weak var delegate: (any TerminalSessionDelegate)?
        let workingDirectory: String? = nil
        var isRunning = false
        var answer: Answer
        var terminated = 0

        init(_ name: String, answer: Answer = .now(.none)) {
            displayName = name
            self.answer = answer
        }

        func foregroundProgram(within timeout: Duration) async -> ForegroundReport {
            switch answer {
            case .now(let report):
                return report
            case .after(let delay, let report):
                try? await Task.sleep(for: delay)
                return report
            case .never:
                try? await Task.sleep(for: .seconds(3600))
                return .none
            }
        }

        func start(size: MawTerminalKit.TerminalSize) throws(TerminalSessionError) {
            isRunning = true
        }

        func send(_ bytes: ArraySlice<UInt8>) {}
        func resize(to size: MawTerminalKit.TerminalSize) {}
        func terminate() {
            terminated += 1
            isRunning = false
        }
        func terminalReportedTitle(_ title: String) {}
        func terminalReportedWorkingDirectory(_ url: String) {}
        func refresh(isVisible: Bool) {}
    }

    /// Answers every question with `answer`, after `delay`, and records them.
    final class FakeHost: WindowHost {
        var questions: [MawTerminalKit.Confirmation] = []
        /// The failures reported, each as its message and detail.
        var failures: [[String]] = []
        var answer = false
        var delay = Duration.zero
        var closed = 0
        /// How many times the window gave the keyboard focus to a terminal.
        var terminalFocuses = 0

        func confirm(_ confirmation: MawTerminalKit.Confirmation) async -> Bool {
            questions.append(confirmation)
            try? await Task.sleep(for: delay)
            return answer
        }

        func report(failure message: String, detail: String) { failures.append([message, detail]) }
        func closeWindow() { closed += 1 }
        func focusTerminal(_ view: NSView) { terminalFocuses += 1 }
        func openNewWindow() {}
        func setWindowTitle(_ title: String) {}
        func chromeDidChange() {}
    }

    /// A window whose sessions come from `make`, with its first tab open, and the profiles it
    /// was asked for.
    func window(
        settings change: (inout Settings) -> Void = { _ in },
        distributions: (any DistributionProvider)? = nil,
        make: @escaping (Profile) -> any TerminalSession = { FakeSession($0.name) }
    ) -> (WindowModel, FakeHost, () -> [Profile]) {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "maw-window-\(UUID().uuidString).json")
        let store = SettingsStore(fileURL: file)
        store.update(change)
        try? FileManager.default.removeItem(at: file)
        var asked: [Profile] = []
        let provider = distributions ?? FakeDaemonClient().provider()
        let model = WindowModel(settingsStore: store, distributions: provider) {
            asked.append($0)
            return make($0)
        }
        let host = FakeHost()
        model.host = host
        model.start()
        return (model, host, { asked })
    }

    var focused: (WindowModel) -> FakeSession? {
        { $0.focusedPane?.session as? FakeSession }
    }

    // MARK: Asking the sessions

    @Test func theSessionsAreAskedAtOnceWithOneDeadline() async {
        let sessions = [
            FakeSession("a", answer: .now(.program(name: "vim"))),
            FakeSession("b", answer: .after(.milliseconds(50), .none)),
            FakeSession("c", answer: .after(.seconds(5), .program(name: "late"))),
            FakeSession("d", answer: .never),
        ]
        let started = ContinuousClock.now
        let reports = await WindowModel.foregroundReports(
            of: sessions, within: .milliseconds(300))
        // The late answer and the missing one count as no answer, so the deadline ended the
        // wait; how soon it did is checked in `Latency`.
        #expect(reports == [.program(name: "vim"), .none, .noAnswer, .noAnswer])
        #expect(ContinuousClock.now - started >= .milliseconds(300))
    }

    @Test func theQuestionNamesTheProgramsAndTheSessionsThatDidNotAnswer() async {
        let (model, _, _) = window()
        defer { model.shutDown() }
        func panes(_ sessions: [FakeSession]) -> [PaneController] {
            sessions.map { PaneController(profile: .localShell("/bin/sh"), session: $0) }
        }
        #expect(await WindowModel.runningDetail(of: panes([FakeSession("zsh")])) == nil)
        #expect(
            await WindowModel.runningDetail(
                of: panes([FakeSession("Ubuntu-24.04", answer: .now(.program(name: "sleep")))]))
                == "sleep is still running and will be ended.")
        #expect(
            await WindowModel.runningDetail(
                of: panes([
                    FakeSession("zsh", answer: .now(.program(name: "vim"))),
                    FakeSession("Ubuntu-24.04", answer: .now(.program(name: nil))),
                    FakeSession("Debian-13", answer: .never),
                ]), within: .milliseconds(100))
                == "vim and a program in Ubuntu-24.04 are still running and will be ended. "
                + "A program may be running in Debian-13, which did not answer within 100 ms.")
    }

    // MARK: Closing

    @Test func atThePromptATabClosesWithoutAsking() async {
        let (model, host, _) = window()
        defer { model.shutDown() }
        model.perform(.newTab(profile: Profile.localShellID))
        #expect(model.tabs.count == 2)
        let session = focused(model)
        model.perform(.closePane)
        #expect(await waitUntil(seconds: 5) { model.tabs.count == 1 })
        #expect(host.questions.isEmpty)
        #expect(session?.terminated == 1)
    }

    @Test func aRunningProgramIsNamedAndCancellingKeepsThePane() async {
        let (model, host, _) = window()
        defer { model.shutDown() }
        focused(model)?.answer = .now(.program(name: "sleep"))
        model.perform(.closePane)
        #expect(await waitUntil(seconds: 5) { !host.questions.isEmpty })
        #expect(host.questions.first?.message == "Close this tab?")
        #expect(host.questions.first?.detail == "sleep is still running and will be ended.")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.tabs.count == 1 && focused(model)?.terminated == 0)
        #expect(!model.isAskingToClose)
        host.answer = true
        model.perform(.closePane)
        #expect(await waitUntil(seconds: 5) { host.closed == 1 })
    }

    @Test func aSessionThatDoesNotAnswerMakesTheQuestionSaySoInTime() async {
        let (model, host, _) = window(make: { _ in FakeSession("Ubuntu-24.04") })
        defer { model.shutDown() }
        focused(model)?.answer = .never
        model.perform(.closePane)
        #expect(await waitUntil(seconds: 5) { !host.questions.isEmpty })
        #expect(
            host.questions.first?.detail
                == "A program may be running in Ubuntu-24.04, which did not answer within 500 ms.")
    }

    @Test func aSecondCloseWhileAQuestionIsOpenIsIgnored() async {
        let (model, host, _) = window()
        defer { model.shutDown() }
        focused(model)?.answer = .after(.milliseconds(200), .program(name: "top"))
        host.delay = .milliseconds(300)
        host.answer = true
        model.perform(.closePane)
        model.perform(.closePane)
        model.requestCloseWindow()
        #expect(await waitUntil(seconds: 5) { host.closed == 1 })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(host.questions.count == 1)
        #expect(host.closed == 1)
    }

    @Test func aWindowThatClosesWhileItsQueryWaitsAsksNothing() async {
        let (model, host, _) = window()
        focused(model)?.answer = .never
        model.perform(.closePane)
        #expect(await waitUntil(seconds: 5) { model.isAskingToClose })
        model.shutDown()
        #expect(await waitUntil(seconds: 5) { !model.isAskingToClose })
        #expect(host.questions.isEmpty)
        #expect(model.tabs.count == 1)
    }

    @Test func closingTheWindowAsksForEveryPaneAndClosesAtThePrompt() async {
        let (model, host, _) = window()
        defer { model.shutDown() }
        model.perform(.splitRight)
        focused(model)?.answer = .now(.program(name: "htop"))
        host.answer = false
        model.requestCloseWindow()
        #expect(await waitUntil(seconds: 5) { !host.questions.isEmpty })
        #expect(host.questions.first?.message == "Close this window?")
        #expect(host.questions.first?.detail == "htop is still running and will be ended.")
        #expect(await waitUntil(seconds: 5) { !model.isAskingToClose })
        #expect(host.closed == 0)
        focused(model)?.answer = .now(.none)
        model.requestCloseWindow()
        #expect(await waitUntil(seconds: 5) { host.closed == 1 })
        #expect(host.questions.count == 1)
    }

    /// The question covers the panes that existed when it was asked; a pane opened meanwhile
    /// makes the window ask again, about every pane, before it closes.
    @Test func aPaneOpenedWhileTheWindowAsksIsAskedAboutBeforeClosing() async {
        let (model, host, _) = window()
        defer { model.shutDown() }
        focused(model)?.answer = .now(.program(name: "top"))
        host.delay = .milliseconds(300)
        host.answer = true
        model.requestCloseWindow()
        #expect(await waitUntil(seconds: 5) { host.questions.count == 1 })
        model.perform(.newTab(profile: Profile.localShellID))
        focused(model)?.answer = .now(.program(name: "vim"))
        #expect(await waitUntil(seconds: 5) { host.closed == 1 })
        #expect(host.questions.count == 2)
        #expect(host.questions.last?.detail.contains("vim") == true)
    }

    @Test func aPaneSplitWhileTheTabAsksIsAskedAboutBeforeClosing() async {
        let (model, host, _) = window()
        defer { model.shutDown() }
        model.perform(.newTab(profile: Profile.localShellID))
        guard let tab = model.tabs.selectedID else {
            Issue.record("no tab is selected")
            return
        }
        focused(model)?.answer = .now(.program(name: "top"))
        host.delay = .milliseconds(300)
        host.answer = true
        model.closeTab(tab)
        #expect(await waitUntil(seconds: 5) { host.questions.count == 1 })
        model.perform(.splitRight)
        focused(model)?.answer = .now(.program(name: "vim"))
        #expect(await waitUntil(seconds: 5) { model.tabs.count == 1 })
        #expect(host.questions.count == 2)
        #expect(host.questions.last?.detail.contains("vim") == true)
    }

    @Test func withTheQuestionTurnedOffNothingIsAsked() async {
        let (model, host, _) = window { $0.confirmCloseWithRunningProcess = false }
        defer { model.shutDown() }
        focused(model)?.answer = .never
        model.requestCloseWindow()
        #expect(await waitUntil(seconds: 5) { host.closed == 1 })
        #expect(host.questions.isEmpty)
    }

    @Test func quittingAsksAboutEveryPaneOnceTheyHaveAnswered() async {
        let panes = [
            PaneController(profile: .localShell("/bin/sh"), session: FakeSession("Ubuntu-24.04")),
            PaneController(
                profile: .localShell("/bin/sh"),
                session: FakeSession(
                    "Debian-13",
                    answer: .after(
                        .milliseconds(50),
                        .program(
                            name: "sleep")))),
        ]
        var questions: [MawTerminalKit.Confirmation] = []
        let quit = await WindowModel.confirmQuitting(
            { panes },
            ask: { question in
                questions.append(question)
                return false
            })
        #expect(!quit)
        #expect(questions.map(\.message) == ["Quit maw?"])
        #expect(questions.first?.detail == "sleep is still running and will be ended.")
        let idle = [PaneController(profile: .localShell("/bin/sh"), session: FakeSession("zsh"))]
        #expect(await WindowModel.confirmQuitting({ idle }, ask: { _ in false }))
    }

    @Test func aPaneOpenedWhileQuittingAsksIsAskedAboutBeforeQuitting() async {
        var panes = [
            PaneController(
                profile: .localShell("/bin/sh"),
                session: FakeSession("zsh", answer: .now(.program(name: "top"))))
        ]
        var questions: [MawTerminalKit.Confirmation] = []
        let quit = await WindowModel.confirmQuitting(
            { panes },
            ask: { question in
                questions.append(question)
                if questions.count == 1 {
                    panes.append(
                        PaneController(
                            profile: .localShell("/bin/sh"),
                            session: FakeSession("zsh", answer: .now(.program(name: "vim")))))
                }
                return true
            })
        #expect(quit)
        #expect(questions.count == 2)
        #expect(questions.last?.detail == "top and vim are still running and will be ended.")
    }

    // MARK: Profiles

    @Test func eachSplitOpensTheProfileItsPaneWasOpenedWith() {
        let (model, _, asked) = window { $0.defaultProfile = Profile.localShellID }
        defer { model.shutDown() }
        let local = model.settings.localShellProfile
        #expect(asked() == [local])
        model.perform(.splitRight)
        #expect(asked() == [local, local])
        model.perform(.newTab(profile: Profile.defaultDistributionID))
        model.perform(.splitDown)
        #expect(asked() == [local, local, .defaultDistribution, .defaultDistribution])
        #expect(model.focusedPane?.profile == .defaultDistribution)
    }

    @Test func everyProfileListOffersTheDefaultDistributionAndTheLocalShell() {
        let (model, _, asked) = window()
        defer { model.shutDown() }
        #expect(asked() == [.defaultDistribution])
        #expect(model.profiles.map(\.id) == ["default-distribution", "local"])
        #expect(model.registry[.newTab(profile: "default-distribution")]?.shortcut == .command("t"))
        #expect(
            model.registry[.newTab(profile: "local")]?.title
                == "new tab: \(model.settings.localShellProfile.paletteName)")
        let form = SettingsForm(settings: model.settings, profiles: model.profiles)
        let field = form.fields(on: .general).first { $0.id == .defaultProfile }
        #expect(field?.value == "default distribution")
    }

    @Test(arguments: [[], ["Ubuntu-24.04"], ["Debian-13", "Ubuntu-24.04"]])
    func theProfilesAreTheDefaultEachReportedDistributionAndTheLocalShell(names: [String]) async {
        let daemon = FakeDaemonClient()
        daemon.install(names)
        let provider = daemon.provider()
        await provider.refreshed()
        let (model, _, _) = window(distributions: provider)
        defer { model.shutDown() }
        let local = model.settings.localShellProfile
        #expect(
            model.profiles.map(\.id)
                == ["default-distribution"] + names.map { "distribution:\($0)" } + ["local"])
        let newTabs = model.registry.commands.filter {
            if case .newTab = $0.id { return true }
            return false
        }
        #expect(
            newTabs.map(\.title)
                == ["new tab: default distribution"] + names.map { "new tab: \($0)" }
                + ["new tab: \(local.paletteName)"])
        #expect(model.registry.newTabCommand == .newTab(profile: "default-distribution"))
        let form = SettingsForm(settings: model.settings, profiles: model.profiles)
        let field = form.fields(on: .general).first { $0.id == .defaultProfile }
        #expect(
            field?.kind
                == .choice(
                    options: ["default distribution"] + names + [local.paletteName], selected: 0))
        if let last = names.last {
            let index = names.count
            #expect(
                form.choosing(.defaultProfile, index: index).defaultProfile
                    == "distribution:\(last)")
        }
    }

    /// The list is asked for when the palette or the distributions screen opens, and never
    /// for ⌘T or a split.
    @Test func thePaletteAndTheScreenRefreshTheListAndNothingElseDoes() async {
        let daemon = FakeDaemonClient()
        let provider = daemon.provider()
        let (model, _, _) = window(distributions: provider)
        defer { model.shutDown() }
        func connects() async -> Int {
            await provider.pending?.value
            return daemon.record.withLock { $0.connects }
        }
        #expect(await connects() == 0)
        model.perform(.commandPalette)
        #expect(await connects() == 1)
        model.perform(.commandPalette)
        model.perform(.newTab(profile: Profile.localShellID))
        model.perform(.splitRight)
        #expect(await connects() == 1)
        model.perform(.openDistributions)
        #expect(await connects() == 2)
        #expect(daemon.record.withLock { $0.closes } == 2)
    }

    /// The first tab and ⌘T open the setting's distribution from its name, before any list
    /// has arrived, and ask the daemon for no list.
    @Test func aNamedDistributionOpensBeforeTheListHasArrived() throws {
        let daemon = FakeDaemonClient()
        let (model, _, asked) = window(
            settings: { $0.defaultProfile = "distribution:Debian-13" },
            distributions: daemon.provider())
        defer { model.shutDown() }
        #expect(asked() == [.distribution("Debian-13")])
        let command = try #require(model.registry.newTabCommand)
        model.perform(command)
        #expect(asked() == [.distribution("Debian-13"), .distribution("Debian-13")])
        #expect(model.registry[command]?.title == "new tab")
        #expect(daemon.record.withLock { $0.connects } == 0)
    }

    /// ⌘T with a distribution that the list does not contain reaches the session layer, which
    /// opens the default and says so; a split then opens the distribution that opened.
    @Test func commandTWithADistributionThatIsNotListedSaysWhatItOpened() async throws {
        let daemon = FakeDaemonClient()
        daemon.install(["Ubuntu-24.04"])
        let provider = daemon.provider()
        await provider.refreshed()
        let cores = FakeCores()
        cores.installed = ["Ubuntu-24.04"]
        cores.defaultName = "Ubuntu-24.04"
        let (model, _, asked) = window(
            settings: { $0.defaultProfile = "distribution:Debian-13" }, distributions: provider,
            make: { $0.makeSession(localShell: .localShell("/bin/sh"), cores: cores.cores) })
        defer { model.shutDown() }
        let notice =
            "Debian-13 is not installed. This tab opened Ubuntu-24.04, the default distribution."
        model.focusedPane?.startIfNeeded()
        model.perform(try #require(model.registry.newTabCommand))
        let pane = try #require(model.focusedPane)
        pane.startIfNeeded()
        #expect(asked() == [.distribution("Debian-13"), .distribution("Debian-13")])
        #expect(await waitUntil(seconds: 5) { pane.displayName == "Ubuntu-24.04" })
        #expect(await waitUntil(seconds: 5) { text(of: pane).contains("prompt$") })
        #expect(text(of: pane).contains(notice), "\(text(of: pane))")
        #expect(pane.session is LinuxSession)
        #expect(pane.profile == .distribution("Debian-13"))

        model.perform(.splitRight)
        #expect(asked().last == .distribution("Ubuntu-24.04"))
        model.focusedPane?.startIfNeeded()
        #expect(await waitUntil(seconds: 5) { model.focusedPane?.displayName == "Ubuntu-24.04" })
        #expect(!text(of: model.focusedPane).contains("not installed"))
        // The first tab's fallback may open before or after ⌘T's tab is made.
        #expect(
            cores.opened.map { $0 ?? "default" }.sorted()
                == ["Debian-13", "Debian-13", "Ubuntu-24.04", "default", "default"])
    }

    /// The daemon looks names up without regard to case: the listed distribution gets ⌘T and
    /// the form shows it.
    @Test func aSettingInAnotherCaseIsTheListedDistribution() async throws {
        let daemon = FakeDaemonClient()
        daemon.install(["Ubuntu-24.04"])
        let provider = daemon.provider()
        await provider.refreshed()
        let (model, _, asked) = window(
            settings: { $0.defaultProfile = "distribution:ubuntu-24.04" }, distributions: provider)
        defer { model.shutDown() }
        let command = try #require(model.registry.newTabCommand)
        #expect(command == .newTab(profile: "distribution:Ubuntu-24.04"))
        model.perform(command)
        #expect(asked() == [.distribution("ubuntu-24.04"), .distribution("Ubuntu-24.04")])
        let form = SettingsForm(settings: model.settings, profiles: model.profiles)
        #expect(form.fields(on: .general).first?.value == "Ubuntu-24.04")
    }

    /// A pane of the default distribution splits into the distribution it opened, by its
    /// stored name, even after the default changes; one that never opened splits its profile.
    @Test func aSplitOpensTheDistributionThePaneOpenedByItsStoredName() async throws {
        let cores = FakeCores()
        cores.installed = ["Ubuntu-24.04", "Debian-13"]
        cores.defaultName = "Ubuntu-24.04"
        let (model, _, asked) = window(make: {
            $0.makeSession(localShell: .localShell("/bin/sh"), cores: cores.cores)
        })
        defer { model.shutDown() }
        let pane = try #require(model.focusedPane)
        pane.startIfNeeded()
        #expect(await waitUntil(seconds: 5) { pane.displayName == "Ubuntu-24.04" })
        cores.defaultName = "Debian-13"
        model.perform(.splitDown)
        #expect(asked() == [.defaultDistribution, .distribution("Ubuntu-24.04")])

        cores.failure = .daemonUnreachable(reason: "gone")
        model.perform(.newTab(profile: Profile.defaultDistributionID))
        let failed = try #require(model.focusedPane)
        failed.startIfNeeded()
        #expect(await waitUntil(seconds: 5) { failed.offersNewSession })
        model.perform(.splitRight)
        #expect(asked().last == .defaultDistribution)
    }

    // MARK: ⌘T

    /// A window whose default distribution's sessions run on fake cores that end with
    /// `ending`, or open `Ubuntu-24.04` without one.
    func linuxWindow(ending: DistributionSession.Ending?) -> (WindowModel, FakeHost) {
        let (model, host, _) = window(make: { profile in
            guard profile.kind == .defaultDistribution else { return FakeSession("zsh") }
            let fallback: LinuxSession.ChooseFallback = { error in
                LinuxSession.fallbackNotice(for: error).map {
                    LinuxSession.Fallback(replacement: FakeSession("zsh"), notice: $0)
                }
            }
            return LinuxSession(name: nil, fallback: fallback) { terminal, output in
                let core = LinuxSessionTests.FakeCore(
                    terminal: terminal, output: output,
                    name: ending == nil ? "Ubuntu-24.04" : nil, foreground: .none)
                if let ending { core.end(ending) }
                return core
            }
        })
        model.focusedPane?.startIfNeeded()
        return (model, host)
    }

    /// The pane's text, with the terminal's line breaks removed, so that a wrapped line reads
    /// as one.
    func text(of pane: PaneController?) -> String {
        guard let pane else { return "" }
        let data = pane.terminalView.getTerminal().getBufferAsData()
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: "")
    }

    @Test func commandTOpensTheDefaultDistribution() async {
        let (model, _) = linuxWindow(ending: nil)
        defer { model.shutDown() }
        #expect(model.focusedPane?.session is LinuxSession)
        #expect(await waitUntil(seconds: 5) { model.focusedPane?.displayName == "Ubuntu-24.04" })
    }

    @Test(arguments: [
        MawError.noDistributionInstalled, .daemonNotInstalled(label: "dev.maw.mawd"),
    ])
    func withNothingInstalledCommandTOpensTheLocalShellWithANotice(error: MawError) async {
        let (model, _) = linuxWindow(ending: .failed(error))
        defer { model.shutDown() }
        #expect(await waitUntil(seconds: 5) { model.focusedPane?.session is FakeSession })
        #expect(model.focusedPane?.session.isRunning == true)
        #expect(model.focusedPane?.offersNewSession == false)
        let expected =
            error == .noDistributionInstalled
            ? "No Linux distribution is installed" : "maw: The maw daemon is not installed"
        #expect(text(of: model.focusedPane).contains(expected))
    }

    @Test(arguments: [
        MawError.daemonUnreachable(reason: "the connection was invalidated"),
        .daemonConnectionLost(during: "openSession"),
        .daemonProtocolError(reason: "a field is missing"),
        .daemonVersionMismatch(client: 3, daemon: 2),
        .clientSignatureRejected(identifier: "dev.maw.app"),
        .launchctlTimedOut(command: "launchctl print", seconds: 10),
    ])
    func anyOtherFailureShowsTheErrorInALinuxPane(error: MawError) async throws {
        let (model, _) = linuxWindow(ending: .failed(error))
        defer { model.shutDown() }
        #expect(await waitUntil(seconds: 5) { model.focusedPane?.offersNewSession == true })
        let pane = try #require(model.focusedPane)
        #expect(pane.session is LinuxSession)
        #expect(pane.displayName == "linux")
        let text = text(of: pane)
        let firstLine = try #require(error.description.split(separator: "\n").first)
        #expect(text.contains("maw: \(firstLine)"), "\(text)")
        #expect(text.contains("[↩ new session]"), "\(text)")
    }
}

extension WindowModelTests {
    /// Upper bounds on how long the questions wait (decision record 0018). CI runs this suite
    /// after the others, one test at a time, because every test of this package shares the main
    /// actor.
    @MainActor
    @Suite struct Latency {
        @Test func theDeadlineEndsTheWaitForASessionThatDoesNotAnswer() async {
            let started = ContinuousClock.now
            let reports = await WindowModel.foregroundReports(
                of: [FakeSession("a", answer: .never)], within: .milliseconds(300))
            #expect(reports == [.noAnswer])
            #expect(ContinuousClock.now - started < .seconds(2))
        }

        @Test func sessionsThatAnswerAtOnceAreNotKeptWaiting() async {
            let started = ContinuousClock.now
            let reports = await WindowModel.foregroundReports(
                of: [FakeSession("a"), FakeSession("b", answer: .now(.program(name: nil)))],
                within: .seconds(5))
            #expect(reports == [.none, .program(name: nil)])
            #expect(ContinuousClock.now - started < .seconds(2))
        }

        @Test func theQuestionAboutASilentSessionComesInTime() async {
            let (model, host, _) = WindowModelTests().window(make: { _ in
                FakeSession("Ubuntu-24.04", answer: .never)
            })
            defer { model.shutDown() }
            let started = ContinuousClock.now
            model.perform(.closePane)
            #expect(await waitUntil(seconds: 5) { !host.questions.isEmpty })
            #expect(ContinuousClock.now - started < .seconds(2))
        }
    }
}
