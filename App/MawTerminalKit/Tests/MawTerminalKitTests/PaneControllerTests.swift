import AppKit
import SwiftTerm
import Testing

@testable import MawTerminalKit

@MainActor
@Suite struct PaneControllerTests {
    /// A session that records nothing and never starts a process.
    final class IdleSession: TerminalSession {
        let id = UUID()
        let displayName = "idle"
        weak var delegate: (any TerminalSessionDelegate)?
        let workingDirectory: String? = nil
        let isRunning = false

        func foregroundProgram(within timeout: Duration) async -> ForegroundReport { .none }
        func start(size: TerminalSize) throws(TerminalSessionError) {}
        func send(_ bytes: ArraySlice<UInt8>) {}
        func resize(to size: TerminalSize) {}
        func terminate() {}
        func terminalReportedTitle(_ title: String) {}
        func terminalReportedWorkingDirectory(_ url: String) {}
        func refresh(isVisible: Bool) {}
    }

    @Test func theScrollerIsHidden() {
        let pane = PaneController(profile: .localShell("/bin/sh"), session: IdleSession())
        let scrollers = pane.terminalView.subviews.compactMap { $0 as? NSScroller }
        #expect(!scrollers.isEmpty, "SwiftTerm no longer adds a scroller; update hideScroller()")
        #expect(scrollers.allSatisfy { $0.isHidden })
    }

    @Test func theGridUsesTheWidthTheScrollerWouldTake() {
        let pane = PaneController(profile: .localShell("/bin/sh"), session: IdleSession())
        let hidden = pane.terminalView
        let shown = TerminalView(frame: hidden.frame)
        shown.font = hidden.font
        for view in [hidden, shown] {
            view.setFrameSize(NSSize(width: 800, height: 400))
        }
        #expect(hidden.getTerminal().cols > shown.getTerminal().cols)
    }

    struct SampleError: LocalizedError {
        var errorDescription: String? { "first line\nsecond line" }
        var recoverySuggestion: String? { "Try this." }
    }

    @Test func aFailureKeepsTheErrorsMessageAndSuggestion() {
        #expect(
            TerminalSessionError(SampleError())
                == .failed(message: "first line\nsecond line", suggestion: "Try this."))
        let error = TerminalSessionError.failed(message: "message", suggestion: nil)
        #expect(error.errorDescription == "message")
        #expect(error.recoverySuggestion == nil)
    }

    @Test func aFailureAppearsInThePaneLineByLine() {
        let session = IdleSession()
        let pane = PaneController(profile: .localShell("/bin/sh"), session: session)
        pane.session(session, didFailWith: TerminalSessionError(SampleError()))
        #expect(pane.failure == TerminalSessionError(SampleError()))
        let terminal = pane.terminalView.getTerminal()
        let rows = (0..<3).map { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
        #expect(rows == ["first line", "second line", "Try this."])
    }
}
