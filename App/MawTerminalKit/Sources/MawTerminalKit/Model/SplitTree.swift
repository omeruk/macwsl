import CoreGraphics
import Foundation

/// Identifies one pane. Stable for the pane's lifetime, across splits and moves in the tree.
public struct PaneID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

/// Identifies one split, and with it the divider between its two children.
public struct SplitID: Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// How a split arranges its two children.
public enum SplitAxis: Hashable, Sendable {
    /// Side by side, with a vertical divider. "Split right" creates this.
    case horizontal
    /// One above the other, with a horizontal divider. "Split down" creates this.
    case vertical
}

/// A direction for moving focus between panes.
public enum FocusDirection: Hashable, Sendable, CaseIterable {
    case left, right, up, down
}

/// The layout of the panes in one tab: a binary tree whose leaves are panes and whose inner
/// nodes split their area between two children.
///
/// The tree is a value type with no knowledge of sessions or views, so that every operation can
/// be tested on its own. It always contains at least one pane and always has a focused pane.
public struct SplitTree: Hashable, Sendable {
    public indirect enum Node: Hashable, Sendable {
        case pane(PaneID)
        /// `ratio` is the share of the area given to `first` (left or top), from
        /// `SplitTree.ratioRange`.
        case split(id: SplitID, axis: SplitAxis, ratio: Double, first: Node, second: Node)
    }

    /// The limits for a split's ratio, so that a dragged divider cannot hide a pane.
    public static let ratioRange: ClosedRange<Double> = 0.1...0.9

    public private(set) var root: Node
    public private(set) var focusedPane: PaneID

    public init(pane: PaneID) {
        root = .pane(pane)
        focusedPane = pane
    }

    /// The panes in reading order: depth first, left before right and top before bottom. A
    /// pane's position in this list, plus one, is its number in the pane title.
    public var panes: [PaneID] {
        root.panes
    }

    public var paneCount: Int {
        panes.count
    }

    public func contains(_ pane: PaneID) -> Bool {
        root.contains(pane)
    }

    /// The one-based number of `pane`, as shown in its title, or `nil` if it is not in the tree.
    public func number(of pane: PaneID) -> Int? {
        panes.firstIndex(of: pane).map { $0 + 1 }
    }

    // MARK: Editing

    /// Splits `pane` in two along `axis`. The existing pane keeps the first half (left or
    /// top), `newPane` takes the second, and focus moves to `newPane`.
    ///
    /// Returns `false`, and changes nothing, if `pane` is not in the tree or `newPane` already is.
    @discardableResult
    public mutating func split(_ pane: PaneID, axis: SplitAxis, newPane: PaneID) -> Bool {
        guard contains(pane), !contains(newPane) else { return false }
        root = root.replacing(pane) {
            .split(
                id: SplitID(), axis: axis, ratio: 0.5, first: .pane(pane), second: .pane(newPane))
        }
        focusedPane = newPane
        return true
    }

    /// Removes `pane`. Its sibling takes the place of their parent split.
    ///
    /// If `pane` was focused, focus moves to the pane in the sibling that was nearest to it:
    /// the sibling's first pane when the closed pane was on the left or top, and its last pane
    /// otherwise.
    ///
    /// Returns `false`, and changes nothing, if `pane` is the last pane or is not in the tree.
    /// Closing the last pane closes the tab, which is the caller's decision.
    @discardableResult
    public mutating func close(_ pane: PaneID) -> Bool {
        guard paneCount > 1, contains(pane) else { return false }
        var successor: PaneID?
        root = root.removing(pane, successor: &successor)
        if focusedPane == pane, let successor {
            focusedPane = successor
        }
        return true
    }

    /// Focuses `pane`. Returns `false` if it is not in the tree.
    @discardableResult
    public mutating func focus(_ pane: PaneID) -> Bool {
        guard contains(pane) else { return false }
        focusedPane = pane
        return true
    }

    /// Sets the ratio of one split, clamped to `ratioRange`. Returns `false` if there is no
    /// such split.
    @discardableResult
    public mutating func setRatio(_ ratio: Double, of split: SplitID) -> Bool {
        let clamped = min(max(ratio, Self.ratioRange.lowerBound), Self.ratioRange.upperBound)
        var found = false
        root = root.settingRatio(clamped, of: split, found: &found)
        return found
    }

    /// Gives every pane the same share of the space along each run of same-axis splits. Three
    /// panes side by side get a third of the width each, however they were split.
    public mutating func equalize() {
        root = root.equalized()
    }

    // MARK: Geometry

    /// A divider between the two children of a split, in the coordinates of a layout.
    public struct Divider: Hashable, Sendable {
        public var split: SplitID
        public var axis: SplitAxis
        /// The gap between the two children, where the divider can be grabbed.
        public var frame: CGRect
        /// The area of the whole split, which a drag position is measured against.
        public var splitFrame: CGRect
    }

    /// The frames of the panes and dividers when the tree fills `bounds`, with `gap` points
    /// between neighboring panes.
    public struct Layout: Hashable, Sendable {
        public var panes: [PaneID: CGRect]
        public var dividers: [Divider]
    }

    public func layout(in bounds: CGRect, gap: CGFloat = 0) -> Layout {
        var layout = Layout(panes: [:], dividers: [])
        root.layout(in: bounds, gap: gap, into: &layout)
        return layout
    }

    /// The ratio for `split` that puts its divider at `location`, in the coordinates of
    /// `divider.splitFrame`. Used while dragging a divider.
    public static func ratio(for location: CGPoint, dragging divider: Divider, gap: CGFloat)
        -> Double
    {
        let frame = divider.splitFrame
        switch divider.axis {
        case .horizontal:
            let usable = max(frame.width - gap, 1)
            return Double((location.x - frame.minX - gap / 2) / usable)
        case .vertical:
            let usable = max(frame.height - gap, 1)
            return Double((location.y - frame.minY - gap / 2) / usable)
        }
    }

    /// Moves focus to the nearest pane in `direction` from the focused one.
    ///
    /// A candidate must lie entirely beyond the focused pane's edge in that direction and
    /// overlap it on the other axis. Among candidates, the nearest edge wins, then the largest
    /// overlap, then reading order. Returns `false` if there is no pane in that direction.
    @discardableResult
    public mutating func moveFocus(_ direction: FocusDirection) -> Bool {
        let frames = layout(in: CGRect(x: 0, y: 0, width: 1, height: 1)).panes
        guard let current = frames[focusedPane] else { return false }
        let epsilon: CGFloat = 1e-9

        var best: (pane: PaneID, distance: CGFloat, overlap: CGFloat)?
        for pane in panes where pane != focusedPane {
            guard let frame = frames[pane] else { continue }
            let distance: CGFloat
            let overlap: CGFloat
            switch direction {
            case .left:
                guard frame.maxX <= current.minX + epsilon else { continue }
                distance = current.minX - frame.maxX
                overlap = min(frame.maxY, current.maxY) - max(frame.minY, current.minY)
            case .right:
                guard frame.minX >= current.maxX - epsilon else { continue }
                distance = frame.minX - current.maxX
                overlap = min(frame.maxY, current.maxY) - max(frame.minY, current.minY)
            case .up:
                guard frame.maxY <= current.minY + epsilon else { continue }
                distance = current.minY - frame.maxY
                overlap = min(frame.maxX, current.maxX) - max(frame.minX, current.minX)
            case .down:
                guard frame.minY >= current.maxY - epsilon else { continue }
                distance = frame.minY - current.maxY
                overlap = min(frame.maxX, current.maxX) - max(frame.minX, current.minX)
            }
            guard overlap > epsilon else { continue }
            if let best, distance > best.distance + epsilon { continue }
            if let existing = best, abs(distance - existing.distance) <= epsilon,
                overlap <= existing.overlap + epsilon
            {
                continue
            }
            best = (pane, distance, overlap)
        }
        guard let best else { return false }
        focusedPane = best.pane
        return true
    }
}

extension SplitTree.Node {
    var panes: [PaneID] {
        switch self {
        case .pane(let pane): [pane]
        case .split(_, _, _, let first, let second): first.panes + second.panes
        }
    }

    func contains(_ pane: PaneID) -> Bool {
        switch self {
        case .pane(let candidate): candidate == pane
        case .split(_, _, _, let first, let second): first.contains(pane) || second.contains(pane)
        }
    }

    func replacing(_ pane: PaneID, with makeNode: () -> Self) -> Self {
        switch self {
        case .pane(let candidate):
            return candidate == pane ? makeNode() : self
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(
                id: id, axis: axis, ratio: ratio,
                first: first.replacing(pane, with: makeNode),
                second: second.replacing(pane, with: makeNode))
        }
    }

    /// The node without `pane`. `successor` is set to the pane nearest to the removed one.
    func removing(_ pane: PaneID, successor: inout PaneID?) -> Self {
        guard case .split(let id, let axis, let ratio, let first, let second) = self else {
            return self
        }
        if case .pane(pane) = first {
            successor = second.panes.first
            return second
        }
        if case .pane(pane) = second {
            successor = first.panes.last
            return first
        }
        return .split(
            id: id, axis: axis, ratio: ratio,
            first: first.removing(pane, successor: &successor),
            second: second.removing(pane, successor: &successor))
    }

    func settingRatio(_ newRatio: Double, of split: SplitID, found: inout Bool) -> Self {
        guard case .split(let id, let axis, let ratio, let first, let second) = self else {
            return self
        }
        if id == split {
            found = true
            return .split(id: id, axis: axis, ratio: newRatio, first: first, second: second)
        }
        return .split(
            id: id, axis: axis, ratio: ratio,
            first: first.settingRatio(newRatio, of: split, found: &found),
            second: second.settingRatio(newRatio, of: split, found: &found))
    }

    /// The number of panes laid out along `axis` in this node: nested splits on the same axis
    /// add up, and anything else counts as one.
    func weight(along axis: SplitAxis) -> Int {
        guard case .split(_, let nodeAxis, _, let first, let second) = self, nodeAxis == axis
        else { return 1 }
        return first.weight(along: axis) + second.weight(along: axis)
    }

    func equalized() -> Self {
        guard case .split(let id, let axis, _, let first, let second) = self else { return self }
        let firstWeight = Double(first.weight(along: axis))
        let secondWeight = Double(second.weight(along: axis))
        return .split(
            id: id, axis: axis, ratio: firstWeight / (firstWeight + secondWeight),
            first: first.equalized(), second: second.equalized())
    }

    func layout(in bounds: CGRect, gap: CGFloat, into layout: inout SplitTree.Layout) {
        switch self {
        case .pane(let pane):
            layout.panes[pane] = bounds
        case .split(let id, let axis, let ratio, let first, let second):
            let firstFrame: CGRect
            let secondFrame: CGRect
            let dividerFrame: CGRect
            switch axis {
            case .horizontal:
                let usable = max(bounds.width - gap, 0)
                let firstWidth = usable * CGFloat(ratio)
                firstFrame = CGRect(
                    x: bounds.minX, y: bounds.minY, width: firstWidth, height: bounds.height)
                dividerFrame = CGRect(
                    x: firstFrame.maxX, y: bounds.minY, width: gap, height: bounds.height)
                secondFrame = CGRect(
                    x: dividerFrame.maxX, y: bounds.minY, width: usable - firstWidth,
                    height: bounds.height)
            case .vertical:
                let usable = max(bounds.height - gap, 0)
                let firstHeight = usable * CGFloat(ratio)
                firstFrame = CGRect(
                    x: bounds.minX, y: bounds.minY, width: bounds.width, height: firstHeight)
                dividerFrame = CGRect(
                    x: bounds.minX, y: firstFrame.maxY, width: bounds.width, height: gap)
                secondFrame = CGRect(
                    x: bounds.minX, y: dividerFrame.maxY, width: bounds.width,
                    height: usable - firstHeight)
            }
            layout.dividers.append(
                SplitTree.Divider(split: id, axis: axis, frame: dividerFrame, splitFrame: bounds))
            first.layout(in: firstFrame, gap: gap, into: &layout)
            second.layout(in: secondFrame, gap: gap, into: &layout)
        }
    }
}
