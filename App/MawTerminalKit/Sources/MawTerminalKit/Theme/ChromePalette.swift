import Foundation

/// The colors of the window chrome, named after the tokens in `docs/design/terminal/README.md`.
public struct ChromePalette: Hashable, Sendable {
    public var background: ThemeColor
    public var titlebarBackground: ThemeColor
    public var line: ThemeColor
    public var lineStrong: ThemeColor
    public var text: ThemeColor
    public var textSelected: ThemeColor
    public var textSelectedSecondary: ThemeColor
    public var textSecondary: ThemeColor
    public var textTab: ThemeColor
    public var textTabNumber: ThemeColor
    public var textMuted: ThemeColor
    public var accent: ThemeColor
    public var statusOK: ThemeColor
    /// The theme's red slot. It marks problems: errors, invalid settings, failed states.
    public var problem: ThemeColor
    public var overlay: ThemeColor

    /// How far each grey token sits between the theme's background (0) and foreground (1).
    ///
    /// The fractions reproduce the maw Default greys to within a few steps per component: for
    /// example `line` is `#262626` there, and 0.18 of the way from `#000000` to `#CFD5E3` is
    /// `#252629`. Mixing in sRGB keeps the derivation predictable for light themes too, where
    /// the greys move from a light background towards a dark foreground.
    public enum Mix {
        public static let titlebarBackground = 0.05
        public static let line = 0.18
        public static let lineStrong = 0.34
        public static let textTabNumber = 0.55
        public static let textSecondary = 0.65
        public static let textMuted = 0.68
        public static let textTab = 0.77
        /// The opacity of the background behind the command palette.
        public static let overlayOpacity = 0.6
    }

    /// Derives every token from the theme's background, foreground, and ANSI slots: the greys
    /// by mixing the foreground into the background (see `Mix`), `accent` from yellow,
    /// `statusOK` from green, and `problem` from red. Selected text is the background color on
    /// the foreground, as reverse video.
    public static func derived(from theme: Theme) -> ChromePalette {
        let background = theme.background
        let foreground = theme.foreground
        func grey(_ fraction: Double) -> ThemeColor {
            background.mixed(with: foreground, fraction: fraction)
        }
        return ChromePalette(
            background: background,
            titlebarBackground: grey(Mix.titlebarBackground),
            line: grey(Mix.line),
            lineStrong: grey(Mix.lineStrong),
            text: foreground,
            textSelected: background,
            textSelectedSecondary: grey(Mix.lineStrong),
            textSecondary: grey(Mix.textSecondary),
            textTab: grey(Mix.textTab),
            textTabNumber: grey(Mix.textTabNumber),
            textMuted: grey(Mix.textMuted),
            accent: theme.ansi.yellow,
            statusOK: theme.ansi.green,
            problem: theme.ansi.red,
            overlay: background.withOpacity(Mix.overlayOpacity)
        )
    }

    /// The palette with every token that `overrides` sets replaced.
    public func applying(_ overrides: ChromeOverrides?) -> ChromePalette {
        guard let overrides else { return self }
        var palette = self
        for (keyPath, override) in ChromeOverrides.tokens {
            if let color = overrides[keyPath: override] {
                palette[keyPath: keyPath] = color
            }
        }
        return palette
    }
}

/// Chrome tokens set by a theme. In settings files the keys are the token names in camel case,
/// for example `lineStrong` for `line.strong`.
public struct ChromeOverrides: Hashable, Sendable, Codable {
    public var background: ThemeColor?
    public var titlebarBackground: ThemeColor?
    public var line: ThemeColor?
    public var lineStrong: ThemeColor?
    public var text: ThemeColor?
    public var textSelected: ThemeColor?
    public var textSelectedSecondary: ThemeColor?
    public var textSecondary: ThemeColor?
    public var textTab: ThemeColor?
    public var textTabNumber: ThemeColor?
    public var textMuted: ThemeColor?
    public var accent: ThemeColor?
    public var statusOK: ThemeColor?
    public var problem: ThemeColor?
    public var overlay: ThemeColor?

    public init(
        background: ThemeColor? = nil, titlebarBackground: ThemeColor? = nil,
        line: ThemeColor? = nil, lineStrong: ThemeColor? = nil, text: ThemeColor? = nil,
        textSelected: ThemeColor? = nil, textSelectedSecondary: ThemeColor? = nil,
        textSecondary: ThemeColor? = nil, textTab: ThemeColor? = nil,
        textTabNumber: ThemeColor? = nil, textMuted: ThemeColor? = nil,
        accent: ThemeColor? = nil, statusOK: ThemeColor? = nil, problem: ThemeColor? = nil,
        overlay: ThemeColor? = nil
    ) {
        self.background = background
        self.titlebarBackground = titlebarBackground
        self.line = line
        self.lineStrong = lineStrong
        self.text = text
        self.textSelected = textSelected
        self.textSelectedSecondary = textSelectedSecondary
        self.textSecondary = textSecondary
        self.textTab = textTab
        self.textTabNumber = textTabNumber
        self.textMuted = textMuted
        self.accent = accent
        self.statusOK = statusOK
        self.problem = problem
        self.overlay = overlay
    }

    /// Every palette token paired with its override, so that the two lists cannot drift apart.
    static var tokens:
        [(WritableKeyPath<ChromePalette, ThemeColor>, KeyPath<ChromeOverrides, ThemeColor?>)]
    {
        [
            (\.background, \.background),
            (\.titlebarBackground, \.titlebarBackground),
            (\.line, \.line),
            (\.lineStrong, \.lineStrong),
            (\.text, \.text),
            (\.textSelected, \.textSelected),
            (\.textSelectedSecondary, \.textSelectedSecondary),
            (\.textSecondary, \.textSecondary),
            (\.textTab, \.textTab),
            (\.textTabNumber, \.textTabNumber),
            (\.textMuted, \.textMuted),
            (\.accent, \.accent),
            (\.statusOK, \.statusOK),
            (\.problem, \.problem),
            (\.overlay, \.overlay),
        ]
    }
}
