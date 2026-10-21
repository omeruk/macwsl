import AppKit
import Observation
import SwiftTerm

/// How a pane looks: the parts of the settings that apply to terminals, after the window's
/// font size adjustment.
struct TerminalAppearance: Equatable {
    var theme: Theme
    var fontFamily: String
    var fontSize: CGFloat
    var cursorShape: CursorShape
    var backgroundOpacity: Double

    init(settings: Settings, fontSizeAdjustment: Double) {
        theme = settings.selectedTheme
        fontFamily = settings.fontFamily
        fontSize = CGFloat(
            min(
                max(settings.fontSize + fontSizeAdjustment, Settings.fontSizeRange.lowerBound),
                Settings.fontSizeRange.upperBound))
        cursorShape = settings.cursorShape
        backgroundOpacity = settings.backgroundOpacity
    }
}

/// One pane: a session and the SwiftTerm view that shows it.
///
/// The controller owns the terminal view for the pane's whole life. SwiftUI only places it
/// (see `TerminalHostView`), so splitting, moving, or reordering panes never recreates the view
/// and never loses the scrollback.
@MainActor
@Observable
final class PaneController {
    let id: PaneID
    let session: any TerminalSession
    @ObservationIgnored let terminalView: MawTerminalView

    private(set) var title: String?
    private(set) var workingDirectory: String?
    private(set) var size = TerminalSize.default
    private(set) var termination: TerminationStatus?
    private(set) var startError: TerminalSessionError?

    /// Called when the session ends with status 0, so that the window can close the pane, as
    /// Windows Terminal does by default. A pane whose process failed stays open with its status.
    @ObservationIgnored var onCleanExit: ((PaneID) -> Void)?
    /// Called when the user clicks into the pane's terminal.
    @ObservationIgnored var onFocus: ((PaneID) -> Void)?
    /// Asks before pasting several lines. Returns whether to paste.
    @ObservationIgnored var confirmPaste: ((String) -> Bool)?

    @ObservationIgnored private var appearance: TerminalAppearance?
    @ObservationIgnored private var started = false

    init(id: PaneID = PaneID(), session: any TerminalSession) {
        self.id = id
        self.session = session
        terminalView = MawTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        terminalView.hideScroller()
        terminalView.terminalDelegate = self
        terminalView.pane = self
        session.delegate = self
    }

    var displayName: String { session.displayName }
    var isRunning: Bool { session.isRunning }

    /// Starts the session once the view has its first real size, so that the program starts
    /// with the right number of columns and rows.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        let terminal = terminalView.getTerminal()
        size = TerminalSize(columns: terminal.cols, rows: terminal.rows)
        do {
            try session.start(size: size)
        } catch {
            startError = error
            let message = [error.errorDescription, error.recoverySuggestion]
                .compactMap { $0 }.joined(separator: "\r\n")
            terminalView.feed(text: "\u{1B}[31m\(message)\u{1B}[0m\r\n")
        }
    }

    func apply(_ appearance: TerminalAppearance) {
        guard appearance != self.appearance else { return }
        terminalView.apply(appearance, previous: self.appearance)
        self.appearance = appearance
    }

    func send(_ text: String) {
        session.send(ArraySlice(text.utf8))
    }

    func refresh(isVisible: Bool) {
        session.refresh(isVisible: isVisible)
    }

    func terminate() {
        session.terminate()
    }
}

extension PaneController: TerminalSessionDelegate {
    func session(_ session: any TerminalSession, didReceive bytes: ArraySlice<UInt8>) {
        terminalView.feed(byteArray: bytes)
    }

    func session(_ session: any TerminalSession, didChangeTitle title: String) {
        self.title = title
    }

    func session(_ session: any TerminalSession, didChangeWorkingDirectory directory: String) {
        workingDirectory = directory
    }

    func session(_ session: any TerminalSession, didTerminateWith status: TerminationStatus) {
        termination = status
        if status == .exited(0) {
            onCleanExit?(id)
        } else {
            terminalView.feed(text: "\r\n\u{1B}[2m[\(status.description)]\u{1B}[0m\r\n")
        }
    }
}

// SwiftTerm calls its view delegate on the main thread, from the view's own event handling.
extension PaneController: @preconcurrency TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        size = TerminalSize(columns: newCols, rows: newRows)
        session.resize(to: size)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        session.terminalReportedTitle(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        if let directory {
            session.terminalReportedWorkingDirectory(directory)
        }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session.send(data)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        TerminalView.openDefaultLink(link)
    }

    func bell(source: TerminalView) {
        NSSound.beep()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        // Programs may not read the clipboard without the user's involvement.
        nil
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

extension TerminalView {
    /// Hides SwiftTerm's scroller, which the design does not have. SwiftTerm then reserves no
    /// width for it, so the grid uses the pane's full width. Scrollback stays available with the
    /// trackpad or mouse wheel, and with Page Up and Page Down (fn-↑ and fn-↓).
    func hideScroller() {
        for case let scroller as NSScroller in subviews {
            scroller.isHidden = true
        }
    }

    /// Applies the parts of `appearance` that differ from `previous`.
    func apply(_ appearance: TerminalAppearance, previous: TerminalAppearance?) {
        let theme = appearance.theme
        if previous?.fontFamily != appearance.fontFamily
            || previous?.fontSize != appearance.fontSize
        {
            font = MawFonts.terminalFont(family: appearance.fontFamily, size: appearance.fontSize)
        }
        if previous?.theme != theme || previous?.backgroundOpacity != appearance.backgroundOpacity {
            installColors(theme.ansi.colors.map(\.terminalColor))
            nativeForegroundColor = theme.foreground.nsColor
            nativeBackgroundColor = theme.background.nsColor
            backgroundOpacity = appearance.backgroundOpacity
            caretColor = theme.cursor.nsColor
            caretTextColor = theme.cursorText.nsColor
            selectedTextBackgroundColor = theme.selectionBackground.nsColor
            selectedTextForegroundColor = theme.foreground.nsColor
        }
        if previous?.cursorShape != appearance.cursorShape {
            let style: CursorStyle =
                switch appearance.cursorShape {
                case .block: .steadyBlock
                case .bar: .steadyBar
                case .underline: .steadyUnderline
                }
            getTerminal().setCursorStyle(style)
        }
    }
}

/// SwiftTerm's view with maw's paste confirmation and focus reporting.
final class MawTerminalView: TerminalView {
    weak var pane: PaneController?

    // SwiftTerm sets `hasFocus` when the view becomes the first responder.
    override var hasFocus: Bool {
        get { super.hasFocus }
        set {
            super.hasFocus = newValue
            if newValue, let pane {
                pane.onFocus?(pane.id)
            }
        }
    }

    override func paste(_ sender: Any) {
        if let text = NSPasteboard.general.string(forType: .string),
            text.contains(where: \.isNewline),
            let pane, pane.isRunning,
            let confirm = pane.confirmPaste, !confirm(text)
        {
            return
        }
        super.paste(sender)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width > 40, newSize.height > 40 {
            pane?.startIfNeeded()
        }
    }
}
