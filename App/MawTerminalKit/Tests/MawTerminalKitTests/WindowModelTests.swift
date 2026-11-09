import AppKit
import MawClient
import MawCore
import MawProtocol
import Testing

@testable import MawTerminalKit

/// The window model's splits, against fake sessions.
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
        let hasForegroundProcess = false
        let foregroundProcessName: String? = nil

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
