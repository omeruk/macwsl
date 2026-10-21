import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The title bar: text tabs, a plain `+`, and `maw` at the right end, as in `Main.dc.html`.
struct TitleBarView: View {
    let model: WindowModel
    @Environment(\.chrome) private var chrome
    @State private var draggedTab: TabID?

    var body: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: max(model.trafficLightsWidth - 14, 0), height: 1)
            ForEach(model.tabs.tabs) { tab in
                TabButton(model: model, tab: tab)
                    .onDrag {
                        draggedTab = tab.id
                        return NSItemProvider(object: tab.id.rawValue.uuidString as NSString)
                    }
                    .onDrop(
                        of: [.text],
                        delegate: TabDropDelegate(
                            model: model, target: tab.id, dragged: $draggedTab))
            }
            Button {
                model.perform(.newTab(profile: model.defaultProfile.id))
            } label: {
                Text("+").chromeStyle(chrome.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New tab (⌘T)")
            .accessibilityLabel("New tab")
            Spacer(minLength: 8)
            Text("maw").chromeStyle(chrome.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .frame(height: model.titleBarHeight)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                chrome.titlebarBackground.color
                WindowDragArea()
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(chrome.line.color).frame(height: 1)
        }
    }
}

/// One tab: `<n> <name>  <directory>`, reverse video when selected. Screen tabs show no number.
struct TabButton: View {
    let model: WindowModel
    let tab: Tab
    @Environment(\.chrome) private var chrome

    var body: some View {
        let selected = model.tabs.selectedID == tab.id
        let number = model.tabs.labelNumber(of: tab.id)
        let (name, directory) = label
        Button {
            model.select(tab.id)
        } label: {
            HStack(spacing: 0) {
                if let number {
                    Text("\(number) ")
                        .chromeStyle(selected ? chrome.textSelectedSecondary : chrome.textTabNumber)
                }
                Text(name).chromeStyle(selected ? chrome.textSelected : chrome.textTab)
                if let directory {
                    Text("  " + directory)
                        .chromeStyle(selected ? chrome.textSelected : chrome.textTab)
                }
            }
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(selected ? chrome.text.color : .clear, ignoresSafeAreaEdges: [])
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay { MiddleClickArea { model.closeTab(tab.id) } }
        .contextMenu {
            Button("Close Tab") { model.closeTab(tab.id) }
        }
        .accessibilityLabel(accessibilityLabel(number: number, name: name, directory: directory))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private var label: (String, String?) {
        switch tab.content {
        case .screen(let kind):
            return (kind.title, nil)
        case .terminal(let tree):
            guard let pane = model.panes[tree.focusedPane] else { return ("", nil) }
            return (
                pane.displayName, pane.workingDirectory.map { Self.shortened(abbreviatingHome($0)) }
            )
        }
    }

    /// Long directories keep their last components, so that tabs stay narrow: `…/Sources/App`.
    static func shortened(_ path: String, limit: Int = 28) -> String {
        guard path.count > limit else { return path }
        var components = path.split(separator: "/", omittingEmptySubsequences: false)
        while components.count > 1, components.joined(separator: "/").count + 2 > limit {
            components.removeFirst()
        }
        let tail = components.joined(separator: "/")
        return tail.count + 2 > limit ? "…" + tail.suffix(limit - 1) : "…/" + tail
    }

    private func accessibilityLabel(number: Int?, name: String, directory: String?) -> String {
        [number.map { "Tab \($0)" }, name, directory].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Reorders tabs while one is dragged over another.
struct TabDropDelegate: DropDelegate {
    let model: WindowModel
    let target: TabID
    @Binding var dragged: TabID?

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target, let index = model.tabs.index(of: target) else {
            return
        }
        withAnimation(.easeOut(duration: 0.12)) {
            model.moveTab(dragged, to: index)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}

/// Lets the empty parts of the title bar move the window, and a double-click zoom or minimize
/// it as the system setting for double-clicking a title bar says.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
                switch action {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
                return
            }
            window.performDrag(with: event)
        }
    }
}

/// Receives middle clicks only. Every other event passes through to the view below.
struct MiddleClickArea: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.action = action
        return view
    }

    func updateNSView(_ view: ClickView, context: Context) {
        view.action = action
    }

    final class ClickView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .otherMouseDown ? super.hitTest(point) : nil
        }

        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber == 2 {
                action?()
            }
        }
    }
}
