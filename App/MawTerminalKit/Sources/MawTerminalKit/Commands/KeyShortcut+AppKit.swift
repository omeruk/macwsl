import AppKit

extension KeyShortcut {
    /// The menu item key equivalent and modifier mask for this shortcut. Letters are given in
    /// lowercase with an explicit Shift, so that the menu shows `⇧⌘P` as macOS writes it.
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags) {
        let key: String
        switch self.key {
        case .character(let character): key = String(character)
        case .upArrow: key = String(UnicodeScalar(NSUpArrowFunctionKey).map(Character.init) ?? " ")
        case .downArrow:
            key = String(UnicodeScalar(NSDownArrowFunctionKey).map(Character.init) ?? " ")
        case .leftArrow:
            key = String(UnicodeScalar(NSLeftArrowFunctionKey).map(Character.init) ?? " ")
        case .rightArrow:
            key = String(UnicodeScalar(NSRightArrowFunctionKey).map(Character.init) ?? " ")
        case .escape: key = "\u{1B}"
        case .return: key = "\r"
        case .tab: key = "\t"
        }
        return (key, modifiers.eventFlags)
    }
}

extension KeyShortcut.Modifiers {
    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        return flags
    }

    init(eventFlags flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.shift) { insert(.shift) }
    }
}

/// A key press, decoded from an `NSEvent` into the terms `KeyShortcut.matches` uses.
struct KeyStroke {
    var key: KeyShortcut.Key
    var unshiftedKey: KeyShortcut.Key?
    var modifiers: KeyShortcut.Modifiers

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        modifiers = KeyShortcut.Modifiers(eventFlags: event.modifierFlags)
        if let special = Self.specialKey(code: event.keyCode) {
            key = special
            unshiftedKey = special
            return
        }
        guard let typed = event.charactersIgnoringModifiers?.first else { return nil }
        key = .character(typed)
        unshiftedKey = event.characters(byApplyingModifiers: [])?.first.map { .character($0) }
    }

    private static func specialKey(code: UInt16) -> KeyShortcut.Key? {
        switch code {
        case 123: .leftArrow
        case 124: .rightArrow
        case 125: .downArrow
        case 126: .upArrow
        case 53: .escape
        case 36, 76: .return
        case 48: .tab
        default: nil
        }
    }

    func matches(_ shortcut: KeyShortcut) -> Bool {
        shortcut.matches(key: key, unshiftedKey: unshiftedKey, modifiers: modifiers)
    }
}
