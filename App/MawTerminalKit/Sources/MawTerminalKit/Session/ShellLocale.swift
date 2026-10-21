import Darwin
import Foundation

/// Chooses the locale variables for a shell, so that it runs with a UTF-8 character type.
///
/// Apps started from the Finder or Xcode inherit no `LANG` from launchd, and the obvious
/// candidate built from the user's language and region often does not exist: English with the
/// region Turkey gives `en_TR.UTF-8`, which macOS does not have. A shell given a locale that
/// does not exist falls back to the C locale, and its line editor then treats each byte of a
/// multibyte character as a character of its own.
public enum ShellLocale {
    /// The variables that decide the character type, in the order of precedence POSIX gives.
    static let characterTypeVariables = ["LC_ALL", "LC_CTYPE", "LANG"]

    /// The environment with its locale variables corrected.
    ///
    /// - An inherited `LC_ALL`, `LC_CTYPE`, or `LANG` that names a valid locale is kept
    ///   unchanged, even if it is not UTF-8: that is the user's choice.
    /// - An inherited `LC_ALL` or `LC_CTYPE` that names no valid locale is removed, because it
    ///   would otherwise override `LANG`.
    /// - If no valid variable remains, `LANG` is set to the first valid candidate from
    ///   `candidates(for:)`. If none is valid, the environment is returned without those
    ///   variables, and the shell uses the C locale.
    public static func environment(
        _ environment: [String: String], locale: Locale,
        isValid: (String) -> Bool = isValidCharacterType
    ) -> [String: String] {
        var environment = environment
        for name in ["LC_ALL", "LC_CTYPE"] {
            if let value = environment[name], !value.isEmpty, !isValid(value) {
                environment[name] = nil
            }
        }
        let effective = characterTypeVariables.lazy
            .compactMap { environment[$0] }
            .first { !$0.isEmpty }
        if let effective, isValid(effective) {
            return environment
        }
        environment["LANG"] = candidates(for: locale).first(where: isValid)
        return environment
    }

    /// The locales to try, best first: the language with the user's region, the language with
    /// its own country (`tr_TR` for Turkish), and `en_US`, all in UTF-8.
    public static func candidates(for locale: Locale) -> [String] {
        var candidates: [String] = []
        if let language = locale.language.languageCode?.identifier, language.count == 2 {
            if let region = locale.region?.identifier, region.count == 2 {
                candidates.append("\(language)_\(region).UTF-8")
            }
            candidates.append("\(language)_\(language.uppercased()).UTF-8")
        }
        candidates.append("en_US.UTF-8")
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0).inserted }
    }

    /// Whether `name` is a locale that this system can use for the character type, as
    /// `newlocale(3)` decides.
    public static func isValidCharacterType(_ name: String) -> Bool {
        guard let handle = newlocale(LC_CTYPE_MASK, name, nil) else { return false }
        freelocale(handle)
        return true
    }
}
