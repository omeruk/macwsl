import Foundation

/// The arrangement of the menu bar. Items name registry commands; their titles, shortcuts, and
/// enabled states come from `CommandRegistry`, so the menu bar cannot disagree with the palette.
public struct MenuLayout: Hashable, Sendable {
    /// Standard items that AppKit implements and that are not maw commands.
    public enum SystemItem: Hashable, Sendable {
        case about, services, hide, hideOthers, showAll, quit
        case minimize, zoom, bringAllToFront, toggleFullScreen
    }

    public enum Item: Hashable, Sendable {
        case command(CommandID)
        case system(SystemItem)
        case separator
        /// The new-tab command of every profile, the default profile first.
        case newTabCommands
    }

    public struct Menu: Hashable, Sendable {
        public var title: String
        public var items: [Item]
        /// Whether AppKit should use this menu as the Window menu, listing open windows.
        public var isWindowsMenu = false
    }

    public var menus: [Menu]

    public static let standard = MenuLayout(menus: [
        Menu(
            title: "maw",
            items: [
                .system(.about), .separator, .command(.openSettings), .separator,
                .system(.services), .separator, .system(.hide), .system(.hideOthers),
                .system(.showAll), .separator, .system(.quit),
            ]),
        Menu(
            title: "Shell",
            items: [
                .command(.newWindow), .newTabCommands, .separator, .command(.closePane),
                .command(.closeTab),
            ]),
        Menu(title: "Edit", items: [.command(.copy), .command(.paste), .command(.selectAll)]),
        Menu(
            title: "View",
            items: [
                .command(.commandPalette), .command(.openDistributions), .separator,
                .command(.switchTheme), .separator, .command(.increaseFontSize),
                .command(.decreaseFontSize), .command(.resetFontSize), .separator,
                .system(.toggleFullScreen),
            ]),
        Menu(
            title: "Pane",
            items: [
                .command(.splitRight), .command(.splitDown), .separator,
                .command(.focusPane(.left)), .command(.focusPane(.right)),
                .command(.focusPane(.up)), .command(.focusPane(.down)), .separator,
                .command(.equalizePanes),
            ]),
        Menu(
            title: "Window",
            items: [.system(.minimize), .system(.zoom), .separator]
                + [.command(.previousTab), .command(.nextTab), .separator]
                + (1...9).map { .command(.selectTab($0)) }
                + [.separator, .system(.bringAllToFront)],
            isWindowsMenu: true),
    ])

    /// Every command the layout names directly.
    public var commandIDs: [CommandID] {
        menus.flatMap(\.items).compactMap { item in
            guard case .command(let id) = item else { return nil }
            return id
        }
    }
}
