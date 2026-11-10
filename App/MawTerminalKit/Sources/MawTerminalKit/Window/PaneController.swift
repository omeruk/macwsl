import AppKit
import MawClient
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
/// and never loses the scrollback. When a session fails or ends with an error, the pane offers
/// a new session of its profile, which Enter starts in the same view.
@MainActor
@Observable
final class PaneController {
    let id: PaneID
    /// The profile the pane was opened with. A split and a new session open it again.
    let profile: Profile
    private(set) var session: any TerminalSession
    @ObservationIgnored let terminalView: MawTerminalView

    private(set) var title: String?
    private(set) var workingDirectory: String?
    private(set) var size = TerminalSize.default
    private(set) var termination: TerminationStatus?
    /// Why the session could not start, or why it failed afterwards.
    private(set) var failure: TerminalSessionError?

    /// Called when the session ends with status 0, so that the window can close the pane, as
    /// Windows Terminal does by default. A pane whose process failed stays open with its status.
    @ObservationIgnored var onCleanExit: ((PaneID) -> Void)?
    /// Called when the user clicks into the pane's terminal.
    @ObservationIgnored var onFocus: ((PaneID) -> Void)?
    /// Asks before pasting several lines. Returns whether to paste.
    @ObservationIgnored var confirmPaste: ((String) -> Bool)?
    /// Makes the session that Enter starts after the offer of a new session.
    @ObservationIgnored var makeSession: ((Profile) -> (any TerminalSession)?)?

    @ObservationIgnored private var appearance: TerminalAppearance?
    @ObservationIgnored private var started = false
    /// Whether the pane shows `[↩ new session]`, so that Enter starts one.
    @ObservationIgnored private(set) var offersNewSession = false

    init(id: PaneID = PaneID(), profile: Profile, session: any TerminalSession) {
        self.id = id
        self.profile = profile
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
        start()
    }

    private func start() {
        do {
            try session.start(size: size)
        } catch {
            show(error)
        }
    }

    /// Replaces the session with `replacement` and starts it in the same view, keeping the
    /// scrollback.
    private func replaceSession(with replacement: any TerminalSession) {
        session.delegate = nil
        session.terminate()
        session = replacement
        replacement.delegate = self
        title = nil
        workingDirectory = nil
        termination = nil
        failure = nil
        offersNewSession = false
        start()
    }

    /// Prints a failure as `maw` prints it, in the theme's red, then offers a new session.
    private func show(_ error: TerminalSessionError) {
        failure = error
        write(runtimeErrorText(error), style: "31")
        offerNewSession()
    }

    private func offerNewSession() {
        offersNewSession = true
        write("[↩ new session]\n", style: "2")
    }

    /// Writes lines that end in a line feed, from the start of a line, in an SGR style such as
    /// `2` (dim). The terminal needs CR LF, and messages contain line feeds of their own.
    private func write(_ text: String, style: String) {
        let atLineStart = terminalView.getTerminal().getCursorLocation().x == 0
        let lines = text.replacingOccurrences(of: "\n", with: "\r\n")
        terminalView.feed(text: "\(atLineStart ? "" : "\r\n")\u{1B}[\(style)m\(lines)\u{1B}[0m")
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

    func session(_ session: any TerminalSession, didFailWith error: TerminalSessionError) {
        show(error)
    }

    func session(
        _ session: any TerminalSession, didFallBackTo replacement: any TerminalSession,
        notice: String
    ) {
        write(notice, style: "2")
        replaceSession(with: replacement)
    }

    func session(_ session: any TerminalSession, didTerminateWith status: TerminationStatus) {
        termination = status
        if status == .exited(0) {
            onCleanExit?(id)
        } else {
            write("[\(status.description)]\n", style: "2")
            offerNewSession()
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

    /// Typed keys go to the session. After the offer of a new session, Enter starts one, and
    /// other keys are dropped.
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard offersNewSession else {
            session.send(data)
            return
        }
        if data.contains(0x0D), let replacement = makeSession?(profile) {
            replaceSession(with: replacement)
        }
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
