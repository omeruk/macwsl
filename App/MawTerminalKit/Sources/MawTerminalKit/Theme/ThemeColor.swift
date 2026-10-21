import Foundation

/// An sRGB color with 8-bit components, written in settings files as `#RRGGBB` or `#RRGGBBAA`.
public struct ThemeColor: Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Parses `#RRGGBB` or `#RRGGBBAA`. The `#` is required; hex digits may be in either case.
    public init?(hex: String) {
        guard hex.first == "#" else { return nil }
        let digits = hex.dropFirst()
        guard digits.count == 6 || digits.count == 8,
            digits.allSatisfy(\.isHexDigit),
            let value = UInt32(digits, radix: 16)
        else { return nil }
        if digits.count == 6 {
            self.init(
                red: UInt8(value >> 16 & 0xFF), green: UInt8(value >> 8 & 0xFF),
                blue: UInt8(value & 0xFF))
        } else {
            self.init(
                red: UInt8(value >> 24 & 0xFF), green: UInt8(value >> 16 & 0xFF),
                blue: UInt8(value >> 8 & 0xFF), alpha: UInt8(value & 0xFF))
        }
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when the color is not opaque.
    public var hex: String {
        let rgb = String(format: "#%02X%02X%02X", red, green, blue)
        return alpha == 255 ? rgb : rgb + String(format: "%02X", alpha)
    }

    /// The color moved `fraction` of the way from `self` towards `other`, per component, in
    /// sRGB. A fraction of 0 returns `self` and 1 returns `other`. Alpha is taken from `self`.
    public func mixed(with other: ThemeColor, fraction: Double) -> ThemeColor {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Double(a) + (Double(b) - Double(a)) * fraction).rounded())
        }
        return ThemeColor(
            red: mix(red, other.red), green: mix(green, other.green),
            blue: mix(blue, other.blue), alpha: alpha)
    }

    /// The same color with the given opacity, from 0 to 1.
    public func withOpacity(_ opacity: Double) -> ThemeColor {
        var color = self
        color.alpha = UInt8((max(0, min(1, opacity)) * 255).rounded())
        return color
    }

    /// The WCAG 2 relative luminance, from 0 (black) to 1 (white). Alpha is ignored.
    public var relativeLuminance: Double {
        func linear(_ component: UInt8) -> Double {
            let value = Double(component) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG 2 contrast ratio between two colors, from 1 to 21.
    public func contrastRatio(with other: ThemeColor) -> Double {
        let (lighter, darker) = (
            max(relativeLuminance, other.relativeLuminance),
            min(relativeLuminance, other.relativeLuminance)
        )
        return (lighter + 0.05) / (darker + 0.05)
    }
}

extension ThemeColor: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let color = ThemeColor(hex: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "'\(text)' is not a color; use #RRGGBB or #RRGGBBAA.")
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

extension ThemeColor: ExpressibleByStringLiteral {
    /// Built-in themes are written as literals. An invalid literal is a programming error.
    public init(stringLiteral value: String) {
        guard let color = ThemeColor(hex: value) else {
            preconditionFailure("Invalid color literal \(value)")
        }
        self = color
    }
}
