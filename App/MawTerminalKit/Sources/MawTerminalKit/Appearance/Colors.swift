import AppKit
import SwiftTerm
import SwiftUI

extension ThemeColor {
    public var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255)
    }

    public var color: SwiftUI.Color {
        SwiftUI.Color(nsColor: nsColor)
    }

    /// SwiftTerm's color type, which uses 16-bit components.
    var terminalColor: SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16(red) * 257, green: UInt16(green) * 257, blue: UInt16(blue) * 257)
    }
}

/// The chrome palette in SwiftUI, passed down the view hierarchy.
struct ChromeKey: EnvironmentKey {
    static let defaultValue = Theme.mawDefault.chromePalette
}

/// The theme's ANSI palette, for data colors such as numbers in the distributions table.
struct ANSIKey: EnvironmentKey {
    static let defaultValue = Theme.mawDefault.ansi
}

extension EnvironmentValues {
    var chrome: ChromePalette {
        get { self[ChromeKey.self] }
        set { self[ChromeKey.self] = newValue }
    }

    var ansi: ANSIPalette {
        get { self[ANSIKey.self] }
        set { self[ANSIKey.self] = newValue }
    }
}

extension Text {
    /// Text in the chrome font with the design's 20 pt line height.
    func chromeStyle(_ color: ThemeColor, semibold: Bool = false) -> some View {
        font(MawFonts.chromeFont(semibold: semibold))
            .foregroundStyle(color.color)
            .lineLimit(1)
    }
}
