import MawTerminalKit
import Testing

@Suite struct CommandRegistryTests {
    let registry = CommandRegistry(
        profiles: [
            .localShell("/bin/zsh"), Profile(id: "other", kind: .localShell(shell: "/bin/bash")),
        ],
        defaultProfile: Profile.localShellID)

    let terminalContext = CommandContext(selection: .terminal(paneCount: 2), tabCount: 3)

    @Test func identifiersAreUnique() {
        let ids = registry.commands.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func shortcutsAreUniqueWithinOverlappingScopes() {
        // Window-wide and terminal shortcuts can both apply at once, so they must all differ.
        let global = registry.commands.filter { definition in
            switch definition.scope {
            case .window, .terminal: definition.shortcut != nil
            case .screen, .anyScreen: false
            }
        }
        let shortcuts = global.compactMap(\.shortcut)
        #expect(Set(shortcuts).count == shortcuts.count)
    }

    @Test func menuLayoutNamesOnlyRegisteredCommands() {
        for id in MenuLayout.standard.commandIDs {
            #expect(registry[id] != nil, "\(id) is in the menu layout but not in the registry")
        }
    }

    @Test func everyActionIsReachableFromTheMenuOrThePalette() {
        let inMenu = Set(MenuLayout.standard.commandIDs)
        for definition in registry.commands where definition.kind == .action {
            let reachable =
                inMenu.contains(definition.id) || definition.inPalette
                || definition.scope == .screen(.distributions) || definition.scope == .anyScreen
            if case .newTab = definition.id { continue }
            #expect(reachable, "\(definition.id) has no menu item and is not in the palette")
        }
    }

    @Test func theDefaultProfileGetsCommandT() {
        #expect(registry[.newTab(profile: "local")]?.shortcut == .command("t"))
        #expect(registry[.newTab(profile: "other")]?.shortcut == nil)
        #expect(registry[.newTab(profile: "local")]?.title == "new tab: zsh on this mac")
    }

    @Test func anUnknownDefaultProfileFallsBackToTheFirst() {
        let registry = CommandRegistry(profiles: [.localShell("/bin/zsh")], defaultProfile: "gone")
        #expect(registry[.newTab(profile: "local")]?.shortcut == .command("t"))
    }

    @Test func designShortcutsAreDisplayedAsInTheBoards() {
        #expect(registry[.splitRight]?.keys == "⌘D")
        #expect(registry[.splitDown]?.keys == "⌘⇧D")
        #expect(registry[.openDistributions]?.keys == "⌘⇧L")
        #expect(registry[.commandPalette]?.keys == "⌘⇧P")
        #expect(registry[.openSettings]?.keys == "⌘,")
        #expect(registry[.increaseFontSize]?.keys == "⌘+")
        #expect(registry[.focusPane(.left)]?.keys == "⌥⌘←")
        #expect(registry[.nextTab]?.keys == "⌘⇧]")
        #expect(registry[.selectTab(9)]?.keys == "⌘9")
    }

    @Test func terminalHintsMatchTheMainBoard() {
        let hints = registry.hints(in: terminalContext)
        #expect(hints.map(\.keys) == ["⌘T", "⌘D", "⌘⇧L", "⌘⇧P", "⌘,"])
        #expect(hints.map(\.label) == ["tab", "split", "distros", "commands", "settings"])
        #expect(hints.allSatisfy { $0.isEnabled })
    }

    @Test func distributionsHintsShowInstallAsNotYetAvailable() {
        let context = CommandContext(selection: .screen(.distributions), tabCount: 2)
        let hints = registry.hints(in: context)
        #expect(hints.map(\.keys) == ["i", "esc"])
        #expect(hints[0].label == "install…")
        #expect(!hints[0].isEnabled)
        #expect(hints[0].note == "arrives in a later version")
        #expect(hints[1].label == "back")
        #expect(hints[1].isEnabled)
    }

    @Test func settingsHintsListTheNavigationKeys() {
        let context = CommandContext(selection: .screen(.settings), tabCount: 2)
        let hints = registry.hints(in: context)
        #expect(hints.map(\.keys) == ["↑↓", "←→", "↩", "⇥", "esc"])
        #expect(hints.allSatisfy { $0.isEnabled })
    }

    @Test func paneCommandsNeedATerminalTab() {
        let screen = CommandContext(selection: .screen(.settings), tabCount: 2)
        #expect(!registry.isEnabled(.splitRight, in: screen))
        #expect(registry.isEnabled(.splitRight, in: terminalContext))
        #expect(registry.isEnabled(.back, in: screen))
        #expect(!registry.isEnabled(.back, in: terminalContext))
    }

    @Test func enabledStatesFollowTheContext() {
        let single = CommandContext(selection: .terminal(paneCount: 1), tabCount: 1)
        #expect(!registry.isEnabled(.equalizePanes, in: single))
        #expect(!registry.isEnabled(.focusPane(.left), in: single))
        #expect(!registry.isEnabled(.nextTab, in: single))
        #expect(!registry.isEnabled(.selectTab(2), in: single))
        #expect(registry.isEnabled(.selectTab(3), in: terminalContext))
        #expect(!registry.isEnabled(.selectTab(4), in: terminalContext))
        #expect(!registry.isEnabled(.copy, in: terminalContext))
        #expect(!registry.isEnabled(.installDistribution, in: terminalContext))
        #expect(!registry.isEnabled(.resetFontSize, in: terminalContext))
    }

    @Test func withoutAWindowOnlyWindowCreatingCommandsRun() {
        #expect(registry.isEnabled(.newWindow, in: .noWindow))
        #expect(registry.isEnabled(.newTab(profile: "local"), in: .noWindow))
        #expect(!registry.isEnabled(.closePane, in: .noWindow))
        #expect(!registry.isEnabled(.commandPalette, in: .noWindow))
    }

    @Test func thePaletteListsEnabledPaletteCommandsOnly() {
        let titles = registry.paletteCommands(in: terminalContext).map(\.title)
        #expect(titles.contains("split pane right"))
        #expect(titles.contains("new tab: bash on this mac"))
        #expect(!titles.contains("command palette"))
        #expect(!titles.contains("select tab 1"))
    }

    @Test func theKeyboardPageListsEveryShortcut() {
        let listed = Set(registry.keyboardShortcuts.map(\.id))
        for definition in registry.commands where definition.shortcut != nil {
            #expect(listed.contains(definition.id))
        }
    }
}

@Suite struct KeyShortcutTests {
    @Test func matchesPlainCommandKeys() {
        let shortcut = KeyShortcut.command("t")
        #expect(
            shortcut.matches(
                key: .character("t"), unshiftedKey: .character("t"), modifiers: .command))
        #expect(
            !shortcut.matches(
                key: .character("t"), unshiftedKey: .character("t"), modifiers: [.command, .option])
        )
        #expect(
            !shortcut.matches(
                key: .character("y"), unshiftedKey: .character("y"), modifiers: .command))
    }

    @Test func shiftedLettersMatchTheirShortcut() {
        let shortcut = KeyShortcut.command("p", .shift)
        #expect(
            shortcut.matches(
                key: .character("P"), unshiftedKey: .character("p"), modifiers: [.command, .shift]))
        #expect(
            !shortcut.matches(
                key: .character("p"), unshiftedKey: .character("p"), modifiers: .command))
    }

    @Test func shiftedBracketsMatchByTheirUnshiftedKey() {
        let shortcut = KeyShortcut.command("]", .shift)
        // A US layout reports ⌘⇧] as "}".
        #expect(
            shortcut.matches(
                key: .character("}"), unshiftedKey: .character("]"), modifiers: [.command, .shift]))
        #expect(
            !shortcut.matches(
                key: .character("]"), unshiftedKey: .character("]"), modifiers: .command))
    }

    @Test func plusMatchesWithAndWithoutShift() {
        let shortcut = KeyShortcut.command("+")
        // ⌘+ on a US layout is ⌘⇧=.
        #expect(
            shortcut.matches(
                key: .character("+"), unshiftedKey: .character("="), modifiers: [.command, .shift]))
        // ⌘= is accepted as well.
        #expect(
            shortcut.matches(
                key: .character("="), unshiftedKey: .character("="), modifiers: .command))
        // Layouts with a dedicated + key.
        #expect(
            shortcut.matches(
                key: .character("+"), unshiftedKey: .character("+"), modifiers: .command))
    }

    @Test func shiftDoesNotLeakIntoLetterShortcuts() {
        // ⌘⇧D is split down; it must not trigger ⌘D.
        let splitRight = KeyShortcut.command("d")
        #expect(
            !splitRight.matches(
                key: .character("D"), unshiftedKey: .character("d"), modifiers: [.command, .shift]))
    }

    @Test func arrowsWithOptionCommand() {
        let shortcut = KeyShortcut(.leftArrow, [.option, .command])
        #expect(
            shortcut.matches(
                key: .leftArrow, unshiftedKey: .leftArrow, modifiers: [.option, .command]))
        #expect(!shortcut.matches(key: .leftArrow, unshiftedKey: .leftArrow, modifiers: .command))
    }
}
