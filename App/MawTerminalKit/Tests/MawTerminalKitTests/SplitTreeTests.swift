import CoreGraphics
import MawTerminalKit
import Testing

@Suite struct SplitTreeTests {
    let a = PaneID()
    let b = PaneID()
    let c = PaneID()
    let d = PaneID()

    @Test func startsWithOneFocusedPane() {
        let tree = SplitTree(pane: a)
        #expect(tree.panes == [a])
        #expect(tree.focusedPane == a)
        #expect(tree.number(of: a) == 1)
    }

    @Test func splitPutsTheNewPaneSecondAndFocusesIt() {
        var tree = SplitTree(pane: a)
        expectTrue(tree.split(a, axis: .horizontal, newPane: b))
        #expect(tree.panes == [a, b])
        #expect(tree.focusedPane == b)
        #expect(tree.number(of: b) == 2)
    }

    @Test func splitRejectsUnknownAndDuplicatePanes() {
        var tree = SplitTree(pane: a)
        expectFalse(tree.split(b, axis: .horizontal, newPane: c))
        expectFalse(tree.split(a, axis: .horizontal, newPane: a))
        #expect(tree.panes == [a])
    }

    @Test func nestedSplitsKeepReadingOrder() {
        var tree = SplitTree(pane: a)
        tree.split(a, axis: .horizontal, newPane: b)
        tree.split(a, axis: .vertical, newPane: c)
        // a | b, with a split into a over c.
        #expect(tree.panes == [a, c, b])
    }

    @Test func closingTheLastPaneIsRefused() {
        var tree = SplitTree(pane: a)
        expectFalse(tree.close(a))
        #expect(tree.panes == [a])
    }

    @Test func closingAFirstChildFocusesTheSiblingsFirstPane() {
        var tree = SplitTree(pane: a)
        tree.split(a, axis: .horizontal, newPane: b)
        tree.split(b, axis: .vertical, newPane: c)
        tree.focus(a)
        expectTrue(tree.close(a))
        #expect(tree.panes == [b, c])
        #expect(tree.focusedPane == b)
    }

    @Test func closingASecondChildFocusesTheSiblingsLastPane() {
        var tree = SplitTree(pane: a)
        tree.split(a, axis: .horizontal, newPane: b)
        tree.split(a, axis: .vertical, newPane: c)
        // (a over c) | b. Closing b focuses c, the pane nearest to b.
        tree.focus(b)
        expectTrue(tree.close(b))
        #expect(tree.panes == [a, c])
        #expect(tree.focusedPane == c)
    }

    @Test func closingAnUnfocusedPaneKeepsFocus() {
        var tree = SplitTree(pane: a)
        tree.split(a, axis: .horizontal, newPane: b)
        tree.split(b, axis: .horizontal, newPane: c)
        tree.focus(a)
        tree.close(c)
        #expect(tree.focusedPane == a)
        #expect(tree.panes == [a, b])
    }

    @Test func layoutDividesTheAreaAndLeavesGaps() {
        var tree = SplitTree(pane: a)
        tree.split(a, axis: .horizontal, newPane: b)
        let layout = tree.layout(in: CGRect(x: 0, y: 0, width: 210, height: 100), gap: 10)
        #expect(layout.panes[a] == CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(layout.panes[b] == CGRect(x: 110, y: 0, width: 100, height: 100))
        #expect(layout.dividers.count == 1)
        #expect(layout.dividers[0].frame == CGRect(x: 100, y: 0, width: 10, height: 100))
    }

    @Test func verticalSplitsStackTopToBottom() {
        var tree = SplitTree(pane: a)
        tree.split(a, axis: .vertical, newPane: b)
        let layout = tree.layout(in: CGRect(x: 0, y: 0, width: 100, height: 200))
        #expect(layout.panes[a] == CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(layout.panes[b] == CGRect(x: 0, y: 100, width: 100, height: 100))
    }

    @Test func ratiosAreClamped() throws {
        var tree = SplitTree(pane: a)
        tree.split(a, axis: .horizontal, newPane: b)
        let divider = try #require(
            tree.layout(in: CGRect(x: 0, y: 0, width: 100, height: 100)).dividers.first)
        expectTrue(tree.setRatio(0.01, of: divider.split))
        let frames = tree.layout(in: CGRect(x: 0, y: 0, width: 100, height: 100)).panes
        #expect(frames[a]?.width == 10)
        expectFalse(tree.setRatio(0.5, of: SplitID()))
    }

    @Test func dragPositionBecomesARatio() throws {
        var tree = SplitTree(pane: a)
        tree.split(a, axis: .horizontal, newPane: b)
        let divider = try #require(
            tree.layout(in: CGRect(x: 0, y: 0, width: 210, height: 100), gap: 10).dividers.first)
        let ratio = SplitTree.ratio(for: CGPoint(x: 55, y: 50), dragging: divider, gap: 10)
        #expect(abs(ratio - 0.25) < 1e-9)
    }

    @Test func equalizeGivesEachPaneTheSameShareAlongAnAxis() {
        var tree = SplitTree(pane: a)
        tree.split(a, axis: .horizontal, newPane: b)
        tree.split(b, axis: .horizontal, newPane: c)
        // a | (b | c): without equalizing, a has half and b and c a quarter each.
        let before = tree.layout(in: CGRect(x: 0, y: 0, width: 300, height: 100)).panes
        #expect(before[a]?.width == 150)
        tree.equalize()
        let after = tree.layout(in: CGRect(x: 0, y: 0, width: 300, height: 100)).panes
        for pane in [a, b, c] {
            #expect(abs((after[pane]?.width ?? 0) - 100) < 1e-9)
        }
    }

    @Test func equalizeTreatsAPerpendicularSplitAsOnePane() {
        var tree = SplitTree(pane: a)
        tree.split(a, axis: .horizontal, newPane: b)
        tree.split(b, axis: .vertical, newPane: c)
        tree.equalize()
        let frames = tree.layout(in: CGRect(x: 0, y: 0, width: 200, height: 200)).panes
        #expect(frames[a]?.width == 100)
        #expect(frames[b]?.height == 100)
        #expect(frames[c]?.height == 100)
    }

    /// a | b on top, c across the bottom: (a | b) over c.
    func grid() -> SplitTree {
        var tree = SplitTree(pane: a)
        tree.split(a, axis: .vertical, newPane: c)
        tree.split(a, axis: .horizontal, newPane: b)
        return tree
    }

    @Test func focusMovesToTheNeighborInEachDirection() {
        var tree = grid()
        tree.focus(a)
        expectTrue(tree.moveFocus(.right))
        #expect(tree.focusedPane == b)
        expectTrue(tree.moveFocus(.down))
        #expect(tree.focusedPane == c)
        expectTrue(tree.moveFocus(.up))
        // From c, both a and b are above; a comes first in reading order.
        #expect(tree.focusedPane == a)
        expectTrue(tree.moveFocus(.right))
        expectTrue(tree.moveFocus(.left))
        #expect(tree.focusedPane == a)
    }

    @Test func focusDoesNotMovePastTheEdge() {
        var tree = grid()
        tree.focus(a)
        expectFalse(tree.moveFocus(.left))
        expectFalse(tree.moveFocus(.up))
        #expect(tree.focusedPane == a)
    }

    @Test func focusPrefersTheLargestOverlap() throws {
        // a on the left; on the right, b over c with b taking 70%.
        var tree = SplitTree(pane: a)
        tree.split(a, axis: .horizontal, newPane: b)
        tree.split(b, axis: .vertical, newPane: c)
        let layout = tree.layout(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let vertical = try #require(layout.dividers.first { $0.axis == .vertical })
        tree.setRatio(0.7, of: vertical.split)
        tree.focus(a)
        expectTrue(tree.moveFocus(.right))
        #expect(tree.focusedPane == b)
        tree.focus(c)
        expectTrue(tree.moveFocus(.left))
        #expect(tree.focusedPane == a)
    }
}
