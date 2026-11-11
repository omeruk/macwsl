import AppKit

/// Builds the menu bar from `MenuLayout.standard` and the command registry.
@MainActor
struct MenuBuilder {
    let registry: CommandRegistry
    /// Receives `performMenuCommand(_:)` and validates the items.
    let target: AnyObject

    func build() -> NSMenu {
        let bar = NSMenu()
        for layout in MenuLayout.standard.menus {
            let menu = NSMenu(title: layout.title)
            if layout.items.contains(.newTabCommands) {
                // The target refreshes the profiles when the menu opens.
                menu.delegate = target as? NSMenuDelegate
            }
            for item in layout.items {
                for menuItem in items(for: item) {
                    menu.addItem(menuItem)
                }
            }
            let barItem = NSMenuItem(title: layout.title, action: nil, keyEquivalent: "")
            barItem.submenu = menu
            bar.addItem(barItem)
            if layout.isWindowsMenu {
                NSApp.windowsMenu = menu
            }
        }
        return bar
    }

    private func items(for item: MenuLayout.Item) -> [NSMenuItem] {
        switch item {
        case .separator:
            return [.separator()]
        case .command(let id):
            return registry[id].map { [menuItem(for: $0)] } ?? []
        case .newTabCommands:
            return newTabItems()
        case .system(let system):
            return [systemItem(system)]
        }
    }

    /// The new-tab items, the default profile's, which has ⌘T, first.
    private func newTabItems() -> [NSMenuItem] {
        let newTabs = registry.commands.filter(\.id.isNewTab)
        let first = registry.newTabCommand
        return (newTabs.filter { $0.id == first } + newTabs.filter { $0.id != first })
            .map(menuItem(for:))
    }

    /// Replaces the new-tab items of `menu` with the registry's, in place, so that a menu that
    /// is open shows the profiles as soon as they change.
    func replaceNewTabItems(in menu: NSMenu) {
        let indices = menu.items.indices.filter { index in
            (menu.items[index].representedObject as? CommandBox)?.id.isNewTab ?? false
        }
        guard let first = indices.first else { return }
        for index in indices.reversed() {
            menu.removeItem(at: index)
        }
        for (offset, item) in newTabItems().enumerated() {
            menu.insertItem(item, at: first + offset)
        }
    }

    private func menuItem(for definition: CommandDefinition) -> NSMenuItem {
        let item: NSMenuItem
        switch definition.kind {
        case .responder(let selector):
            item = NSMenuItem(
                title: definition.menuTitle, action: NSSelectorFromString(selector),
                keyEquivalent: "")
        case .action, .navigation:
            item = NSMenuItem(
                title: definition.menuTitle,
                action: #selector(AppController.performMenuCommand(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = CommandBox(definition.id)
        }
        if let shortcut = definition.shortcut {
            let equivalent = shortcut.menuKeyEquivalent
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.modifiers
        }
        return item
    }

    private func systemItem(_ system: MenuLayout.SystemItem) -> NSMenuItem {
        switch system {
        case .about:
            return NSMenuItem(
                title: "About maw",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: "")
        case .services:
            let item = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
            let services = NSMenu(title: "Services")
            item.submenu = services
            NSApp.servicesMenu = services
            return item
        case .hide:
            return NSMenuItem(
                title: "Hide maw", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        case .hideOthers:
            let item = NSMenuItem(
                title: "Hide Others",
                action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            item.keyEquivalentModifierMask = [.command, .option]
            return item
        case .showAll:
            return NSMenuItem(
                title: "Show All",
                action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        case .quit:
            return NSMenuItem(
                title: "Quit maw", action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q")
        case .minimize:
            return NSMenuItem(
                title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m")
        case .zoom:
            return NSMenuItem(
                title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        case .bringAllToFront:
            return NSMenuItem(
                title: "Bring All to Front",
                action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        case .toggleFullScreen:
            let item = NSMenuItem(
                title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
                keyEquivalent: "f")
            item.keyEquivalentModifierMask = [.command, .control]
            return item
        }
    }
}
