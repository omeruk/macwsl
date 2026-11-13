import Foundation

/// How the distributions screen writes the daemon's figures, as the phase 11c prompt and
/// `Distributions.dc.html` show them.
enum FigureFormat {
    /// Binary units with one decimal below 10 and whole numbers above: `512B`, `412M`, `1.2G`,
    /// `256G`.
    static func bytes(_ count: UInt64) -> String {
        let units = ["K", "M", "G", "T", "P"]
        guard count >= 1024 else { return "\(count)B" }
        var value = Double(count) / 1024
        var unit = 0
        while unit < units.count - 1, value.rounded() >= 1024 {
            value /= 1024
            unit += 1
        }
        return "\(number(value))\(units[unit])"
    }

    /// Percent of one core, which may exceed 100: `0.4%`, `37%`, `180%`.
    static func percent(_ value: Double) -> String {
        "\(number(max(0, value)))%"
    }

    /// `37s`, `41m`, `2h 14m`, `3d 2h`.
    static func uptime(_ milliseconds: UInt64) -> String {
        let seconds = milliseconds / 1000
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
        default: return "\(seconds / 86_400)d \(seconds % 86_400 / 3600)h"
        }
    }

    /// The path with the home directory written as `~`.
    static func path(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// One decimal below 10, as written; whole numbers from there on.
    private static func number(_ value: Double) -> String {
        let tenth = (value * 10).rounded() / 10
        if tenth < 10 { return String(format: "%.1f", tenth) }
        return String(format: "%.0f", value.rounded())
    }
}
