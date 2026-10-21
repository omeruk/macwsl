import Foundation

/// The pages of the settings tab, in the order its `settings` box lists them.
public enum SettingsPage: String, Hashable, Sendable, CaseIterable {
    case appearance, general, keyboard, profiles, distributions

    /// The note on pages that arrive later, naming when.
    public var placeholder: String? {
        switch self {
        case .profiles:
            "Profiles beyond the local shell arrive in a later version, together with Linux "
                + "distribution support (roadmap phase 11)."
        case .distributions:
            "Distribution settings arrive in a later version, together with Linux distribution "
                + "support (roadmap phase 11)."
        case .appearance, .general, .keyboard:
            nil
        }
    }
}

/// The fields of the settings pages as `label  value` rows, and how each one changes the
/// settings. The view only draws rows and forwards keys; this type holds the rules, so that
/// they can be tested without a window.
public struct SettingsForm: Sendable {
    public enum FieldID: Hashable, Sendable {
        case theme, fontFamily, fontSize, cursorShape, backgroundOpacity
        case defaultProfile, localShell, showKeyHints, confirmClose, confirmQuit
    }

    public enum Kind: Hashable, Sendable {
        /// One of a list of values. ←→ cycles, ↩ opens the list.
        case choice(options: [String], selected: Int)
        /// A number. ←→ steps it.
        case number
        /// On or off. ←→ and ↩ flip it.
        case toggle
        /// Free text. ↩ edits it.
        case text(String)
    }

    public struct Field: Hashable, Sendable, Identifiable {
        public var id: FieldID
        public var label: String
        public var value: String
        public var kind: Kind
    }

    public var settings: Settings
    public var profiles: [Profile]

    public init(settings: Settings, profiles: [Profile]) {
        self.settings = settings
        self.profiles = profiles
    }

    static let confirmChoices = ["when a process is running", "never"]

    public func fields(on page: SettingsPage) -> [Field] {
        switch page {
        case .appearance:
            let themes = settings.availableThemes.map(\.name)
            var families = MawFonts.offeredFamilies
            if !families.contains(settings.fontFamily) {
                families.append(settings.fontFamily)
            }
            let shapes = CursorShape.allCases.map(\.rawValue)
            return [
                choice(.theme, "theme", themes, selected: settings.selectedTheme.name),
                choice(.fontFamily, "font family", families, selected: settings.fontFamily),
                Field(
                    id: .fontSize, label: "font size",
                    value: String(format: "%g", settings.fontSize), kind: .number),
                choice(.cursorShape, "cursor", shapes, selected: settings.cursorShape.rawValue),
                Field(
                    id: .backgroundOpacity, label: "background opacity",
                    value: "\(Int((settings.backgroundOpacity * 100).rounded()))%", kind: .number),
            ]
        case .general:
            let names = profiles.map(\.name)
            let selected = profiles.first { $0.id == settings.defaultProfile }?.name ?? names.first
            let shell = settings.localShell ?? ""
            return [
                choice(.defaultProfile, "default profile", names, selected: selected ?? ""),
                Field(
                    id: .localShell, label: "local shell",
                    value: shell.isEmpty ? "login shell (\(Profile.userLoginShell()))" : shell,
                    kind: .text(shell)),
                Field(
                    id: .showKeyHints, label: "show key hints",
                    value: settings.showKeyHints ? "on" : "off", kind: .toggle),
                choice(
                    .confirmClose, "confirm close", Self.confirmChoices,
                    selected: Self.confirmChoices[settings.confirmCloseWithRunningProcess ? 0 : 1]),
                choice(
                    .confirmQuit, "confirm quit", Self.confirmChoices,
                    selected: Self.confirmChoices[settings.confirmQuitWithRunningProcess ? 0 : 1]),
            ]
        case .keyboard, .profiles, .distributions:
            return []
        }
    }

    private func choice(_ id: FieldID, _ label: String, _ options: [String], selected: String)
        -> Field
    {
        Field(
            id: id, label: label, value: selected,
            kind: .choice(options: options, selected: options.firstIndex(of: selected) ?? 0))
    }

    /// The settings after ←→ on a field: the next or previous choice, wrapping; a number one
    /// step up or down, within its range; or a toggle flipped.
    public func stepping(_ id: FieldID, forward: Bool) -> Settings {
        var settings = self.settings
        guard let field = allFields.first(where: { $0.id == id }) else { return settings }
        switch field.kind {
        case .choice(let options, let selected):
            guard !options.isEmpty else { return settings }
            let next = (selected + (forward ? 1 : -1) + options.count) % options.count
            return choosing(id, index: next)
        case .number:
            switch id {
            case .fontSize:
                settings.fontSize = settings.fontSize.rounded() + (forward ? 1 : -1)
            case .backgroundOpacity:
                let percent = (settings.backgroundOpacity * 100 / 5).rounded() * 5
                settings.backgroundOpacity = (percent + (forward ? 5 : -5)) / 100
            default:
                break
            }
        case .toggle:
            settings.showKeyHints.toggle()
        case .text:
            break
        }
        return settings
    }

    /// The settings with option `index` of a choice field selected.
    public func choosing(_ id: FieldID, index: Int) -> Settings {
        var settings = self.settings
        guard let field = allFields.first(where: { $0.id == id }),
            case .choice(let options, _) = field.kind, options.indices.contains(index)
        else { return settings }
        let option = options[index]
        switch id {
        case .theme: settings.theme = option
        case .fontFamily: settings.fontFamily = option
        case .cursorShape: settings.cursorShape = CursorShape(rawValue: option) ?? .block
        case .defaultProfile:
            settings.defaultProfile =
                profiles.first { $0.name == option }?.id ?? settings.defaultProfile
        case .confirmClose: settings.confirmCloseWithRunningProcess = index == 0
        case .confirmQuit: settings.confirmQuitWithRunningProcess = index == 0
        default: break
        }
        return settings
    }

    /// The settings with a text field set. An empty local shell means the login shell.
    public func settingText(_ id: FieldID, to text: String) -> Settings {
        var settings = self.settings
        if id == .localShell {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            settings.localShell = trimmed.isEmpty ? nil : trimmed
        }
        return settings
    }

    private var allFields: [Field] {
        SettingsPage.allCases.flatMap(fields(on:))
    }
}
