import MawTerminalKit
import Testing

@Suite struct TabListTests {
    func terminal() -> Tab {
        Tab(content: .terminal(SplitTree(pane: PaneID())))
    }

    @Test func appendSelectsTheNewTab() {
        var list = TabList()
        let first = terminal()
        let second = terminal()
        list.append(first)
        list.append(second)
        #expect(list.selectedID == second.id)
        #expect(list.previousID == first.id)
        #expect(list.tabs.map(\.id) == [first.id, second.id])
    }

    @Test func selectsByPosition() {
        var list = TabList()
        let tabs = [terminal(), terminal(), terminal()]
        for tab in tabs { list.append(tab) }
        expectTrue(list.select(position: 1))
        #expect(list.selectedID == tabs[0].id)
        expectFalse(list.select(position: 4))
        expectFalse(list.select(position: 0))
        #expect(list.selectedID == tabs[0].id)
    }

    @Test func adjacentSelectionWraps() {
        var list = TabList()
        let tabs = [terminal(), terminal(), terminal()]
        for tab in tabs { list.append(tab) }
        list.selectAdjacent(forward: true)
        #expect(list.selectedID == tabs[0].id)
        list.selectAdjacent(forward: false)
        #expect(list.selectedID == tabs[2].id)
        list.selectAdjacent(forward: false)
        #expect(list.selectedID == tabs[1].id)
    }

    @Test func screensOpenOncePerWindow() {
        var list = TabList()
        list.append(terminal())
        let first = list.openScreen(.settings)
        list.select(position: 1)
        let second = list.openScreen(.settings)
        #expect(first == second)
        #expect(list.count == 2)
        #expect(list.selectedID == first)
        let distributions = list.openScreen(.distributions)
        #expect(distributions != first)
        #expect(list.count == 3)
    }

    @Test func screenTabsShowNoNumberButKeepTheirPosition() {
        var list = TabList()
        let shell = terminal()
        list.append(shell)
        let settings = list.openScreen(.settings)
        let other = terminal()
        list.append(other)
        #expect(list.labelNumber(of: shell.id) == 1)
        #expect(list.labelNumber(of: settings) == nil)
        #expect(list.labelNumber(of: other.id) == 3)
        // ⌘2 still selects the settings tab.
        list.select(position: 2)
        #expect(list.selectedID == settings)
    }

    @Test func returnToPreviousGoesBackWithoutClosing() {
        var list = TabList()
        let first = terminal()
        let second = terminal()
        list.append(first)
        list.append(second)
        list.select(first.id)
        let settings = list.openScreen(.settings)
        expectTrue(list.returnToPrevious())
        #expect(list.selectedID == first.id)
        #expect(list[settings] != nil)
    }

    @Test func returnToPreviousFallsBackToTheNearestTerminal() {
        var list = TabList()
        let first = terminal()
        let second = terminal()
        list.append(first)
        list.append(second)
        let distributions = list.openScreen(.distributions)
        list.remove(second.id)
        list.select(distributions)
        // The previous tab, `second`, is gone.
        expectTrue(list.returnToPrevious())
        #expect(list.selectedID == first.id)
    }

    @Test func returnToPreviousWithNoOtherTabFails() {
        var list = TabList()
        let settings = list.openScreen(.settings)
        expectFalse(list.returnToPrevious())
        #expect(list.selectedID == settings)
    }

    @Test func removingTheSelectedTabSelectsThePreviousOne() {
        var list = TabList()
        let tabs = [terminal(), terminal(), terminal()]
        for tab in tabs { list.append(tab) }
        list.select(tabs[0].id)
        list.select(tabs[1].id)
        list.remove(tabs[1].id)
        #expect(list.selectedID == tabs[0].id)
    }

    @Test func removingTheSelectedTabWithoutHistorySelectsItsNeighbor() {
        var list = TabList()
        let tabs = [terminal(), terminal(), terminal()]
        for tab in tabs { list.append(tab) }
        list.remove(tabs[1].id)
        // tabs[2] was selected and its predecessor is tabs[1], now removed. Remove tabs[2].
        list.remove(tabs[2].id)
        #expect(list.selectedID == tabs[0].id)
        list.remove(tabs[0].id)
        #expect(list.isEmpty)
        #expect(list.selectedID == nil)
    }

    @Test func moveReordersWithoutChangingSelection() {
        var list = TabList()
        let tabs = [terminal(), terminal(), terminal()]
        for tab in tabs { list.append(tab) }
        list.move(tabs[2].id, to: 0)
        #expect(list.tabs.map(\.id) == [tabs[2].id, tabs[0].id, tabs[1].id])
        #expect(list.selectedID == tabs[2].id)
        list.move(tabs[2].id, to: 99)
        #expect(list.tabs.map(\.id) == [tabs[0].id, tabs[1].id, tabs[2].id])
    }

    @Test func updateReplacesATabsLayout() throws {
        var list = TabList()
        let tab = terminal()
        list.append(tab)
        var tree = try #require(tab.splitTree)
        tree.split(tree.focusedPane, axis: .horizontal, newPane: PaneID())
        list.update(tab.id, content: .terminal(tree))
        #expect(list[tab.id]?.splitTree?.paneCount == 2)
    }
}
