import AppKit
import SwiftTerm
import Testing

@testable import MawTerminalKit

@MainActor
@Suite struct PaneControllerTests {
    /// A session that never starts a process and records its input.
    final class IdleSession: TerminalSession {
        let id = UUID()
        let displayName = "idle"
        weak var delegate: (any TerminalSessionDelegate)?
        let workingDirectory: String? = nil
        var isRunning = false
        var input: [UInt8] = []

        func foregroundProgram(within timeout: Duration) async -> ForegroundReport { .none }
        func start(size: TerminalSize) throws(TerminalSessionError) { isRunning = true }
        func send(_ bytes: ArraySlice<UInt8>) { input += bytes }
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
        #expect(
            rows(of: pane, 4) == ["maw: first line", "second line", "Try this.", "[↩ new session]"])
    }

    func rows(of pane: PaneController, _ count: Int) -> [String?] {
        let terminal = pane.terminalView.getTerminal()
        return (0..<count).map { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
    }

    /// A pane whose sessions come from `IdleSession`, as the window makes them.
    func paneWithNewSessions() -> (PaneController, () -> [IdleSession]) {
        let first = IdleSession()
        var made = [first]
        let pane = PaneController(profile: .localShell("/bin/sh"), session: first)
        pane.makeSession = { profile in
            #expect(profile == .localShell("/bin/sh"))
            made.append(IdleSession())
            return made.last
        }
        pane.startIfNeeded()
        return (pane, { made })
    }

    @Test func enterInAPaneThatStillRunsReachesTheProgram() {
        let (pane, made) = paneWithNewSessions()
        pane.send(source: pane.terminalView, data: [0x0D])
        #expect(made().count == 1)
        #expect(made()[0].input == [0x0D])
        #expect(!pane.offersNewSession)
    }

    @Test func afterAFailureEnterStartsANewSessionOfTheProfileKeepingTheScrollback() throws {
        let (pane, made) = paneWithNewSessions()
        let first = made()[0]
        pane.session(first, didReceive: ArraySlice("before\r\n".utf8))
        first.isRunning = false
        pane.session(first, didFailWith: .failed(message: "it stopped", suggestion: nil))
        #expect(pane.offersNewSession)
        pane.send(source: pane.terminalView, data: ArraySlice("x".utf8))
        #expect(made().count == 1)
        #expect(first.input.isEmpty)
        pane.send(source: pane.terminalView, data: [0x0D])
        let second = try #require(made().last)
        #expect(made().count == 2)
        #expect(pane.session === second && second.isRunning)
        #expect(second.delegate === pane && first.delegate == nil)
        #expect(pane.failure == nil && !pane.offersNewSession)
        #expect(rows(of: pane, 3) == ["before", "maw: it stopped", "[↩ new session]"])
        pane.send(source: pane.terminalView, data: [0x0D])
        #expect(second.input == [0x0D])
    }

    @Test func anExitWithAnErrorOffersANewSessionAndACleanExitClosesThePane() {
        let (pane, _) = paneWithNewSessions()
        var closed: [PaneID] = []
        pane.onCleanExit = { closed.append($0) }
        pane.session(pane.session, didTerminateWith: .exited(2))
        #expect(pane.offersNewSession)
        #expect(rows(of: pane, 2) == ["[exited with status 2]", "[↩ new session]"])
        let (clean, _) = paneWithNewSessions()
        clean.session(clean.session, didTerminateWith: .exited(0))
        #expect(closed.isEmpty)
        #expect(!clean.offersNewSession)
    }

    @Test func aFallbackPrintsItsNoticeDimAndStartsTheReplacement() {
        let (pane, _) = paneWithNewSessions()
        let replacement = IdleSession()
        pane.session(pane.session, didFallBackTo: replacement, notice: "line one\nline two\n")
        #expect(pane.session === replacement && replacement.isRunning)
        #expect(replacement.delegate === pane)
        #expect(rows(of: pane, 2) == ["line one", "line two"])
        let terminal = pane.terminalView.getTerminal()
        let attribute = terminal.getCharData(col: 0, row: 0)?.attribute
        #expect(attribute?.style.contains(.dim) == true)
    }
}
