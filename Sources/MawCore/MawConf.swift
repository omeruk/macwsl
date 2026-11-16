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

    /// `text` with `[user] default` set to `user`, every other line kept as it is, or `nil` if
    /// `text` already names `user`. Line endings become LF.
    ///
    /// The parser keeps the last `default` line of the last `[user]` section, so that line is
    /// replaced. Without one, the line goes under the last `[user]` section header, and without
    /// such a section, a new section is appended.
    public static func settingDefaultUser(_ user: String, in text: String) -> String? {
        if MawConf(parsing: text).defaultUser == user {
            return nil
        }
        let setting = "default = \(user)"
        // Every line break, as the parser splits: "\r\n" is one Character in Swift, so a split
        // at "\n" alone would see a file with CRLF line endings as one line. The result has LF
        // line endings.
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        // A file that ends with a line break splits into a last, empty element.
        let endsWithLineBreak = lines.last == ""
        if endsWithLineBreak {
            lines.removeLast()
        }
        var section = ""
        var lastHeader: Int?
        var lastDefault: Int?
        for (index, rawLine) in lines.enumerated() {
            let line = trimmed(rawLine)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                continue
            }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = trimmed(line.dropFirst().dropLast()).lowercased()
                if section == "user" {
                    lastHeader = index
                }
                continue
            }
            guard section == "user", let equals = line.firstIndex(of: "=") else { continue }
            if trimmed(line[..<equals]).lowercased() == "default" {
                lastDefault = index
            }
        }
        if let lastDefault {
            lines[lastDefault] = setting
        } else if let lastHeader {
            lines.insert(setting, at: lastHeader + 1)
        } else {
            if let last = lines.last, !trimmed(last).isEmpty {
                lines.append("")
            }
            lines += ["[user]", setting]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// `text` without leading and trailing spaces and tabs.
private func trimmed(_ text: some StringProtocol) -> String {
    let isBlank: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\r" }
    let start = text.firstIndex { !isBlank($0) } ?? text.endIndex
    let end = text.lastIndex { !isBlank($0) }.map(text.index(after:)) ?? start
    return String(text[start..<end])
}
