import Testing

@testable import MawTerminalKit

@Suite struct PaletteStateTests {
    @Test func theSelectionFollowsItsRowWhenRowsAreInsertedAbove() {
        var state = PaletteState()
        state.select(2, in: ["new tab", "new window", "split right"])
        // The daemon's list arrives and adds a profile's row above.
        let ids = ["new tab", "new tab: Ubuntu-24.04", "new window", "split right"]
        #expect(state.selectedIndex(in: ids) == 3)
    }

    @Test func theSelectionFollowsItsRowWhenRowsAreRemovedAbove() {
        var state = PaletteState()
        state.select(3, in: ["new tab", "new tab: Ubuntu-24.04", "new window", "split right"])
        #expect(state.selectedIndex(in: ["new tab", "new window", "split right"]) == 2)
    }

    @Test func aSelectedRowThatDisappearsLeavesTheSelectionWithinTheRows() {
        var state = PaletteState()
        state.select(3, in: ["new tab", "new tab: Ubuntu-24.04", "new window", "split right"])
        #expect(state.selectedIndex(in: ["new tab", "new window"]) == 1)
        #expect(state.selectedIndex(in: []) == 0)
    }

    @Test func withoutAChosenRowThePositionCounts() {
        let state = PaletteState(mode: .themes, query: "", selection: 1)
        #expect(state.selectedIndex(in: ["maw", "paper", "night"]) == 1)
    }
}

/// The command palette's lists in a window: which view has the keys, how ↑↓ move the
/// selection, and the theme preview. That SwiftUI delivers the keys to the palette's view once
/// it has them is not covered here, because it needs a window on screen.
@MainActor @Suite struct CommandPaletteTests {
    /// Long enough for the window's deferred focus to run.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// Enter on "theme: switch" closes the command list and opens the theme list in the same
    /// turn. The terminal must not take the keys from it, or ↑↓ and esc would reach the shell.
    @Test func theThemeListKeepsTheKeysWhenItReplacesTheCommandList() async {
        let (model, host, _) = WindowModelTests().window()
        await settle()
        let before = host.terminalFocuses
        model.perform(.commandPalette)
        model.perform(.switchTheme)
        await settle()
        #expect(model.palette?.mode == .themes)
        #expect(host.terminalFocuses == before)

        model.closePalette(restoringTheme: true)
        await settle()
        #expect(model.palette == nil)
        #expect(host.terminalFocuses == before + 1)
    }

    /// ↑↓ move through the themes, each move previews the theme it selects, the ends stop the
    /// selection, and esc restores the theme that was selected when the list opened.
    @Test func arrowsPreviewEachThemeAndEscRestoresTheOriginal() throws {
        let (model, _, _) = WindowModelTests().window()
        let original = model.settings.theme
        let names = model.settings.availableThemes.map(\.name)
        let start = try #require(names.firstIndex(of: original))
        model.perform(.switchTheme)
        #expect(model.palette?.selectedIndex(in: names) == start)

        for step in [1, 1, -1] {
            let expected = min(
                max((model.palette?.selectedIndex(in: names) ?? 0) + step, 0), names.count - 1)
            model.movePaletteSelection(by: step, in: names)
            #expect(model.palette?.selectedIndex(in: names) == expected)
            #expect(model.previewThemeName == names[expected])
            #expect(model.effectiveSettings.theme == names[expected])
        }
        model.movePaletteSelection(by: -names.count, in: names)
        #expect(model.palette?.selectedIndex(in: names) == 0)
        #expect(model.previewThemeName == names[0])
        model.movePaletteSelection(by: names.count, in: names)
        #expect(model.palette?.selectedIndex(in: names) == names.count - 1)

        model.closePalette(restoringTheme: true)
        #expect(model.previewThemeName == nil)
        #expect(model.effectiveSettings.theme == original)
        #expect(model.settings.theme == original)
    }

    /// A preview redraws the query field, and SwiftUI writes the unchanged text back through
    /// its binding, as the app linked against the macOS 27 SDK does. That write must leave the
    /// selection and the preview where ↑↓ put them; only a new query selects its first match.
    @Test func writingTheSameQueryBackKeepsTheSelectionAndThePreview() throws {
        let (model, _, _) = WindowModelTests().window()
        let names = model.settings.availableThemes.map(\.name)
        model.perform(.switchTheme)
        model.movePaletteSelection(by: 1, in: names)
        model.movePaletteSelection(by: 1, in: names)
        let selected = try #require(model.palette?.selectedIndex(in: names))
        #expect(selected == 2)

        expectFalse(model.setPaletteQuery(""))
        #expect(model.palette?.selectedIndex(in: names) == selected)
        #expect(model.previewThemeName == names[selected])
        model.movePaletteSelection(by: 1, in: names)
        #expect(model.palette?.selectedIndex(in: names) == selected + 1)

        expectTrue(model.setPaletteQuery("dra"))
        #expect(model.palette?.selection == 0)
        #expect(model.palette?.selectedRowID == nil)
    }

    /// The theme list opens on the current theme, and the field's first write of its empty
    /// query does not move it to the first row.
    @Test func theThemeListOpensOnTheCurrentTheme() {
        let (model, _, _) = WindowModelTests().window { $0.theme = "Dracula" }
        let names = model.settings.availableThemes.map(\.name)
        model.perform(.commandPalette)
        expectTrue(model.setPaletteQuery("theme"))
        model.perform(.switchTheme)
        expectFalse(model.setPaletteQuery(""))
        #expect(model.palette.map { names[$0.selectedIndex(in: names)] } == "Dracula")
    }

    /// In the command list, ↑↓ move the selection and preview nothing.
    @Test func arrowsMoveThroughTheCommandsWithoutAPreview() {
        let (model, _, _) = WindowModelTests().window()
        model.perform(.commandPalette)
        let ids = model.registry.paletteCommands(in: model.context).map { "\($0.id)" }
        for step in [1, 1, -1] { model.movePaletteSelection(by: step, in: ids) }
        #expect(model.palette?.selectedIndex(in: ids) == 1)
        #expect(model.palette?.selectedRowID == ids[1])
        #expect(model.previewThemeName == nil)
        model.movePaletteSelection(by: -5, in: ids)
        #expect(model.palette?.selectedIndex(in: ids) == 0)
    }
}
