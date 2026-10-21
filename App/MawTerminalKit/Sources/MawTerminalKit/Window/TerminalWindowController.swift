import AppKit
import SwiftUI

/// One terminal window. AppKit owns the window and its title bar; SwiftUI draws everything
/// inside it, including the tab strip in the title bar area.
///
/// The window has an empty toolbar with the unified compact style, so that AppKit sizes the
/// title bar and centers the traffic lights without the app moving them. The content view
/// extends under the title bar (`fullSizeContentView`), and the SwiftUI tab strip is drawn in
/// that area, starting after the traffic lights.
@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    let model: WindowModel
    /// Called when the window has closed, so that the app can release it.
    var onClose: ((TerminalWindowController) -> Void)?
    var onNewWindow: (() -> Void)?

    init(settingsStore: SettingsStore, distributions: any DistributionProvider) {
        model = WindowModel(settingsStore: settingsStore, distributions: distributions)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.minSize = NSSize(width: 480, height: 280)
        let toolbar = NSToolbar(identifier: "maw.window")
        toolbar.showsBaselineSeparator = false
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        super.init(window: window)

        model.host = self
        window.delegate = self
        window.contentView = NSHostingView(rootView: WindowRootView(model: model))
        window.setFrameAutosaveName("maw.terminal")
        updateTitleBarMetrics()
        applyWindowOpacity()
        model.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Reads the title bar's height and the traffic lights' extent from AppKit.
    func updateTitleBarMetrics() {
        guard let window else { return }
        let height = window.frame.height - window.contentLayoutRect.height
        if height > 0 {
            model.titleBarHeight = height
        }
        if window.styleMask.contains(.fullScreen) {
            model.trafficLightsWidth = 0
        } else if let zoom = window.standardWindowButton(.zoomButton) {
            model.trafficLightsWidth = zoom.frame.maxX + 12
        }
    }

    func applyWindowOpacity() {
        guard let window else { return }
        let translucent = model.settings.backgroundOpacity < 1
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : model.chrome.background.nsColor
    }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        updateTitleBarMetrics()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        updateTitleBarMetrics()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        updateTitleBarMetrics()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let running = model.runningProcessNames
        guard model.settings.confirmCloseWithRunningProcess, !running.isEmpty else { return true }
        Task {
            let confirmed = await confirm(
                Confirmation(
                    message: "Close this window?",
                    detail: "\(WindowModel.list(running)) \(running.count == 1 ? "is" : "are") "
                        + "still running and will be ended.",
                    confirmTitle: "Close"))
            if confirmed {
                closeWindow()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        model.shutDown()
        onClose?(self)
    }

    // MARK: Commands from the menu bar

    @objc func performMenuCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CommandBox else { return }
        model.perform(box.id)
    }
}

extension TerminalWindowController: WindowHost {
    func confirm(_ confirmation: Confirmation) async -> Bool {
        guard let window else { return true }
        let alert = NSAlert()
        alert.messageText = confirmation.message
        alert.informativeText = confirmation.detail
        alert.addButton(withTitle: confirmation.confirmTitle)
        alert.addButton(withTitle: "Cancel")
        if window.attachedSheet != nil {
            return alert.runModal() == .alertFirstButtonReturn
        }
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
        return response == .alertFirstButtonReturn
    }

    func closeWindow() {
        window?.delegate = nil
        model.shutDown()
        window?.close()
        onClose?(self)
    }

    func focusTerminal(_ view: NSView) {
        guard let window, view.window === window, window.firstResponder !== view else { return }
        window.makeFirstResponder(view)
    }

    func openNewWindow() {
        onNewWindow?()
    }

    func setWindowTitle(_ title: String) {
        if window?.title != title {
            window?.title = title
        }
    }
}

/// Wraps a command identifier for `NSMenuItem.representedObject`.
final class CommandBox: NSObject {
    let id: CommandID

    init(_ id: CommandID) {
        self.id = id
    }
}
