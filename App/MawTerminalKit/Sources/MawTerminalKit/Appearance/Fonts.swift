import AppKit
import CoreText
import SwiftUI
import os

/// The app's fonts. IBM Plex Mono is bundled with the app and used for the chrome and the
/// terminal alike; if it cannot be loaded, SF Mono and then Menlo stand in.
public enum MawFonts {
    /// The family name of the bundled font.
    public static let bundledFamily = "IBM Plex Mono"
    /// The chrome's size and line height, from the design README.
    public static let chromeSize: CGFloat = 13
    public static let chromeLineHeight: CGFloat = 20

    /// The families the appearance settings offer. Any installed monospaced family can also be
    /// named in the settings file.
    public static let offeredFamilies = [bundledFamily, "SF Mono", "Menlo"]

    /// Registers the font files in `directory` for this process. The app calls this at launch
    /// with its bundled `Fonts` folder.
    public static func registerFonts(in directory: URL) {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        let fonts = files.filter { ["otf", "ttf"].contains($0.pathExtension.lowercased()) }
        guard !fonts.isEmpty else {
            Logger.app.error("No font files in \(directory.path, privacy: .public)")
            return
        }
        for font in fonts {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(font as CFURL, .process, &error) {
                let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
                Logger.app.error(
                    "Could not register \(font.lastPathComponent, privacy: .public): \(reason, privacy: .public)"
                )
            }
        }
    }

    /// The terminal font for `family` at `size`, falling back to SF Mono, then Menlo.
    public static func terminalFont(family: String, size: CGFloat) -> NSFont {
        if let font = font(family: family, size: size, weight: 5) {
            return font
        }
        if family != bundledFamily, let font = font(family: bundledFamily, size: size, weight: 5) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The chrome font: IBM Plex Mono at 13 pt, Regular or SemiBold.
    public static func chromeFont(semibold: Bool = false) -> Font {
        let weight = semibold ? 8 : 5
        if let font = font(family: bundledFamily, size: chromeSize, weight: weight) {
            return Font(font)
        }
        return .system(
            size: chromeSize, weight: semibold ? .semibold : .regular, design: .monospaced)
    }

    /// The width of one character of the chrome font, for column layouts.
    public static var chromeCharacterWidth: CGFloat {
        let font =
            font(family: bundledFamily, size: chromeSize, weight: 5)
            ?? .monospacedSystemFont(ofSize: chromeSize, weight: .regular)
        return ("M" as NSString).size(withAttributes: [.font: font]).width
    }

    /// `weight` uses NSFontManager's scale: 5 is regular, 8 is semibold, 9 is bold.
    private static func font(family: String, size: CGFloat, weight: Int) -> NSFont? {
        if family == "SF Mono" {
            return .monospacedSystemFont(ofSize: size, weight: weight >= 8 ? .semibold : .regular)
        }
        return NSFontManager.shared.font(withFamily: family, traits: [], weight: weight, size: size)
    }
}
