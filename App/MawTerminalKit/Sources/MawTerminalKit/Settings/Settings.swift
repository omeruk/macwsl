import Foundation

/// The cursor shapes the appearance settings offer.
public enum CursorShape: String, Hashable, Sendable, Codable, CaseIterable {
    case block, bar, underline
}

/// The user's settings, stored as JSON in `settings.json` (see `SettingsStore`).
///
/// Every key is optional in the file: a missing key takes its default, so a file that sets only
/// `"theme"` is valid. Unknown keys are ignored, so that a newer file still opens in an older
/// build as far as it can.
public struct Settings: Hashable, Sendable {
    /// The format version this build writes. `SettingsMigration` upgrades older files.
    public static let currentVersion = 1

    public static let fontSizeRange: ClosedRange<Double> = 8...36
    public static let backgroundOpacityRange: ClosedRange<Double> = 0.3...1
    public static let defaultFontSize = 13.0
    public static let defaultFontFamily = "IBM Plex Mono"

    public var theme = Theme.defaultName
    /// Themes defined in the file. A custom theme with a built-in theme's name replaces it.
    public var themes: [Theme] = []
    public var fontFamily = Settings.defaultFontFamily
    public var fontSize = Settings.defaultFontSize {
        didSet { fontSize = Self.clamp(fontSize, to: Self.fontSizeRange) }
    }
    public var cursorShape = CursorShape.block
    public var backgroundOpacity = 1.0 {
        didSet {
            backgroundOpacity = Self.clamp(backgroundOpacity, to: Self.backgroundOpacityRange)
        }
    }
    public var defaultProfile = Profile.localShellID
    /// The local profile's shell. `nil` uses the login shell from the user database.
    public var localShell: String?
    public var showKeyHints = true
    public var confirmCloseWithRunningProcess = true
    public var confirmQuitWithRunningProcess = true

    public init() {}

    /// The built-in themes and the custom ones, with custom themes replacing built-in themes of
    /// the same name, in the order the appearance page lists them.
    public var availableThemes: [Theme] {
        var themes = Theme.builtIn.map { builtIn in
            self.themes.last { $0.name == builtIn.name } ?? builtIn
        }
        for custom in self.themes where !themes.contains(where: { $0.name == custom.name }) {
            themes.append(custom)
        }
        return themes
    }

    /// The selected theme, or maw Default if the settings name a theme that does not exist.
    public var selectedTheme: Theme {
        availableThemes.first { $0.name == theme } ?? .mawDefault
    }

    /// The local shell profile, with the configured shell or the user's login shell.
    public var localShellProfile: Profile {
        let configured = localShell?.trimmingCharacters(in: .whitespaces)
        if let configured, !configured.isEmpty {
            return .localShell(configured)
        }
        return .localShell(Profile.userLoginShell())
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
    }
}

extension Settings: Codable {
    enum CodingKeys: String, CodingKey {
        case version, theme, themes, fontFamily, fontSize, cursorShape, backgroundOpacity
        case defaultProfile, localShell, showKeyHints
        case confirmCloseWithRunningProcess, confirmQuitWithRunningProcess
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        theme = try container.decodeIfPresent(String.self, forKey: .theme) ?? defaults.theme
        themes = try container.decodeIfPresent([Theme].self, forKey: .themes) ?? defaults.themes
        fontFamily =
            try container.decodeIfPresent(String.self, forKey: .fontFamily) ?? defaults.fontFamily
        // Property observers do not run in an initializer, so the ranges are applied here.
        fontSize = Self.clamp(
            try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? defaults.fontSize,
            to: Self.fontSizeRange)
        cursorShape =
            try container.decodeIfPresent(CursorShape.self, forKey: .cursorShape)
            ?? defaults.cursorShape
        backgroundOpacity = Self.clamp(
            try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity)
                ?? defaults.backgroundOpacity,
            to: Self.backgroundOpacityRange)
        defaultProfile =
            try container.decodeIfPresent(String.self, forKey: .defaultProfile)
            ?? defaults.defaultProfile
        localShell = try container.decodeIfPresent(String.self, forKey: .localShell)
        showKeyHints =
            try container.decodeIfPresent(Bool.self, forKey: .showKeyHints) ?? defaults.showKeyHints
        confirmCloseWithRunningProcess =
            try container.decodeIfPresent(Bool.self, forKey: .confirmCloseWithRunningProcess)
            ?? defaults.confirmCloseWithRunningProcess
        confirmQuitWithRunningProcess =
            try container.decodeIfPresent(Bool.self, forKey: .confirmQuitWithRunningProcess)
            ?? defaults.confirmQuitWithRunningProcess
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(theme, forKey: .theme)
        if !themes.isEmpty {
            try container.encode(themes, forKey: .themes)
        }
        try container.encode(fontFamily, forKey: .fontFamily)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(cursorShape, forKey: .cursorShape)
        try container.encode(backgroundOpacity, forKey: .backgroundOpacity)
        try container.encode(defaultProfile, forKey: .defaultProfile)
        try container.encodeIfPresent(localShell, forKey: .localShell)
        try container.encode(showKeyHints, forKey: .showKeyHints)
        try container.encode(
            confirmCloseWithRunningProcess, forKey: .confirmCloseWithRunningProcess)
        try container.encode(confirmQuitWithRunningProcess, forKey: .confirmQuitWithRunningProcess)
    }
}
