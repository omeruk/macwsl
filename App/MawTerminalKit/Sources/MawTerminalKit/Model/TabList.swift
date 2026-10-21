import Foundation

/// Identifies one tab in a window.
public struct TabID: Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// A screen that opens as a tab of its own, at most once per window.
public enum ScreenKind: Hashable, Sendable, CaseIterable {
    case distributions
    case settings

    /// The tab label, as in `Distributions.dc.html`. Screen tabs show no number.
    public var title: String {
        switch self {
        case .distributions: "distributions"
        case .settings: "settings"
        }
    }
}

/// What a tab shows.
public enum TabContent: Hashable, Sendable {
    case terminal(SplitTree)
    case screen(ScreenKind)
}

public struct Tab: Hashable, Sendable, Identifiable {
    public let id: TabID
    public var content: TabContent

    public init(id: TabID = TabID(), content: TabContent) {
        self.id = id
        self.content = content
    }

    public var splitTree: SplitTree? {
        guard case .terminal(let tree) = content else { return nil }
        return tree
    }

    public var screen: ScreenKind? {
        guard case .screen(let kind) = content else { return nil }
        return kind
    }
}

/// The tabs of one window, in order, and which one is selected.
///
/// Every tab, screens included, takes a position for ⌘1 to ⌘9. The list remembers the tab that
/// was selected before the current one, so that esc on a screen returns to it.
public struct TabList: Hashable, Sendable {
    public private(set) var tabs: [Tab] = []
    public private(set) var selectedID: TabID?
    /// The tab selected before `selectedID`, if it still exists.
    public private(set) var previousID: TabID?

    public init() {}

    public var isEmpty: Bool { tabs.isEmpty }
    public var count: Int { tabs.count }

    public var selectedIndex: Int? {
        selectedID.flatMap(index(of:))
    }

    public var selectedTab: Tab? {
        selectedIndex.map { tabs[$0] }
    }

    public func index(of id: TabID) -> Int? {
        tabs.firstIndex { $0.id == id }
    }

    public subscript(id: TabID) -> Tab? {
        index(of: id).map { tabs[$0] }
    }

    /// Adds `tab` after the last tab and selects it.
    public mutating func append(_ tab: Tab) {
        tabs.append(tab)
        select(tab.id)
    }

    /// Selects the tab with `id`. Returns `false` if there is none.
    @discardableResult
    public mutating func select(_ id: TabID) -> Bool {
        guard index(of: id) != nil else { return false }
        if selectedID != id {
            previousID = selectedID
            selectedID = id
        }
        return true
    }

    /// Selects the tab at the one-based `position`, as ⌘1 to ⌘9 do. Returns `false` if there is
    /// no tab there.
    @discardableResult
    public mutating func select(position: Int) -> Bool {
        guard tabs.indices.contains(position - 1) else { return false }
        return select(tabs[position - 1].id)
    }

    /// Selects the next tab, or the previous one with `forward` false, wrapping around.
    public mutating func selectAdjacent(forward: Bool) {
        guard let index = selectedIndex, tabs.count > 1 else { return }
        let next = (index + (forward ? 1 : -1) + tabs.count) % tabs.count
        select(tabs[next].id)
    }

    /// Selects the screen tab of `kind`, adding one after the last tab if the window has none.
    /// Returns its identifier.
    @discardableResult
    public mutating func openScreen(_ kind: ScreenKind) -> TabID {
        if let existing = tabs.first(where: { $0.screen == kind }) {
            select(existing.id)
            return existing.id
        }
        let tab = Tab(content: .screen(kind))
        append(tab)
        return tab.id
    }

    /// Returns from a screen to the tab selected before it, without closing the screen. If that
    /// tab is gone, selects the nearest terminal tab instead. Returns `false` if there is no
    /// other tab to go to.
    @discardableResult
    public mutating func returnToPrevious() -> Bool {
        if let previousID, previousID != selectedID, index(of: previousID) != nil {
            return select(previousID)
        }
        guard let index = selectedIndex else { return false }
        let others = tabs.indices.filter { $0 != index }
        let terminals = others.filter { tabs[$0].splitTree != nil }
        let candidates = terminals.isEmpty ? others : terminals
        guard let nearest = candidates.min(by: { abs($0 - index) < abs($1 - index) }) else {
            return false
        }
        return select(tabs[nearest].id)
    }

    /// Replaces the content of the tab with `id`.
    public mutating func update(_ id: TabID, content: TabContent) {
        guard let index = index(of: id) else { return }
        tabs[index].content = content
    }

    /// Removes the tab with `id`. If it was selected, the previously selected tab is selected
    /// when it still exists, otherwise the tab that took its place, or the new last tab.
    /// Returns the removed tab.
    @discardableResult
    public mutating func remove(_ id: TabID) -> Tab? {
        guard let index = index(of: id) else { return nil }
        let removed = tabs.remove(at: index)
        if previousID == id {
            previousID = nil
        }
        if selectedID == id {
            selectedID = nil
            if let previousID, self.index(of: previousID) != nil {
                selectedID = previousID
            } else if !tabs.isEmpty {
                selectedID = tabs[min(index, tabs.count - 1)].id
            }
            previousID = nil
        }
        return removed
    }

    /// Moves the tab with `id` to `destination`, an index in the list after the move. Used for
    /// reordering by dragging. Selection is unchanged.
    public mutating func move(_ id: TabID, to destination: Int) {
        guard let index = index(of: id) else { return }
        let tab = tabs.remove(at: index)
        tabs.insert(tab, at: min(max(destination, 0), tabs.count))
    }

    /// The number shown in the label of the tab with `id`: its one-based position, or `nil` for
    /// screen tabs, which show none but still count for ⌘1 to ⌘9.
    public func labelNumber(of id: TabID) -> Int? {
        guard let index = index(of: id), tabs[index].screen == nil else { return nil }
        return index + 1
    }
}
