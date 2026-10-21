import Foundation

/// The single definition of every command.
///
/// The menu bar (`MenuLayout`), the keyboard shortcuts (`KeyShortcutMonitor`), the key-hint bar,
/// the command palette, and the keyboard settings page all read this registry, so that a title,
/// a shortcut, or an enabled state cannot differ between them.
public struct CommandRegistry: Hashable, Sendable {
    public let commands: [CommandDefinition]
    private let index: [CommandID: Int]

    /// The registry for the given profiles. ⌘T opens a tab with `defaultProfile`; every profile
    /// gets a `new tab: <profile>` command in the palette.
    public init(profiles: [Profile], defaultProfile: String) {
        var commands: [CommandDefinition] = []
        let defaultID =
            profiles.contains { $0.id == defaultProfile } ? defaultProfile : profiles.first?.id

        // Tabs.
        for profile in profiles {
            let isDefault = profile.id == defaultID
            commands.append(
                CommandDefinition(
                    .newTab(profile: profile.id), title: "new tab: \(profile.paletteName)",
                    menuTitle: isDefault ? "New Tab" : "New Tab: \(profile.paletteName)",
                    group: .tab, shortcut: isDefault ? .command("t") : nil,
                    hint: isDefault ? "tab" : nil))
        }
        commands += [
            CommandDefinition(
                .newWindow, title: "new window", group: .tab, shortcut: .command("n")),
            CommandDefinition(
                .closePane, title: "close pane", group: .tab, shortcut: .command("w")),
            CommandDefinition(.closeTab, title: "close tab", group: .tab),
            CommandDefinition(
                .nextTab, title: "next tab", menuTitle: "Show Next Tab", group: .tab,
                shortcut: .command("]", .shift)),
            CommandDefinition(
                .previousTab, title: "previous tab", menuTitle: "Show Previous Tab", group: .tab,
                shortcut: .command("[", .shift)),
        ]
        for position in 1...9 {
            commands.append(
                CommandDefinition(
                    .selectTab(position), title: "select tab \(position)",
                    menuTitle: "Select Tab \(position)", group: .tab,
                    shortcut: .command(Character(String(position))), inPalette: false))
        }

        // Panes.
        commands += [
            CommandDefinition(
                .splitRight, title: "split pane right", group: .pane, shortcut: .command("d"),
                hint: "split", scope: .terminal),
            CommandDefinition(
                .splitDown, title: "split pane down", group: .pane,
                shortcut: .command("d", .shift), scope: .terminal),
            CommandDefinition(
                .equalizePanes, title: "equalize panes", group: .pane, scope: .terminal),
        ]
        let arrows: [(FocusDirection, KeyShortcut.Key, String)] = [
            (.left, .leftArrow, "left"), (.right, .rightArrow, "right"),
            (.up, .upArrow, "up"), (.down, .downArrow, "down"),
        ]
        for (direction, key, name) in arrows {
            commands.append(
                CommandDefinition(
                    .focusPane(direction), title: "focus pane \(name)",
                    menuTitle: "Select Pane \(name.capitalized)", group: .pane,
                    shortcut: KeyShortcut(key, [.option, .command]), scope: .terminal))
        }

        // Distributions.
        commands += [
            CommandDefinition(
                .openDistributions, title: "open distributions", menuTitle: "Distributions",
                group: .distro, shortcut: .command("l", .shift), hint: "distros"),
            CommandDefinition(
                .installDistribution, title: "install a distribution…",
                menuTitle: "Install a Distribution…", group: .distro,
                shortcut: KeyShortcut(.character("i")), hint: "install…",
                scope: .screen(.distributions)),
        ]

        // View.
        commands += [
            CommandDefinition(
                .commandPalette, title: "command palette", menuTitle: "Command Palette…",
                group: .view, shortcut: .command("p", .shift), hint: "commands",
                inPalette: false),
            CommandDefinition(
                .switchTheme, title: "theme: switch", menuTitle: "Switch Theme…", group: .view),
            CommandDefinition(
                .increaseFontSize, title: "font size: increase", menuTitle: "Bigger",
                group: .view, shortcut: .command("+")),
            CommandDefinition(
                .decreaseFontSize, title: "font size: decrease", menuTitle: "Smaller",
                group: .view, shortcut: .command("-")),
            CommandDefinition(
                .resetFontSize, title: "font size: reset", menuTitle: "Actual Size",
                group: .view, shortcut: .command("0")),
        ]

        // Edit. The responder chain carries these to the focused view.
        commands += [
            CommandDefinition(
                .copy, title: "copy", group: .edit, shortcut: .command("c"),
                kind: .responder("copy:"), inPalette: false),
            CommandDefinition(
                .paste, title: "paste", group: .edit, shortcut: .command("v"),
                kind: .responder("paste:"), inPalette: false),
            CommandDefinition(
                .selectAll, title: "select all", group: .edit, shortcut: .command("a"),
                kind: .responder("selectAll:"), inPalette: false),
        ]

        // App.
        commands.append(
            CommandDefinition(
                .openSettings, title: "open settings", menuTitle: "Settings…", group: .app,
                shortcut: .command(","), hint: "settings"))

        // Screen navigation, handled by the screens' views.
        commands += [
            CommandDefinition(
                .back, title: "back to the previous tab", group: .app,
                shortcut: KeyShortcut(.escape), hint: "back", scope: .anyScreen,
                inPalette: false),
            CommandDefinition(
                .settingsMove, title: "move between items", group: .settings,
                keysOverride: "↑↓", hint: "move", scope: .screen(.settings),
                kind: .navigation, inPalette: false),
            CommandDefinition(
                .settingsChange, title: "change the value", group: .settings,
                keysOverride: "←→", hint: "change", scope: .screen(.settings),
                kind: .navigation, inPalette: false),
            CommandDefinition(
                .settingsOpenList, title: "open the list of choices", group: .settings,
                shortcut: KeyShortcut(.return), hint: "list", scope: .screen(.settings),
                kind: .navigation, inPalette: false),
            CommandDefinition(
                .settingsSwitchBox, title: "switch between pages and fields", group: .settings,
                shortcut: KeyShortcut(.tab), hint: "switch box", scope: .screen(.settings),
                kind: .navigation, inPalette: false),
        ]

        self.commands = commands
        self.index = Dictionary(
            commands.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public subscript(id: CommandID) -> CommandDefinition? {
        index[id].map { commands[$0] }
    }

    /// Whether `id` can run in `context`.
    public func isEnabled(_ id: CommandID, in context: CommandContext) -> Bool {
        guard let definition = self[id] else { return false }
        if case .none = context.selection {
            // With no window, only commands that create one make sense.
            switch id {
            case .newTab, .newWindow, .openSettings, .openDistributions: return true
            default: return false
            }
        }
        switch definition.scope {
        case .window: break
        case .terminal:
            guard case .terminal = context.selection else { return false }
        case .screen(let kind):
            guard context.selection == .screen(kind) else { return false }
        case .anyScreen:
            guard case .screen = context.selection else { return false }
        }
        switch id {
        case .selectTab(let position):
            return position <= context.tabCount
        case .nextTab, .previousTab:
            return context.tabCount > 1
        case .equalizePanes:
            guard case .terminal(let paneCount) = context.selection else { return false }
            return paneCount > 1
        case .focusPane:
            guard case .terminal(let paneCount) = context.selection else { return false }
            return paneCount > 1
        case .copy:
            return context.hasTextSelection
        case .resetFontSize:
            return !context.fontSizeIsDefault
        case .installDistribution:
            // Installation arrives in phase 05.
            return false
        case .settingsMove, .settingsChange, .settingsOpenList, .settingsSwitchBox:
            return false
        default:
            return true
        }
    }

    /// A hint in the key-hint bar.
    public struct Hint: Hashable, Sendable {
        public var command: CommandID
        public var keys: String
        public var label: String
        public var isEnabled: Bool
        /// A short explanation shown after a disabled hint, such as when it will arrive.
        public var note: String?
    }

    /// The hints for the selected tab. Terminal tabs show the main shortcuts, as in
    /// `Main.dc.html`. Screens replace them with their own actions and `esc back`.
    public func hints(in context: CommandContext) -> [Hint] {
        let ids: [CommandID]
        switch context.selection {
        case .none, .terminal:
            let defaultTab = commands.first { definition in
                if case .newTab = definition.id { return definition.shortcut != nil }
                return false
            }
            ids =
                [defaultTab?.id].compactMap { $0 } + [
                    .splitRight, .openDistributions, .commandPalette, .openSettings,
                ]
        case .screen(.distributions):
            ids = [.installDistribution, .back]
        case .screen(.settings):
            ids = [.settingsMove, .settingsChange, .settingsOpenList, .settingsSwitchBox, .back]
        }
        return ids.compactMap { id in
            guard let definition = self[id], let label = definition.hint else { return nil }
            let enabled = definition.kind == .navigation || isEnabled(id, in: context)
            return Hint(
                command: id, keys: definition.keys, label: label, isEnabled: enabled,
                note: id == .installDistribution ? "arrives in a later version" : nil)
        }
    }

    /// The commands the palette lists in `context`: those marked for the palette and enabled.
    public func paletteCommands(in context: CommandContext) -> [CommandDefinition] {
        commands.filter { $0.inPalette && isEnabled($0.id, in: context) }
    }

    /// The commands that have keys, for the keyboard settings page, grouped in registry order.
    public var keyboardShortcuts: [CommandDefinition] {
        commands.filter { !$0.keys.isEmpty }
    }
}
