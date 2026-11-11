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
