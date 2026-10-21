import Foundation

/// Every command the app can perform. The window model handles each case in one `switch`, so
/// the compiler checks that no command is left without an implementation.
public enum CommandID: Hashable, Sendable {
    case newTab(profile: String)
    case newWindow
    case closePane
    case closeTab
    case selectTab(Int)
    case nextTab
    case previousTab

    case splitRight
    case splitDown
    case focusPane(FocusDirection)
    case equalizePanes

    case openDistributions
    case installDistribution

    case commandPalette
    case switchTheme
    case increaseFontSize
    case decreaseFontSize
    case resetFontSize

    case openSettings

    case copy
    case paste
    case selectAll

    /// esc on a screen tab: return to the previously focused tab.
    case back

    // Keys that move within the settings screen. They appear in its key hints and on the
    // keyboard page, but the screen's views handle them.
    case settingsMove
    case settingsChange
    case settingsOpenList
    case settingsSwitchBox
}

/// The groups shown in the palette and on the keyboard settings page.
public enum CommandGroup: String, Hashable, Sendable, CaseIterable {
    case tab, pane, distro, view, edit, app, settings
}

/// Where a command applies.
public enum CommandScope: Hashable, Sendable {
    /// Anywhere in a window.
    case window
    /// Only when the selected tab is a terminal.
    case terminal
    /// Only on a screen tab of this kind.
    case screen(ScreenKind)
    /// On any screen tab.
    case anyScreen
}

/// How a command is carried out.
public enum CommandKind: Hashable, Sendable {
    /// The window model performs it.
    case action
    /// AppKit's responder chain performs it, so that it reaches the focused view, which may
    /// be a text field rather than a terminal. The value is the selector's name.
    case responder(String)
    /// A key the screen's own views handle. Listed for the key hints and the keyboard page.
    case navigation
}

/// One command: everything the menu bar, the keyboard shortcuts, the key-hint bar, the command
/// palette, and the keyboard settings page need to know about it.
public struct CommandDefinition: Hashable, Sendable, Identifiable {
    public var id: CommandID
    /// The title in the palette and on the keyboard page, lowercase as in the design.
    public var title: String
    /// The title in the menu bar, in title case as macOS menus use.
    public var menuTitle: String
    public var group: CommandGroup
    public var shortcut: KeyShortcut?
    /// Keys to show instead of `shortcut`, for navigation that uses several keys, such as `↑↓`.
    public var keysOverride: String?
    /// The short description in the key-hint bar, if the command has a hint there.
    public var hint: String?
    public var scope: CommandScope
    public var kind: CommandKind
    /// Whether the command palette lists it.
    public var inPalette: Bool

    public init(
        _ id: CommandID, title: String, menuTitle: String? = nil, group: CommandGroup,
        shortcut: KeyShortcut? = nil, keysOverride: String? = nil, hint: String? = nil,
        scope: CommandScope = .window, kind: CommandKind = .action, inPalette: Bool = true
    ) {
        self.id = id
        self.title = title
        self.menuTitle = menuTitle ?? title.capitalized
        self.group = group
        self.shortcut = shortcut
        self.keysOverride = keysOverride
        self.hint = hint
        self.scope = scope
        self.kind = kind
        self.inPalette = inPalette
    }

    /// The keys as shown in the palette, the key hints, and the keyboard page, or an empty
    /// string if the command has none.
    public var keys: String {
        keysOverride ?? shortcut?.displayString ?? ""
    }
}

/// The state of a window that decides which commands are enabled.
public struct CommandContext: Hashable, Sendable {
    public enum Selection: Hashable, Sendable {
        case none
        case terminal(paneCount: Int)
        case screen(ScreenKind)
    }

    public var selection: Selection
    public var tabCount: Int
    /// Whether the focused terminal has a selection to copy.
    public var hasTextSelection: Bool
    public var fontSizeIsDefault: Bool

    public init(
        selection: Selection, tabCount: Int, hasTextSelection: Bool = false,
        fontSizeIsDefault: Bool = true
    ) {
        self.selection = selection
        self.tabCount = tabCount
        self.hasTextSelection = hasTextSelection
        self.fontSizeIsDefault = fontSizeIsDefault
    }

    /// The context when no terminal window is open, for example after closing the last one.
    public static let noWindow = CommandContext(selection: .none, tabCount: 0)
}
