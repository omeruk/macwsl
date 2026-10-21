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
        let hasForegroundProcess = false
        let foregroundProcessName: String? = nil

        func start(size: TerminalSize) throws(TerminalSessionError) {}
        func send(_ bytes: ArraySlice<UInt8>) {}
        func resize(to size: TerminalSize) {}
        func terminate() {}
        func terminalReportedTitle(_ title: String) {}
        func terminalReportedWorkingDirectory(_ url: String) {}
        func refresh(isVisible: Bool) {}
    }

    @Test func theScrollerIsHidden() {
        let pane = PaneController(session: IdleSession())
        let scrollers = pane.terminalView.subviews.compactMap { $0 as? NSScroller }
        #expect(!scrollers.isEmpty, "SwiftTerm no longer adds a scroller; update hideScroller()")
        #expect(scrollers.allSatisfy { $0.isHidden })
    }

    @Test func theGridUsesTheWidthTheScrollerWouldTake() {
        let pane = PaneController(session: IdleSession())
        let hidden = pane.terminalView
        let shown = TerminalView(frame: hidden.frame)
        shown.font = hidden.font
        for view in [hidden, shown] {
            view.setFrameSize(NSSize(width: 800, height: 400))
        }
        #expect(hidden.getTerminal().cols > shown.getTerminal().cols)
    }
}
