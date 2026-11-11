import AppKit
import Observation
import os

/// The application: windows, the menu bar, keyboard shortcuts, and quitting.
///
/// The app target's `main` creates one controller and runs it. maw uses the AppKit application
/// life cycle rather than SwiftUI's `App`, because the menu bar is built from the command
/// registry and the windows need AppKit's title bar configuration; SwiftUI draws the content.
@MainActor
public final class AppController: NSObject, NSApplicationDelegate, NSMenuItemValidation,
    NSMenuDelegate
{
    let settingsStore: SettingsStore
    let distributions: any DistributionProvider
    private var windows: [TerminalWindowController] = []
    private var keyMonitor: Any?
    private var lastMenuRegistry: CommandRegistry?
    /// Set while a quit waits for the sessions' answers or for the user.
    private var isAskingToQuit = false

    /// - Parameter fontsDirectory: The bundled fonts, registered at launch.
    public convenience init(fontsDirectory: URL?) {
        if let fontsDirectory {
            MawFonts.registerFonts(in: fontsDirectory)
        }
        self.init(settingsStore: SettingsStore(), distributions: DaemonDistributions())
    }

    /// One provider for every window, so that the profiles and the screens share the list.
    init(settingsStore: SettingsStore, distributions: any DistributionProvider) {
        self.settingsStore = settingsStore
        self.distributions = distributions
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
        observeDistributions()
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

    /// Asks every session of every window at once what runs in it, without blocking the main
    /// thread, and replies once they have answered or the user has, if a program runs. A
    /// second quit while the question is open is cancelled.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply
    {
        let panes = windows.flatMap(\.model.panes.values)
        guard settingsStore.settings.confirmQuitWithRunningProcess, !panes.isEmpty else {
            return .terminateNow
        }
        guard !isAskingToQuit else { return .terminateCancel }
        isAskingToQuit = true
        Task {
            let quit = await WindowModel.confirmQuitting(
                { windows.flatMap(\.model.panes.values) },
                ask: { question in
                    let alert = NSAlert()
                    alert.messageText = question.message
                    alert.informativeText = question.detail
                    alert.addButton(withTitle: question.confirmTitle)
                    alert.addButton(withTitle: "Cancel")
                    return alert.runModal() == .alertFirstButtonReturn
                })
            isAskingToQuit = false
            NSApp.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }

    /// Ends every session, which hangs up every Linux session and ends its lease.
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

    var currentRegistry: CommandRegistry {
        let settings = settingsStore.settings
        return CommandRegistry(
            profiles: settings.profiles(distributions: distributions.distributions.map(\.name)),
            newTabProfile: settings.newTabProfile)
    }

    // MARK: Settings

    /// Applies settings changes to every window, and updates the menus' new-tab items, which
    /// follow the default profile.
    private func observeSettings() {
        withObservationTracking {
            _ = settingsStore.settings
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                for window in self.windows {
                    window.model.applyAppearance()
                }
                self.updateNewTabItems()
                self.observeSettings()
            }
        }
    }

    /// Updates the menus' new-tab items when the daemon's list changes. The appearance does not
    /// depend on it.
    private func observeDistributions() {
        withObservationTracking {
            _ = distributions.distributions
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateNewTabItems()
                self.observeDistributions()
            }
        }
    }

    // MARK: Menus

    /// The menu that lists the new-tab items.
    private(set) var newTabMenu: NSMenu?

    private func rebuildMenus() {
        let registry = currentRegistry
        lastMenuRegistry = registry
        let bar = MenuBuilder(registry: registry, target: self).build()
        newTabMenu = bar.items.compactMap(\.submenu).first { $0.delegate === self }
        NSApp.mainMenu = bar
    }

    /// Replaces the new-tab items in place if the commands changed, so that a menu that is
    /// open shows the list that has just arrived. The rest of the menu bar does not depend on
    /// the profiles.
    func updateNewTabItems() {
        let registry = currentRegistry
        guard registry != lastMenuRegistry, let newTabMenu else { return }
        lastMenuRegistry = registry
        MenuBuilder(registry: registry, target: self).replaceNewTabItems(in: newTabMenu)
    }

    /// The new-tab menu opens: the profiles follow the installed distributions. Not
    /// `menuNeedsUpdate(_:)`, which AppKit may also call while it looks for a key equivalent,
    /// so that a shortcut never sends a request.
    public func menuWillOpen(_ menu: NSMenu) {
        // The menu builder makes this controller the delegate of the new-tab menu only.
        guard menu.delegate === self else { return }
        distributions.refresh()
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
