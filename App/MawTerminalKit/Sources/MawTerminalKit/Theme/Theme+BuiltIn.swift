import Foundation

extension Theme {
    /// The six built-in themes, in the order the appearance settings list them.
    public static let builtIn: [Theme] = [
        .mawDefault, .catppuccinMocha, .dracula, .oneDark, .gruvboxDark, .solarizedLight,
    ]

    /// The name of the theme used when the settings name none, or one that does not exist.
    public static let defaultName = Theme.mawDefault.name

    /// maw Default, exactly as `docs/design/terminal/README.md` defines it, including every
    /// chrome token. The bright colors are the normal ones moved 35% of the way to white in HLS
    /// space; the README records how they were derived and their contrast against black.
    public static let mawDefault = Theme(
        name: "maw Default",
        ansi: ANSIPalette(
            black: "#262626", red: "#E8557C", green: "#CAE797", yellow: "#F7CE46",
            blue: "#A783F7", magenta: "#E99173", cyan: "#7AD3D5", white: "#CFD5E3",
            brightBlack: "#5D636F", brightRed: "#F091AA", brightGreen: "#DDEFBB",
            brightYellow: "#FADF87", brightBlue: "#C6AEFA", brightMagenta: "#F1B8A4",
            brightCyan: "#A9E2E4", brightWhite: "#E0E4ED"),
        foreground: "#CFD5E3",
        background: "#000000",
        cursor: "#CFD5E3",
        cursorText: "#000000",
        selectionBackground: "#343A46",
        chrome: ChromeOverrides(
            background: "#000000",
            titlebarBackground: "#0A0A0A",
            line: "#262626",
            lineStrong: "#4A4A4A",
            text: "#CFD5E3",
            textSelected: "#000000",
            textSelectedSecondary: "#4A4A4A",
            textSecondary: "#8C8C8C",
            textTab: "#A6A6A6",
            textTabNumber: "#777777",
            textMuted: "#8B91A1",
            accent: "#F7CE46",
            statusOK: "#CAE797",
            problem: "#E8557C",
            overlay: "#00000099")
    )

    /// Catppuccin Mocha, from Catppuccin's official Windows Terminal port:
    /// https://github.com/catppuccin/windows-terminal/blob/4d8bb2f00fb86927a98dd3502cdec74a76d25d7b/mocha.json
    /// The port's `purple` slots are the magenta slots here. It defines no cursor text color, so
    /// the background is used.
    public static let catppuccinMocha = Theme(
        name: "Catppuccin Mocha",
        ansi: ANSIPalette(
            black: "#45475A", red: "#F38BA8", green: "#A6E3A1", yellow: "#F9E2AF",
            blue: "#89B4FA", magenta: "#F5C2E7", cyan: "#94E2D5", white: "#BAC2DE",
            brightBlack: "#585B70", brightRed: "#F38BA8", brightGreen: "#A6E3A1",
            brightYellow: "#F9E2AF", brightBlue: "#89B4FA", brightMagenta: "#F5C2E7",
            brightCyan: "#94E2D5", brightWhite: "#A6ADC8"),
        foreground: "#CDD6F4",
        background: "#1E1E2E",
        cursor: "#F5E0DC",
        cursorText: "#1E1E2E",
        selectionBackground: "#585B70"
    )

    /// Dracula, from Dracula's official Windows Terminal port:
    /// https://github.com/dracula/windows-terminal/blob/06f63714a0477a7b5c12cf0aa94ecf92d78f32ca/dracula.json
    /// The port's `purple` slots are the magenta slots here. It defines no cursor text color, so
    /// the background is used.
    public static let dracula = Theme(
        name: "Dracula",
        ansi: ANSIPalette(
            black: "#21222C", red: "#FF5555", green: "#50FA7B", yellow: "#F1FA8C",
            blue: "#BD93F9", magenta: "#FF79C6", cyan: "#8BE9FD", white: "#F8F8F2",
            brightBlack: "#6272A4", brightRed: "#FF6E6E", brightGreen: "#69FF94",
            brightYellow: "#FFFFA5", brightBlue: "#D6ACFF", brightMagenta: "#FF92DF",
            brightCyan: "#A4FFFF", brightWhite: "#FFFFFF"),
        foreground: "#F8F8F2",
        background: "#282A36",
        cursor: "#F8F8F2",
        cursorText: "#282A36",
        selectionBackground: "#44475A"
    )

    /// One Dark, from the terminal palettes published with onedark.vim:
    /// https://github.com/joshdick/onedark.vim/blob/47bec7a6196a843dad195d2666c3ac84c6e80c78/term/One%20Dark.kitty
    public static let oneDark = Theme(
        name: "One Dark",
        ansi: ANSIPalette(
            black: "#2C323C", red: "#E06C75", green: "#98C379", yellow: "#E5C07B",
            blue: "#61AFEF", magenta: "#C678DD", cyan: "#56B6C2", white: "#5C6370",
            brightBlack: "#3E4452", brightRed: "#E06C75", brightGreen: "#98C379",
            brightYellow: "#E5C07B", brightBlue: "#61AFEF", brightMagenta: "#C678DD",
            brightCyan: "#56B6C2", brightWhite: "#ABB2BF"),
        foreground: "#ABB2BF",
        background: "#282C34",
        cursor: "#5C6370",
        cursorText: "#2C323C",
        selectionBackground: "#5C6370"
    )

    /// Gruvbox Dark (medium contrast), from the palette in gruvbox's color scheme and its
    /// terminal color assignments (`g:terminal_color_0` to `15`):
    /// https://github.com/morhetz/gruvbox/blob/ef8864bb42bf244f0295d1c5a403b27e3d139695/colors/gruvbox.vim
    /// The scheme assigns no selection color to terminals, so `bg2` is used, which is its
    /// visual-selection background. The cursor is `fg1` on `bg0`.
    public static let gruvboxDark = Theme(
        name: "Gruvbox Dark",
        ansi: ANSIPalette(
            black: "#282828", red: "#CC241D", green: "#98971A", yellow: "#D79921",
            blue: "#458588", magenta: "#B16286", cyan: "#689D6A", white: "#A89984",
            brightBlack: "#928374", brightRed: "#FB4934", brightGreen: "#B8BB26",
            brightYellow: "#FABD2F", brightBlue: "#83A598", brightMagenta: "#D3869B",
            brightCyan: "#8EC07C", brightWhite: "#EBDBB2"),
        foreground: "#EBDBB2",
        background: "#282828",
        cursor: "#EBDBB2",
        cursorText: "#282828",
        selectionBackground: "#504945"
    )

    /// Solarized Light, from the palette and the terminal color assignments in Solarized's
    /// README:
    /// https://github.com/altercation/solarized/blob/62f656a02f93c5190a8753159e34b385588d5ff3/README.md
    /// The light mode uses `base3` as the background and `base00` as body text. The cursor is
    /// `base01`, and the selection is `base2`, the background highlight color.
    public static let solarizedLight = Theme(
        name: "Solarized Light",
        ansi: ANSIPalette(
            black: "#073642", red: "#DC322F", green: "#859900", yellow: "#B58900",
            blue: "#268BD2", magenta: "#D33682", cyan: "#2AA198", white: "#EEE8D5",
            brightBlack: "#002B36", brightRed: "#CB4B16", brightGreen: "#586E75",
            brightYellow: "#657B83", brightBlue: "#839496", brightMagenta: "#6C71C4",
            brightCyan: "#93A1A1", brightWhite: "#FDF6E3"),
        foreground: "#657B83",
        background: "#FDF6E3",
        cursor: "#586E75",
        cursorText: "#FDF6E3",
        selectionBackground: "#EEE8D5"
    )
}
