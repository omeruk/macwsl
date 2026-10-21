import AppKit
import Observation
import os

/// The application: windows, the menu bar, keyboard shortcuts, and quitting.
///
/// The app target's `main` creates one controller and runs it. maw uses the AppKit application
/// life cycle rather than SwiftUI's `App`, because the menu bar is built from the command
/// registry and the windows need AppKit's title bar configuration; SwiftUI draws the content.
@MainActor
public final class AppController: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let settingsStore: SettingsStore
    let distributions: any DistributionProvider
    private var windows: [TerminalWindowController] = []
    private var keyMonitor: Any?
    private var lastMenuRegistry: CommandRegistry?

    /// - Parameter fontsDirectory: The bundled fonts, registered at launch.
    public init(fontsDirectory: URL?) {
        if let fontsDirectory {
            MawFonts.registerFonts(in: fontsDirectory)
        }
        settingsStore = SettingsStore()
        distributions = NoDistributions()
        super.init()
    }

    /// Runs the application. Does not return.
    public static func run(fontsDirectory: URL?) -> Never {
        let application = NSApplication.shared
        let controller = AppController(fontsDirectory: fontsDirectory)
        application.delegate = controller
        application.setActivationPolicy(.regular)
        application.run()
        exit(0)
    }

    // MARK: NSApplicationDelegate

    public func applicationDidFinishLaunching(_ notification: Notification) {
        settingsStore.load()
        settingsStore.startWatching()
        rebuildMenus()
        observeSettings()
        installKeyMonitor()
        openWindow()
        NSApp.activate()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool)
        -> Bool
    {
        if !hasVisibleWindows {
            openWindow()
        }
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply
    {
        let running = windows.flatMap(\.model.runningProcessNames)
        guard settingsStore.settings.confirmQuitWithRunningProcess, !running.isEmpty else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Quit maw?"
        alert.informativeText =
            "\(WindowModel.list(running)) \(running.count == 1 ? "is" : "are") still running "
            + "and will be ended."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    public func applicationWillTerminate(_ notification: Notification) {
        settingsStore.stopWatching()
        for window in windows {
            window.model.shutDown()
        }
    }

    // MARK: Windows

    func openWindow() {
        let controller = TerminalWindowController(
            settingsStore: settingsStore, distributions: distributions)
        controller.onClose = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
        }
        controller.onNewWindow = { [weak self] in self?.openWindow() }
        windows.append(controller)
        if let current = NSApp.keyWindow, current !== controller.window {
            controller.window?.cascadeTopLeft(from: current.frame.origin)
        }
        controller.showWindow(nil)
    }

    private var keyWindowController: TerminalWindowController? {
        windows.first { $0.window?.isKeyWindow == true }
            ?? windows.first { $0.window?.isMainWindow == true }
    }

    private var currentRegistry: CommandRegistry {
        let settings = settingsStore.settings
        return CommandRegistry(
            profiles: [settings.localShellProfile], defaultProfile: settings.defaultProfile)
    }

    // MARK: Settings

    /// Applies settings changes to every window, and rebuilds the menus when the commands
    /// change, for example when the default profile does.
    private func observeSettings() {
        withObservationTracking {
            _ = settingsStore.settings
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                for window in self.windows {
                    window.model.applyAppearance()
                }
                if self.currentRegistry != self.lastMenuRegistry {
                    self.rebuildMenus()
                }
                self.observeSettings()
            }
        }
    }

    // MARK: Menus

    private func rebuildMenus() {
        let registry = currentRegistry
        lastMenuRegistry = registry
        NSApp.mainMenu = MenuBuilder(registry: registry, target: self).build()
    }

    /// Menu items send their command here. Window commands go to the key window; with no
    /// window, commands that create one open a new window first.
    @objc func performMenuCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CommandBox else { return }
        perform(box.id)
    }

    private func perform(_ id: CommandID) {
        if let controller = keyWindowController {
            controller.model.perform(id)
            return
        }
        switch id {
        case .newWindow, .newTab:
            openWindow()
        case .openSettings, .openDistributions:
            openWindow()
            windows.last?.model.perform(id)
        default:
            break
        }
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let box = menuItem.representedObject as? CommandBox else { return true }
        if let controller = keyWindowController {
            return controller.model.isEnabled(box.id)
        }
        return currentRegistry.isEnabled(box.id, in: .noWindow)
    }

    // MARK: Keyboard shortcuts

    /// Handles every registry shortcut that uses the Command key before the focused view sees
    /// it, so that the terminal never swallows ⌘D or ⌘T and shortcuts typed with Shift on any
    /// layout, such as ⌘+ or ⌘⇧], are recognized. Menu items show the same shortcuts.
    /// Responder-chain commands (copy, paste, select all) are left to the menu, so that they
    /// reach text fields too.
    private func installKeyMonitor() {
        // Local monitors run on the main thread.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleShortcut(event) ?? false }
            return handled ? nil : event
        }
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard let stroke = KeyStroke(event: event), stroke.modifiers.contains(.command),
            NSApp.modalWindow == nil
        else { return false }
        // The shortcut belongs to the window the key event is for. Events for other windows,
        // such as an alert, are left alone, as are windows showing a sheet.
        let controller = windows.first { $0.window === event.window }
        if let window = event.window, controller == nil || window.attachedSheet != nil {
            return false
        }
        let registry = currentRegistry
        guard
            let command = registry.commands.first(where: { definition in
                definition.kind == .action && definition.shortcut.map(stroke.matches) == true
            })
        else { return false }
        if let controller {
            controller.model.perform(command.id)
        } else {
            perform(command.id)
        }
        return true
    }
}
