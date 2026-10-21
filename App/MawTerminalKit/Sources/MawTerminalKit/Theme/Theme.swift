import Foundation

/// The 16 ANSI colors. Keys in settings files follow Windows Terminal's names.
public struct ANSIPalette: Hashable, Sendable, Codable {
    public var black: ThemeColor
    public var red: ThemeColor
    public var green: ThemeColor
    public var yellow: ThemeColor
    public var blue: ThemeColor
    public var magenta: ThemeColor
    public var cyan: ThemeColor
    public var white: ThemeColor
    public var brightBlack: ThemeColor
    public var brightRed: ThemeColor
    public var brightGreen: ThemeColor
    public var brightYellow: ThemeColor
    public var brightBlue: ThemeColor
    public var brightMagenta: ThemeColor
    public var brightCyan: ThemeColor
    public var brightWhite: ThemeColor

    public init(
        black: ThemeColor, red: ThemeColor, green: ThemeColor, yellow: ThemeColor,
        blue: ThemeColor, magenta: ThemeColor, cyan: ThemeColor, white: ThemeColor,
        brightBlack: ThemeColor, brightRed: ThemeColor, brightGreen: ThemeColor,
        brightYellow: ThemeColor, brightBlue: ThemeColor, brightMagenta: ThemeColor,
        brightCyan: ThemeColor, brightWhite: ThemeColor
    ) {
        self.black = black
        self.red = red
        self.green = green
        self.yellow = yellow
        self.blue = blue
        self.magenta = magenta
        self.cyan = cyan
        self.white = white
        self.brightBlack = brightBlack
        self.brightRed = brightRed
        self.brightGreen = brightGreen
        self.brightYellow = brightYellow
        self.brightBlue = brightBlue
        self.brightMagenta = brightMagenta
        self.brightCyan = brightCyan
        self.brightWhite = brightWhite
    }

    /// The colors in ANSI order: the eight normal colors, then the eight bright ones.
    public var colors: [ThemeColor] {
        [
            black, red, green, yellow, blue, magenta, cyan, white,
            brightBlack, brightRed, brightGreen, brightYellow,
            brightBlue, brightMagenta, brightCyan, brightWhite,
        ]
    }
}

/// A terminal color theme: the ANSI palette, the terminal's own colors, and optionally the
/// window chrome. Built-in themes are in `Theme+BuiltIn.swift`; settings files may add more.
public struct Theme: Hashable, Sendable, Codable, Identifiable {
    public var name: String
    public var ansi: ANSIPalette
    public var foreground: ThemeColor
    public var background: ThemeColor
    public var cursor: ThemeColor
    public var cursorText: ThemeColor
    public var selectionBackground: ThemeColor
    /// Chrome tokens the theme sets explicitly. Tokens left out are derived from the theme.
    public var chrome: ChromeOverrides?

    public var id: String { name }

    public init(
        name: String, ansi: ANSIPalette, foreground: ThemeColor, background: ThemeColor,
        cursor: ThemeColor, cursorText: ThemeColor, selectionBackground: ThemeColor,
        chrome: ChromeOverrides? = nil
    ) {
        self.name = name
        self.ansi = ansi
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.chrome = chrome
    }

    /// The window chrome for this theme: the theme's own tokens where it sets them, and the
    /// derivation in `ChromePalette.derived(from:)` for the rest.
    public var chromePalette: ChromePalette {
        ChromePalette.derived(from: self).applying(chrome)
    }
}
