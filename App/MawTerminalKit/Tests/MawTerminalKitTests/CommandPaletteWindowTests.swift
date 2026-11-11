import AppKit
import SwiftUI
import Testing

@testable import MawTerminalKit

/// The command palette's view in a window, with each key delivered as AppKit delivers a typed
/// key, so that what SwiftUI itself does is part of the test.
///
/// The query field writes its unchanged text back through its binding, and
/// `WindowModel.setPaletteQuery(_:)` must ignore that write. On macOS 27 the field writes once
/// when it receives the focus, whatever the SDK, which would open the theme list on its first
/// row. It also writes whenever the view updates, as a theme preview makes it do, which would
/// undo each arrow; SwiftUI does that only when the running program was linked with the
/// macOS 27 SDK or later. Under `swift test` that program is the test runner of the selected
/// Xcode, so these tests follow that Xcode's SDK, not the SDK that the test bundle records
/// (docs/decisions/0019-swiftui-behavior-in-app-tests.md).
@MainActor @Suite struct CommandPaletteWindowTests {
    enum Key {
        case down, up, escape

        var characters: String {
            switch self {
            case .down: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
            case .up: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
            case .escape: "\u{1B}"
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .down: 125
            case .up: 126
            case .escape: 53
            }
        }

        var modifiers: NSEvent.ModifierFlags {
            self == .escape ? [] : [.numericPad, .function]
        }
    }

    /// A window whose content is the model's view, as in `TerminalWindowController`. It is
    /// never ordered on screen; SwiftUI lays it out and gives it the focus all the same.
    func show(_ model: WindowModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WindowRootView(model: model))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    /// Lets SwiftUI give the palette's query field the keys, which it does on the main queue
    /// after the palette appears. The bound counts turns, not time, and is reached only if the
    /// field never receives the focus.
    func waitForTheQueryField(in window: NSWindow) async throws {
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<1000 where !(window.firstResponder is NSTextView) {
            await Task.yield()
        }
        try #require(
            window.firstResponder is NSTextView, "The palette's query field has no focus.")
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Delivers `key` to the window as a key press, then lets SwiftUI update the view, which is
    /// when the query field writes its text back.
    func press(_ key: Key, in window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: key.modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: key.characters,
                    charactersIgnoringModifiers: key.characters, isARepeat: false,
                    keyCode: key.keyCode))
            window.sendEvent(event)
        }
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// The theme list opens on the current theme; ↓ ↓ ↑ move the selection and preview each
    /// theme, and esc restores the theme that was current.
    @Test func theThemeListsArrowsMoveTheSelectionInTheWindow() async throws {
        let (model, _, _) = WindowModelTests().window { $0.theme = "Dracula" }
        let names = model.settings.availableThemes.map(\.name)
        let start = try #require(names.firstIndex(of: "Dracula"))
        try #require(start + 2 < names.count)
        let window = show(model)
        defer { window.close() }
        func selected() -> String? { model.palette.map { names[$0.selectedIndex(in: names)] } }

        model.perform(.switchTheme)
        try await waitForTheQueryField(in: window)
        #expect(selected() == "Dracula")

        for (key, index) in [(Key.down, start + 1), (.down, start + 2), (.up, start + 1)] {
            try press(key, in: window)
            #expect(selected() == names[index], "after \(key)")
            #expect(model.previewThemeName == names[index], "after \(key)")
        }

        try press(.escape, in: window)
        #expect(model.palette == nil)
        #expect(model.previewThemeName == nil)
        #expect(model.effectiveSettings.theme == "Dracula")
    }
}
