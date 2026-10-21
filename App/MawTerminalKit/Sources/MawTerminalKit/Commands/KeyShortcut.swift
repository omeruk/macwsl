import Foundation

/// A keyboard shortcut, independent of AppKit so that it can be compared, displayed, and tested
/// as a value. `KeyShortcut+AppKit.swift` converts it for menus and key events.
public struct KeyShortcut: Hashable, Sendable {
    public enum Key: Hashable, Sendable {
        /// A printable key, stored in lowercase: `"t"`, `"["`, `"+"`, `","`.
        case character(Character)
        case upArrow, downArrow, leftArrow, rightArrow
        case escape, `return`, tab

        /// How the key appears in menus, key hints, and the palette.
        public var symbol: String {
            switch self {
            case .character(let character): String(character).uppercased()
            case .upArrow: "↑"
            case .downArrow: "↓"
            case .leftArrow: "←"
            case .rightArrow: "→"
            case .escape: "esc"
            case .return: "↩"
            case .tab: "⇥"
            }
        }
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let command = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)

        /// The modifier symbols in the order the design writes them: `⌘⇧P`, `⌥⌘←`.
        public var symbols: String {
            var text = ""
            if contains(.control) { text += "⌃" }
            if contains(.option) { text += "⌥" }
            if contains(.command) { text += "⌘" }
            if contains(.shift) { text += "⇧" }
            return text
        }
    }

    public var key: Key
    public var modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers = []) {
        if case .character(let character) = key {
            self.key = .character(Character(character.lowercased()))
        } else {
            self.key = key
        }
        self.modifiers = modifiers
    }

    /// A shortcut with the command key and the given character, for example `.command("t")`.
    public static func command(_ character: Character, _ extra: Modifiers = []) -> KeyShortcut {
        KeyShortcut(.character(character), extra.union(.command))
    }

    /// The shortcut as the design writes it, for example `⌘⇧P`, `⌘,`, or `⌥⌘←`. A letter on
    /// its own, such as a screen's `i`, stays lowercase, as the key hints show it.
    public var displayString: String {
        if modifiers.isEmpty, case .character(let character) = key {
            return String(character)
        }
        return modifiers.symbols + key.symbol
    }

    /// Characters that are typed with Shift on common layouts but whose shortcut is written
    /// without it, mapped to the unshifted key that should also trigger the shortcut. `⌘+` is
    /// typed as ⌘⇧= on a US keyboard, and ⌘= is accepted as well, as in Terminal and Safari.
    static let unshiftedAliases: [Character: Character] = ["+": "="]

    /// Whether a key press triggers this shortcut.
    ///
    /// - Parameters:
    ///   - key: The key as typed, with Shift applied, as `NSEvent.charactersIgnoringModifiers`
    ///     reports it: `"{"` for ⇧[, `"+"` for ⇧= on a US layout.
    ///   - unshiftedKey: The same key without Shift, as `NSEvent.characters(byApplyingModifiers:)`
    ///     with no modifiers reports it: `"["`, `"="`.
    ///   - modifiers: The modifiers held, including Shift.
    public func matches(key pressed: Key, unshiftedKey: Key?, modifiers held: Modifiers) -> Bool {
        let pressed = Self.normalized(pressed)
        let unshifted = unshiftedKey.map(Self.normalized)
        if modifiers.contains(.shift) {
            // ⌘⇧] arrives as "}" with Shift, or "]" with Shift on layouts that report it so.
            return held == modifiers && (pressed == key || unshifted == key)
        }
        if held == modifiers {
            if pressed == key { return true }
            if case .character(let character) = key,
                let alias = Self.unshiftedAliases[character],
                pressed == .character(alias)
            {
                return true
            }
            return false
        }
        // A shortcut written without Shift whose character needs Shift to type, such as ⌘+.
        if held == modifiers.union(.shift), pressed == key, case .character(let character) = key,
            !character.isLetter
        {
            return true
        }
        return false
    }

    private static func normalized(_ key: Key) -> Key {
        guard case .character(let character) = key else { return key }
        return .character(Character(character.lowercased()))
    }
}
