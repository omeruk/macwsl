import AppKit
import SwiftUI

/// The panes of a terminal tab, laid out from its split tree: boxes 10 pt from the window edges
/// and from each other, with the gaps between them acting as draggable dividers.
struct PaneGridView: View {
    let model: WindowModel
    let tree: SplitTree

    static let gap: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let layout = tree.layout(in: bounds, gap: Self.gap)
            ZStack(alignment: .topLeading) {
                ForEach(tree.panes, id: \.self) { paneID in
                    if let pane = model.panes[paneID], let frame = layout.panes[paneID] {
                        PaneBox(
                            pane: pane, number: tree.number(of: paneID) ?? 1,
                            isActive: tree.focusedPane == paneID
                        )
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    }
                }
                ForEach(layout.dividers, id: \.split) { divider in
                    DividerHandle(model: model, divider: divider)
                }
            }
            .coordinateSpace(name: PaneGridView.coordinateSpace)
        }
        .padding(EdgeInsets(top: Self.gap, leading: Self.gap, bottom: 0, trailing: Self.gap))
    }

    static let coordinateSpace = "panes"
}

/// One pane: a box with `<n> <name> <directory>` on its top border, around the terminal.
struct PaneBox: View {
    let pane: PaneController
    let number: Int
    let isActive: Bool
    @Environment(\.chrome) private var chrome

    var body: some View {
        Box(
            title: title, titleColor: isActive ? chrome.text : chrome.textSecondary,
            borderColor: isActive ? chrome.lineStrong : chrome.line
        ) {
            TerminalHostView(pane: pane)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane \(number), \(pane.displayName)")
    }

    private var title: String {
        var parts = ["\(number)", pane.displayName]
        if let directory = pane.workingDirectory {
            parts.append(abbreviatingHome(directory))
        }
        var title = parts.joined(separator: " ")
        if let termination = pane.termination {
            title += " · " + termination.description
        }
        return title
    }
}

/// The gap between two panes: drag to resize, double-click to equalize.
struct DividerHandle: View {
    let model: WindowModel
    let divider: SplitTree.Divider
    @State private var hovering = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: divider.frame.width, height: divider.frame.height)
            .offset(x: divider.frame.minX, y: divider.frame.minY)
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside {
                    (divider.axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown)
                        .push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(
                    minimumDistance: 1, coordinateSpace: .named(PaneGridView.coordinateSpace)
                )
                .onChanged { value in
                    let ratio = SplitTree.ratio(
                        for: value.location, dragging: divider, gap: PaneGridView.gap)
                    model.setRatio(ratio, of: divider.split)
                }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.equalize() })
            .accessibilityElement()
            .accessibilityLabel("Divider")
            .accessibilityHint("Drag to resize the panes. Double-click to make them equal.")
            .accessibilityAction(named: "Equalize panes") { model.equalize() }
    }
}

/// Places a pane's terminal view, which the pane controller owns, in the SwiftUI hierarchy.
/// SwiftUI may recreate the container; the terminal view moves into the new one unchanged.
struct TerminalHostView: NSViewRepresentable {
    let pane: PaneController

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.attach(pane.terminalView)
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        container.attach(pane.terminalView)
    }
}

final class TerminalContainerView: NSView {
    func attach(_ view: NSView) {
        guard view.superview !== self else { return }
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    override func layout() {
        super.layout()
        for subview in subviews {
            subview.frame = bounds
        }
    }
}
