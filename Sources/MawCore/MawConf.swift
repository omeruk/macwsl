/// `/etc/maw.conf` inside a distribution, the counterpart of WSL's `/etc/wsl.conf`.
///
/// The file has sections in brackets and `key = value` lines; `#` and `;` start comments.
/// Phase 05 reads `[user] default`, the user that sessions run as. Phase 12 adds the other
/// settings.
public struct MawConf: Equatable, Sendable {
    /// The settings, keyed by `section.key` in lowercase.
    public private(set) var values: [String: String] = [:]

    public init(parsing text: String) {
        var section = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = trimmed(rawLine)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                continue
            }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = trimmed(line.dropFirst().dropLast()).lowercased()
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = trimmed(line[..<equals]).lowercased()
            var value = trimmed(line[line.index(after: equals)...])
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            values["\(section).\(key)"] = value
        }
    }

    /// `[user] default`: the user that sessions run as when none is given.
    public var defaultUser: String? {
        values["user.default"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The file that provisioning writes for a new distribution.
    public static func contents(defaultUser: UserName) -> String {
        """
        # maw settings for this distribution. docs/distributions.md describes them.
        [user]
        default = \(defaultUser)

        """
    }
}

/// `text` without leading and trailing spaces and tabs.
private func trimmed(_ text: some StringProtocol) -> String {
    let isBlank: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\r" }
    let start = text.firstIndex { !isBlank($0) } ?? text.endIndex
    let end = text.lastIndex { !isBlank($0) }.map(text.index(after:)) ?? start
    return String(text[start..<end])
}
