import Foundation
import MawTerminalKit
import Testing

@Suite struct ThemeColorTests {
    @Test func parsesAndFormatsHex() {
        #expect(ThemeColor(hex: "#E8557C") == ThemeColor(red: 0xE8, green: 0x55, blue: 0x7C))
        #expect(ThemeColor(hex: "#e8557c")?.hex == "#E8557C")
        #expect(ThemeColor(hex: "#00000099")?.alpha == 0x99)
        #expect(ThemeColor(hex: "#00000099")?.hex == "#00000099")
    }

    @Test(arguments: ["E8557C", "#E8557", "#E8557CX", "#GGGGGG", "", "#"])
    func rejectsInvalidHex(_ text: String) {
        #expect(ThemeColor(hex: text) == nil)
    }

    @Test func mixesInSRGB() {
        let black: ThemeColor = "#000000"
        let white: ThemeColor = "#FFFFFF"
        #expect(black.mixed(with: white, fraction: 0) == black)
        #expect(black.mixed(with: white, fraction: 1) == white)
        #expect(black.mixed(with: white, fraction: 0.18).hex == "#2E2E2E")
    }

    @Test func decodingAnInvalidColorExplainsTheFormat() {
        let json = Data(#"["red"]"#.utf8)
        #expect {
            try JSONDecoder().decode([ThemeColor].self, from: json)
        } throws: { error in
            String(describing: error).contains("use #RRGGBB or #RRGGBBAA")
        }
    }
}

@Suite struct ThemeTests {
    @Test func thereAreSixBuiltInThemesInTheDesignOrder() {
        #expect(
            Theme.builtIn.map(\.name) == [
                "maw Default", "Catppuccin Mocha", "Dracula", "One Dark", "Gruvbox Dark",
                "Solarized Light",
            ])
        #expect(Theme.defaultName == "maw Default")
    }

    @Test(arguments: Theme.builtIn)
    func everyBuiltInThemeRoundTripsThroughJSON(_ theme: Theme) throws {
        let data = try JSONEncoder().encode(theme)
        #expect(try JSONDecoder().decode(Theme.self, from: data) == theme)
        // Every slot is present in the encoded form, so a custom theme must define them all.
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ansi = try #require(object["ansi"] as? [String: String])
        #expect(ansi.count == 16)
        for key in ["foreground", "background", "cursor", "cursorText", "selectionBackground"] {
            #expect(object[key] is String, "\(theme.name) has no \(key)")
        }
    }

    @Test func aThemeWithAMissingColorDoesNotDecode() throws {
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(Theme.dracula))
                as? [String: Any])
        var ansi = try #require(object["ansi"] as? [String: String])
        ansi["brightCyan"] = nil
        object["ansi"] = ansi
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Theme.self, from: data)
        }
    }

    @Test func mawDefaultHasTheExactDesignValues() {
        let theme = Theme.mawDefault
        #expect(
            theme.ansi.colors.map(\.hex) == [
                "#262626", "#E8557C", "#CAE797", "#F7CE46", "#A783F7", "#E99173", "#7AD3D5",
                "#CFD5E3", "#5D636F", "#F091AA", "#DDEFBB", "#FADF87", "#C6AEFA", "#F1B8A4",
                "#A9E2E4", "#E0E4ED",
            ])
        #expect(theme.background.hex == "#000000")
        #expect(theme.foreground.hex == "#CFD5E3")
        #expect(theme.cursor.hex == "#CFD5E3")
        #expect(theme.cursorText.hex == "#000000")
        #expect(theme.selectionBackground.hex == "#343A46")

        let chrome = theme.chromePalette
        #expect(chrome.background.hex == "#000000")
        #expect(chrome.titlebarBackground.hex == "#0A0A0A")
        #expect(chrome.line.hex == "#262626")
        #expect(chrome.lineStrong.hex == "#4A4A4A")
        #expect(chrome.text.hex == "#CFD5E3")
        #expect(chrome.textSelected.hex == "#000000")
        #expect(chrome.textSelectedSecondary.hex == "#4A4A4A")
        #expect(chrome.textSecondary.hex == "#8C8C8C")
        #expect(chrome.textTab.hex == "#A6A6A6")
        #expect(chrome.textTabNumber.hex == "#777777")
        #expect(chrome.textMuted.hex == "#8B91A1")
        #expect(chrome.accent.hex == "#F7CE46")
        #expect(chrome.statusOK.hex == "#CAE797")
        #expect(chrome.overlay.hex == "#00000099")
    }

    /// The contrast ratios that the design README records for maw Default.
    @Test func mawDefaultContrastMatchesTheREADME() {
        let black: ThemeColor = "#000000"
        let ansi = Theme.mawDefault.ansi
        let expected: [(ThemeColor, Double)] = [
            (ansi.black, 1.4), (ansi.red, 6.0), (ansi.green, 15.4), (ansi.yellow, 13.9),
            (ansi.blue, 7.2), (ansi.magenta, 8.8), (ansi.cyan, 12.1), (ansi.white, 14.3),
            (ansi.brightBlack, 3.5), (ansi.brightRed, 9.3), (ansi.brightGreen, 17.1),
            (ansi.brightYellow, 16.0), (ansi.brightBlue, 10.8), (ansi.brightMagenta, 12.1),
            (ansi.brightCyan, 14.7), (ansi.brightWhite, 16.5),
        ]
        for (color, ratio) in expected {
            let measured = (color.contrastRatio(with: black) * 10).rounded() / 10
            #expect(measured == ratio, "\(color.hex)")
        }
        let selection = Theme.mawDefault.foreground.contrastRatio(
            with: Theme.mawDefault.selectionBackground)
        #expect((selection * 10).rounded() / 10 == 7.8)
    }

    /// The bright colors are the normal ones moved 35% of the way to white in HLS space,
    /// keeping hue and saturation. Bright black and bright white are the exceptions the README
    /// documents: bright black is the reference theme's comment color.
    @Test func mawDefaultBrightColorsFollowTheDocumentedDerivation() {
        let ansi = Theme.mawDefault.ansi
        let pairs = [
            (ansi.red, ansi.brightRed), (ansi.green, ansi.brightGreen),
            (ansi.yellow, ansi.brightYellow), (ansi.blue, ansi.brightBlue),
            (ansi.magenta, ansi.brightMagenta), (ansi.cyan, ansi.brightCyan),
            (ansi.white, ansi.brightWhite),
        ]
        for (normal, bright) in pairs {
            let derived = lightened(normal, by: 0.35)
            for (a, b) in [
                (derived.red, bright.red), (derived.green, bright.green),
                (derived.blue, bright.blue),
            ] {
                #expect(
                    abs(Int(a) - Int(b)) <= 1, "\(normal.hex) → \(derived.hex), not \(bright.hex)")
            }
        }
    }

    @Test func chromeIsDerivedFromTheThemeWhenNotDefined() {
        let theme = Theme(
            name: "Test", ansi: Theme.mawDefault.ansi, foreground: "#FFFFFF",
            background: "#000000", cursor: "#FFFFFF", cursorText: "#000000",
            selectionBackground: "#333333")
        let chrome = theme.chromePalette
        #expect(chrome.background.hex == "#000000")
        #expect(chrome.text.hex == "#FFFFFF")
        #expect(chrome.line.hex == "#2E2E2E")
        #expect(chrome.lineStrong.hex == "#575757")
        #expect(chrome.textSecondary.hex == "#A6A6A6")
        #expect(chrome.textSelected.hex == "#000000")
        #expect(chrome.accent == theme.ansi.yellow)
        #expect(chrome.statusOK == theme.ansi.green)
        #expect(chrome.problem == theme.ansi.red)
        #expect(chrome.overlay.hex == "#00000099")
    }

    @Test func chromeOverridesReplaceOnlyTheTokensTheySet() {
        var theme = Theme.dracula
        theme.chrome = ChromeOverrides(accent: "#123456")
        let chrome = theme.chromePalette
        #expect(chrome.accent.hex == "#123456")
        #expect(chrome.line == ChromePalette.derived(from: Theme.dracula).line)
    }

    @Test func derivationApproximatesMawDefault() {
        var theme = Theme.mawDefault
        theme.chrome = nil
        let derived = theme.chromePalette
        let explicit = Theme.mawDefault.chromePalette
        let tokens: [(ThemeColor, ThemeColor)] = [
            (derived.titlebarBackground, explicit.titlebarBackground),
            (derived.line, explicit.line), (derived.lineStrong, explicit.lineStrong),
            (derived.textSecondary, explicit.textSecondary), (derived.textTab, explicit.textTab),
            (derived.textTabNumber, explicit.textTabNumber),
            (derived.textMuted, explicit.textMuted),
        ]
        for (a, b) in tokens {
            #expect(abs(Int(a.red) - Int(b.red)) <= 10, "\(a.hex) vs \(b.hex)")
            #expect(abs(Int(a.blue) - Int(b.blue)) <= 12, "\(a.hex) vs \(b.hex)")
        }
    }

    @Test func lightThemesDeriveDarkerGreys() {
        let chrome = Theme.solarizedLight.chromePalette
        #expect(chrome.line.relativeLuminance < chrome.background.relativeLuminance)
        #expect(chrome.textSecondary.relativeLuminance > chrome.text.relativeLuminance)
    }

    /// Moves a color `fraction` of the way to white in HLS space, keeping hue and saturation.
    func lightened(_ color: ThemeColor, by fraction: Double) -> ThemeColor {
        let r = Double(color.red) / 255
        let g = Double(color.green) / 255
        let b = Double(color.blue) / 255
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        var lightness = (maximum + minimum) / 2
        let delta = maximum - minimum
        var hue = 0.0
        var saturation = 0.0
        if delta > 0 {
            saturation =
                lightness > 0.5 ? delta / (2 - maximum - minimum) : delta / (maximum + minimum)
            switch maximum {
            case r: hue = (g - b) / delta + (g < b ? 6 : 0)
            case g: hue = (b - r) / delta + 2
            default: hue = (r - g) / delta + 4
            }
            hue /= 6
        }
        lightness += (1 - lightness) * fraction
        func component(_ p: Double, _ q: Double, _ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let q =
            lightness < 0.5
            ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        func byte(_ value: Double) -> UInt8 { UInt8((value * 255).rounded()) }
        if saturation == 0 {
            return ThemeColor(red: byte(lightness), green: byte(lightness), blue: byte(lightness))
        }
        return ThemeColor(
            red: byte(component(p, q, hue + 1 / 3)), green: byte(component(p, q, hue)),
            blue: byte(component(p, q, hue - 1 / 3)))
    }
}
