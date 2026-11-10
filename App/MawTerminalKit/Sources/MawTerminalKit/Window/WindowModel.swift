import AppKit
import Observation
import os

/// A question the window asks before doing something that cannot be undone.
struct Confirmation {
    var message: String
    var detail: String
    var confirmTitle: String
}

/// What a window model needs from the window that shows it.
@MainActor
protocol WindowHost: AnyObject {
    func confirm(_ confirmation: Confirmation) async -> Bool
    func closeWindow()
    func focusTerminal(_ view: NSView)
    func openNewWindow()
    func setWindowTitle(_ title: String)
    /// The theme in use changed: the settings changed, or a theme is being previewed.
    func chromeDidChange()
}

/// The state of the command palette.
struct PaletteState: Equatable {
    enum Mode: Equatable {
        case commands
        /// Choosing a theme. Moving through the list previews each theme; esc restores the
        /// theme that was selected when the list opened.
        case themes
    }

    var mode = Mode.commands
    var query = ""
    var selection = 0
}

/// The state and behavior of one window: its tabs, the panes in them, and every command.
@MainActor
@Observable
final class WindowModel {
    let settingsStore: SettingsStore
    let distributions: any DistributionProvider
    @ObservationIgnored weak var host: (any WindowHost)?

    private(set) var tabs = TabList()
    private(set) var panes: [PaneID: PaneController] = [:]
    var palette: PaletteState?
    /// ⌘+ and ⌘- change the font size of this window only, as in Terminal and Windows Terminal.
    private(set) var fontSizeAdjustment = 0.0
    /// A theme shown instead of the selected one while the user browses themes.
    var previewThemeName: String? {
        didSet { applyAppearance() }
    }
    /// The title bar's height and the space the traffic lights need, measured from the window.
    var titleBarHeight: CGFloat = 38
    var trafficLightsWidth: CGFloat = 78

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let makeSession: @MainActor (Profile) -> any TerminalSession
    /// Set while a close question waits for the sessions' answers or for the user, so that a
    /// second ⌘W or close is ignored meanwhile.
    @ObservationIgnored private(set) var isAskingToClose = false
    @ObservationIgnored private var isShutDown = false

    /// - Parameter makeSession: Makes a pane's session for a profile. Tests pass fake
    ///   sessions; the app asks the session layer (`Profile.makeSession(localShell:)`).
    init(
        settingsStore: SettingsStore, distributions: any DistributionProvider,
        makeSession: (@MainActor (Profile) -> any TerminalSession)? = nil
    ) {
        self.settingsStore = settingsStore
        self.distributions = distributions
        self.makeSession =
            makeSession ?? { [settingsStore] profile in
                profile.makeSession(localShell: settingsStore.settings.localShellProfile)
            }
    }

    var settings: Settings { settingsStore.settings }

    /// The settings with the previewed theme, if any, as the window should look right now.
    var effectiveSettings: Settings {
        var settings = settingsStore.settings
        if let previewThemeName {
            settings.theme = previewThemeName
        }
        return settings
    }

    var chrome: ChromePalette { effectiveSettings.selectedTheme.chromePalette }

    /// The profiles that the menus, the palette, and the settings offer: the default
    /// distribution, each one the daemon reported, and the local shell.
    var profiles: [Profile] {
        settings.profiles(distributions: distributions.distributions.map(\.name))
    }

    var registry: CommandRegistry {
        CommandRegistry(profiles: profiles, newTabProfile: defaultProfile)
    }

    /// The profile of a new tab, from the setting itself rather than from the list, so that a
    /// distribution opens whether or not the list has arrived or contains it.
    var defaultProfile: Profile { settings.newTabProfile }

    // MARK: Lifecycle

    func start() {
        newTab(profile: defaultProfile)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.refreshVisiblePanes()
            }
        }
    }

    /// Ends every session, which hangs up Linux sessions and ends their leases. Called when
    /// the window closes.
    func shutDown() {
        isShutDown = true
        refreshTask?.cancel()
        for pane in panes.values {
            pane.terminate()
        }
        panes.removeAll()
    }

    // MARK: Selection

    var selectedTab: Tab? { tabs.selectedTab }

    var focusedPane: PaneController? {
        guard let tree = selectedTab?.splitTree else { return nil }
        return panes[tree.focusedPane]
    }

    var context: CommandContext {
        let selection: CommandContext.Selection =
            switch selectedTab?.content {
            case .terminal(let tree)?: .terminal(paneCount: tree.paneCount)
            case .screen(let kind)?: .screen(kind)
            case nil: .none
            }
        return CommandContext(
            selection: selection, tabCount: tabs.count,
            hasTextSelection: focusedPane?.terminalView.selection.active ?? false,
            fontSizeIsDefault: fontSizeAdjustment == 0)
    }

    func isEnabled(_ id: CommandID) -> Bool {
        registry.isEnabled(id, in: context)
    }

    // MARK: Commands

    /// Performs a command if it is enabled. Every command reaches the window through here,
    /// from the menu bar, a shortcut, the palette, a key hint, or a click.
    func perform(_ id: CommandID) {
        guard isEnabled(id) else { return }
        if palette != nil, id != .commandPalette {
            closePalette(restoringTheme: palette?.mode == .themes)
        }
        switch id {
        case .newTab(let profileID):
            newTab(profile: settings.profile(id: profileID) ?? defaultProfile)
        case .newWindow:
            host?.openNewWindow()
        case .closePane:
            closeFocusedPaneOrScreen()
        case .closeTab:
            if let id = tabs.selectedID { closeTab(id) }
        case .selectTab(let position):
            tabs.select(position: position)
            focusSelectedTab()
        case .nextTab:
            tabs.selectAdjacent(forward: true)
            focusSelectedTab()
        case .previousTab:
            tabs.selectAdjacent(forward: false)
            focusSelectedTab()
        case .splitRight:
            split(.horizontal)
        case .splitDown:
            split(.vertical)
        case .focusPane(let direction):
            updateSelectedTree { $0.moveFocus(direction) }
            focusSelectedTab()
        case .equalizePanes:
            updateSelectedTree { $0.equalize() }
        case .openDistributions:
            distributions.refresh()
            tabs.openScreen(.distributions)
        case .installDistribution, .settingsMove, .settingsChange, .settingsOpenList,
            .settingsSwitchBox:
            break
        case .commandPalette:
            if palette == nil {
                distributions.refresh()
                palette = PaletteState()
            } else {
                closePalette(restoringTheme: palette?.mode == .themes)
            }
        case .switchTheme:
            openThemePalette()
        case .increaseFontSize:
            adjustFontSize(by: 1)
        case .decreaseFontSize:
            adjustFontSize(by: -1)
        case .resetFontSize:
            fontSizeAdjustment = 0
            applyAppearance()
        case .openSettings:
            tabs.openScreen(.settings)
        case .copy, .paste, .selectAll:
            // Responder-chain commands; the menu sends them to the focused view.
            break
        case .back:
            if tabs.returnToPrevious() {
                focusSelectedTab()
            }
        }
        updateWindowTitle()
    }

    // MARK: Tabs

    func newTab(profile: Profile) {
        let pane = makePane(profile: profile)
        tabs.append(Tab(content: .terminal(SplitTree(pane: pane.id))))
        focusSelectedTab()
    }

    func select(_ id: TabID) {
        tabs.select(id)
        focusSelectedTab()
        updateWindowTitle()
    }

    func moveTab(_ id: TabID, to index: Int) {
        tabs.move(id, to: index)
    }

    /// Closes a tab, asking first if a program is running in one of its panes. A pane opened
    /// in the tab while the question was open makes it ask again, about every pane.
    func closeTab(_ id: TabID) {
        guard let tab = tabs[id] else { return }
        let panesInTab = tab.splitTree?.panes.compactMap { panes[$0] } ?? []
        Task {
            guard await confirmClosing(panesInTab, message: "Close this tab?") else { return }
            let current = tabs[id]?.splitTree?.panes ?? []
            guard Set(current).isSubset(of: panesInTab.map(\.id)) else { return closeTab(id) }
            removeTab(id)
        }
    }

    /// Closes the window, asking first if a program is running in one of its panes. A pane
    /// opened while the question was open makes it ask again, about every pane.
    func requestCloseWindow() {
        Task {
            let all = Array(panes.values)
            guard await confirmClosing(all, message: "Close this window?") else { return }
            guard Set(panes.keys).isSubset(of: all.map(\.id)) else { return requestCloseWindow() }
            host?.closeWindow()
        }
    }

    private func removeTab(_ id: TabID) {
        guard let tab = tabs.remove(id) else { return }
        for paneID in tab.splitTree?.panes ?? [] {
            panes.removeValue(forKey: paneID)?.terminate()
        }
        if tabs.isEmpty {
            host?.closeWindow()
        } else {
            focusSelectedTab()
            updateWindowTitle()
        }
    }

    // MARK: Panes

    private func makePane(profile: Profile) -> PaneController {
        let pane = PaneController(profile: profile, session: newSession(of: profile))
        pane.makeSession = { [weak self] profile in self?.newSession(of: profile) }
        pane.onCleanExit = { [weak self] id in self?.closePane(id, confirm: false) }
        pane.onFocus = { [weak self] id in self?.paneReceivedFocus(id) }
        pane.confirmPaste = { [weak self] text in self?.confirmPaste(text) ?? true }
        pane.apply(
            TerminalAppearance(settings: effectiveSettings, fontSizeAdjustment: fontSizeAdjustment))
        panes[pane.id] = pane
        return pane
    }

    /// A session of `profile` as the settings configure it now, so that a new session of the
    /// local shell's profile follows a change of the shell.
    private func newSession(of profile: Profile) -> any TerminalSession {
        makeSession(settings.profile(id: profile.id) ?? profile)
    }

    /// Splits the focused pane. The new pane opens what its session names, such as the
    /// distribution that a Linux session opened, or else the profile the focused pane was
    /// opened with.
    private func split(_ axis: SplitAxis) {
        guard let tab = selectedTab, var tree = tab.splitTree,
            let current = panes[tree.focusedPane]
        else { return }
        let pane = makePane(profile: current.session.splitProfile ?? current.profile)
        tree.split(tree.focusedPane, axis: axis, newPane: pane.id)
        tabs.update(tab.id, content: .terminal(tree))
        focusSelectedTab()
    }

    /// ⌘W: closes the focused pane, and its tab with its last pane. On a screen tab, closes
    /// the screen.
    private func closeFocusedPaneOrScreen() {
        guard let tab = selectedTab else { return }
        guard let tree = tab.splitTree else {
            removeTab(tab.id)
            return
        }
        closePane(tree.focusedPane, confirm: true)
    }

    func closePane(_ id: PaneID, confirm: Bool) {
        guard let pane = panes[id] else { return }
        Task {
            if confirm {
                let isLast = tabs.tabs.contains { $0.splitTree?.panes == [id] }
                let message = isLast ? "Close this tab?" : "Close this pane?"
                guard await confirmClosing([pane], message: message) else { return }
            }
            // The tree may have changed while the question was open.
            guard let tab = tabs.tabs.first(where: { $0.splitTree?.contains(id) == true }),
                var tree = tab.splitTree
            else { return }
            if tree.paneCount == 1 {
                removeTab(tab.id)
                return
            }
            tree.close(id)
            panes.removeValue(forKey: id)?.terminate()
            tabs.update(tab.id, content: .terminal(tree))
            if tabs.selectedID == tab.id {
                focusSelectedTab()
            }
        }
    }

    func focus(_ pane: PaneID) {
        updateSelectedTree { $0.focus(pane) }
        focusSelectedTab()
    }

    func setRatio(_ ratio: Double, of split: SplitID) {
        updateSelectedTree { $0.setRatio(ratio, of: split) }
    }

    func equalize() {
        updateSelectedTree { $0.equalize() }
    }

    private func paneReceivedFocus(_ id: PaneID) {
        guard let tree = selectedTab?.splitTree, tree.contains(id), tree.focusedPane != id else {
            return
        }
        updateSelectedTree { $0.focus(id) }
        updateWindowTitle()
    }

    private func updateSelectedTree(_ change: (inout SplitTree) -> Void) {
        guard let tab = selectedTab, var tree = tab.splitTree else { return }
        change(&tree)
        tabs.update(tab.id, content: .terminal(tree))
    }

    /// Makes the focused pane's terminal the first responder once SwiftUI has placed it.
    func focusSelectedTab() {
        guard let pane = focusedPane else { return }
        Task { [weak self] in
            await Task.yield()
            self?.host?.focusTerminal(pane.terminalView)
        }
    }

    private func refreshVisiblePanes() {
        let visible = Set(selectedTab?.splitTree?.panes ?? [])
        for (id, pane) in panes {
            pane.refresh(isVisible: visible.contains(id))
        }
        updateWindowTitle()
    }

    private func updateWindowTitle() {
        let title: String
        if let screen = selectedTab?.screen {
            title = screen.title
        } else if let pane = focusedPane {
            title = pane.title ?? pane.displayName
        } else {
            title = "maw"
        }
        host?.setWindowTitle(title)
    }

    // MARK: Confirmations

    /// How long a session may take to say what runs in its foreground.
    static let foregroundTimeout = Duration.milliseconds(500)

    /// Asks before closing `panes` if a program runs in one of them. Returns false when the
    /// user cancels, while another close question is pending, and when the window closed while
    /// the sessions answered.
    private func confirmClosing(_ panes: [PaneController], message: String) async -> Bool {
        guard settings.confirmCloseWithRunningProcess else { return true }
        guard !isAskingToClose else { return false }
        isAskingToClose = true
        defer { isAskingToClose = false }
        let detail = await Self.runningDetail(of: panes)
        guard !isShutDown else { return false }
        guard let detail else { return true }
        let question = Confirmation(message: message, detail: detail, confirmTitle: "Close")
        return await host?.confirm(question) ?? false
    }

    /// Whether to quit: asks the sessions of `panes()` at once, then `ask` if a program runs.
    /// A pane opened while the question was open makes it ask again, about every pane.
    static func confirmQuitting(
        _ panes: () -> [PaneController], ask: (Confirmation) async -> Bool
    ) async -> Bool {
        var asked: Set<PaneID> = []
        while case let current = panes(), !Set(current.map(\.id)).isSubset(of: asked) {
            asked = Set(current.map(\.id))
            guard let detail = await runningDetail(of: current) else { continue }
            let question = Confirmation(message: "Quit maw?", detail: detail, confirmTitle: "Quit")
            guard await ask(question) else { return false }
        }
        return true
    }

    /// What a close or quit question says about `panes`, or `nil` when every shell waits at
    /// its prompt. Names the programs, and the panes whose session did not answer in time.
    static func runningDetail(
        of panes: [PaneController], within timeout: Duration = foregroundTimeout
    ) async -> String? {
        let reports = await foregroundReports(of: panes.map(\.session), within: timeout)
        var programs: [String] = []
        var silent: [String] = []
        for (pane, report) in zip(panes, reports) {
            switch report {
            case .none: break
            case .program(let name): programs.append(name ?? "a program in \(pane.displayName)")
            case .noAnswer: silent.append(pane.displayName)
            }
        }
        var sentences: [String] = []
        if !programs.isEmpty {
            let verb = programs.count == 1 ? "is" : "are"
            sentences.append("\(list(programs)) \(verb) still running and will be ended.")
        }
        if !silent.isEmpty {
            let milliseconds = Int(timeout / .milliseconds(1))
            sentences.append(
                "A program may be running in \(list(silent)), which did not answer within "
                    + "\(milliseconds) ms.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// Asks every session at once what runs in its foreground, with one deadline. A session
    /// that has not answered by then counts as `noAnswer`. The main actor only awaits.
    static func foregroundReports(of sessions: [any TerminalSession], within timeout: Duration)
        async -> [ForegroundReport]
    {
        var reports = [ForegroundReport](repeating: .noAnswer, count: sessions.count)
        guard !sessions.isEmpty else { return reports }
        let (answers, answer) = AsyncStream<(Int, ForegroundReport)?>.makeStream()
        for (index, session) in sessions.enumerated() {
            Task { answer.yield((index, await session.foregroundProgram(within: timeout))) }
        }
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            answer.yield(nil)
        }
        var pending = sessions.count
        for await next in answers {
            guard let (index, report) = next else { break }
            reports[index] = report
            pending -= 1
            if pending == 0 { break }
        }
        deadline.cancel()
        answer.finish()
        return reports
    }

    private func confirmPaste(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).count
        let alert = NSAlert()
        alert.messageText = "Paste \(lines) lines?"
        alert.informativeText =
            "The text contains line breaks. A shell may run each line as a command."
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + ", and " + names.last!
        }
    }

    // MARK: Appearance

    private func adjustFontSize(by step: Double) {
        let base = settings.fontSize
        let target = min(
            max(base + fontSizeAdjustment + step, Settings.fontSizeRange.lowerBound),
            Settings.fontSizeRange.upperBound)
        fontSizeAdjustment = target - base
        applyAppearance()
    }

    /// Applies the settings to every pane. Called when the settings or the preview change.
    func applyAppearance() {
        let appearance = TerminalAppearance(
            settings: effectiveSettings, fontSizeAdjustment: fontSizeAdjustment)
        for pane in panes.values {
            pane.apply(appearance)
        }
        host?.chromeDidChange()
    }

    // MARK: Palette

    private func openThemePalette() {
        let names = settings.availableThemes.map(\.name)
        palette = PaletteState(
            mode: .themes, query: "", selection: names.firstIndex(of: settings.theme) ?? 0)
    }

    func closePalette(restoringTheme: Bool) {
        if restoringTheme {
            previewThemeName = nil
        }
        palette = nil
        focusSelectedTab()
    }

    /// Applies the previewed theme and closes the palette.
    func choosePreviewedTheme() {
        if let name = previewThemeName {
            settingsStore.update { $0.theme = name }
        }
        previewThemeName = nil
        palette = nil
        focusSelectedTab()
    }
}
