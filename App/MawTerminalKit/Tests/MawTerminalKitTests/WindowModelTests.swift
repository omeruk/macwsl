import AppKit
import MawClient
import MawCore
import MawProtocol
import Testing

@testable import MawTerminalKit

/// The window model's close and quit questions and its splits, against fake sessions.
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
        var answer = false
        var delay = Duration.zero
        var closed = 0

        func confirm(_ confirmation: MawTerminalKit.Confirmation) async -> Bool {
            questions.append(confirmation)
            try? await Task.sleep(for: delay)
            return answer
        }

        func closeWindow() { closed += 1 }
        func focusTerminal(_ view: NSView) {}
        func openNewWindow() {}
        func setWindowTitle(_ title: String) {}
        func chromeDidChange() {}
    }

    /// A window whose sessions come from `make`, with its first tab open, and the profiles it
    /// was asked for.
    func window(
        settings change: (inout Settings) -> Void = { _ in },
        make: @escaping (Profile) -> any TerminalSession = { FakeSession($0.name) }
    ) -> (WindowModel, FakeHost, () -> [Profile]) {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "maw-window-\(UUID().uuidString).json")
        let store = SettingsStore(fileURL: file)
        store.update(change)
        try? FileManager.default.removeItem(at: file)
        var asked: [Profile] = []
        let model = WindowModel(settingsStore: store, distributions: NoDistributions()) {
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
        let elapsed = ContinuousClock.now - started
        #expect(reports == [.program(name: "vim"), .none, .noAnswer, .noAnswer])
        #expect(elapsed >= .milliseconds(300) && elapsed < .seconds(2), "\(elapsed)")
    }

    @Test func sessionsThatAnswerAtOnceAreNotKeptWaiting() async {
        let started = ContinuousClock.now
        let reports = await WindowModel.foregroundReports(
            of: [FakeSession("a"), FakeSession("b", answer: .now(.program(name: nil)))],
            within: .seconds(5))
        #expect(reports == [.none, .program(name: nil)])
        #expect(ContinuousClock.now - started < .seconds(2))
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
        let started = ContinuousClock.now
        model.perform(.closePane)
        #expect(await waitUntil(seconds: 5) { !host.questions.isEmpty })
        #expect(ContinuousClock.now - started < .seconds(2))
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
        focused(model)?.answer = .after(.milliseconds(200), .program(name: "sleep"))
        model.perform(.closePane)
        try? await Task.sleep(for: .milliseconds(50))
        model.shutDown()
        try? await Task.sleep(for: .milliseconds(400))
        #expect(host.questions.isEmpty)
        #expect(!model.isAskingToClose)
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
        let quit = await WindowModel.confirmQuitting(panes) { question in
            questions.append(question)
            return false
        }
        #expect(!quit)
        #expect(questions.map(\.message) == ["Quit maw?"])
        #expect(questions.first?.detail == "sleep is still running and will be ended.")
        let idle = [PaneController(profile: .localShell("/bin/sh"), session: FakeSession("zsh"))]
        #expect(await WindowModel.confirmQuitting(idle) { _ in false })
    }

    // MARK: Profiles

    @Test func eachSplitOpensTheProfileItsPaneWasOpenedWith() {
        let (model, _, asked) = window()
        defer { model.shutDown() }
        let local = model.settings.localShellProfile
        #expect(asked() == [local])
        model.perform(.splitRight)
        #expect(asked() == [local, local])
        #expect(model.focusedPane?.profile == local)
    }
}
