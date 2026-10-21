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

    init(settingsStore: SettingsStore, distributions: any DistributionProvider) {
        self.settingsStore = settingsStore
        self.distributions = distributions
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

    var profiles: [Profile] { [settings.localShellProfile] }

    var registry: CommandRegistry {
        CommandRegistry(profiles: profiles, defaultProfile: settings.defaultProfile)
    }

    var defaultProfile: Profile {
        profiles.first { $0.id == settings.defaultProfile } ?? profiles[0]
    }

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

    /// Ends every session. Called when the window closes.
    func shutDown() {
        refreshTask?.cancel()
        for pane in panes.values {
            pane.terminate()
        }
        panes.removeAll()
    }

    /// Programs running in this window other than idle shells, for close and quit
    /// confirmations.
    var runningProcessNames: [String] {
        panes.values.filter { $0.session.hasForegroundProcess }
            .map { $0.session.foregroundProcessName ?? $0.displayName }
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
            newTab(profile: profiles.first { $0.id == profileID } ?? defaultProfile)
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
            tabs.openScreen(.distributions)
        case .installDistribution, .settingsMove, .settingsChange, .settingsOpenList,
            .settingsSwitchBox:
            break
        case .commandPalette:
            if palette == nil {
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

    /// Closes a tab, asking first if a program is running in one of its panes.
    func closeTab(_ id: TabID) {
        guard let tab = tabs[id] else { return }
        let panesInTab = tab.splitTree?.panes.compactMap { panes[$0] } ?? []
        Task {
            guard await confirmClosing(panesInTab) else { return }
            removeTab(id)
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
        let session: any TerminalSession =
            switch profile.kind {
            case .localShell(let shell): LocalShellSession(shell: shell)
            }
        let pane = PaneController(session: session)
        pane.onCleanExit = { [weak self] id in self?.closePane(id, confirm: false) }
        pane.onFocus = { [weak self] id in self?.paneReceivedFocus(id) }
        pane.confirmPaste = { [weak self] text in self?.confirmPaste(text) ?? true }
        pane.apply(
            TerminalAppearance(settings: effectiveSettings, fontSizeAdjustment: fontSizeAdjustment))
        panes[pane.id] = pane
        return pane
    }

    private func split(_ axis: SplitAxis) {
        guard let tab = selectedTab, var tree = tab.splitTree,
            let current = panes[tree.focusedPane]
        else { return }
        let profile =
            profiles.first { profile in
                if case .localShell(let shell) = profile.kind,
                    let local = current.session as? LocalShellSession
                {
                    return shell == local.shell
                }
                return false
            } ?? defaultProfile
        let pane = makePane(profile: profile)
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
        guard let tab = tabs.tabs.first(where: { $0.splitTree?.contains(id) == true }),
            var tree = tab.splitTree
        else { return }
        Task {
            if confirm, let pane = panes[id] {
                guard await confirmClosing([pane]) else { return }
            }
            if tree.paneCount == 1 {
                removeTab(tab.id)
                return
            }
            // The tree may have changed while the confirmation was open.
            tree = tabs[tab.id]?.splitTree ?? tree
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

    private func confirmClosing(_ panes: [PaneController]) async -> Bool {
        guard settings.confirmCloseWithRunningProcess else { return true }
        let running = panes.filter { $0.session.hasForegroundProcess }
        guard !running.isEmpty else { return true }
        let names = running.map { $0.session.foregroundProcessName ?? $0.displayName }
        let many = panes.count > 1
        return await host?.confirm(
            Confirmation(
                message: many ? "Close this tab?" : "Close this pane?",
                detail: "\(Self.list(names)) \(names.count == 1 ? "is" : "are") still running "
                    + "and will be ended.",
                confirmTitle: "Close")) ?? true
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
