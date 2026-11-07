/// Chooses the locale of a session in the guest.
///
/// The guest uses the Mac's language and region when the distribution has that locale, and
/// `C.UTF-8` otherwise, so that the character type is always UTF-8. Phase 11a found that a
/// locale that does not exist makes line editors treat each byte of a multibyte character as a
/// character of its own, which breaks Turkish input.
public enum GuestLocale {
    /// The locale every glibc distribution has.
    public static let fallback = "C.UTF-8"

    /// The Mac's language and region as a glibc locale name, such as `tr_TR.UTF-8`, or `nil` if
    /// either is missing or not a two-letter code.
    public static func preferred(languageCode: String?, regionCode: String?) -> String? {
        guard let languageCode, let regionCode,
            languageCode.utf8.count == 2, regionCode.utf8.count == 2,
            languageCode.allSatisfy(\.isLetter), regionCode.allSatisfy(\.isLetter)
        else {
            return nil
        }
        return "\(languageCode.lowercased())_\(regionCode.uppercased()).UTF-8"
    }

    /// `preferred` if `available`, the names the distribution lists (as `locale -a` prints
    /// them, such as `tr_TR.utf8`), contains it; otherwise `fallback`.
    public static func choose(preferred: String?, available: some Sequence<String>) -> String {
        guard let preferred else { return fallback }
        let wanted = normalized(preferred)
        return available.contains { normalized($0) == wanted } ? preferred : fallback
    }

    /// The form glibc compares locale names in: the code set in lowercase without punctuation,
    /// so that `tr_TR.UTF-8` and `tr_TR.utf8` are the same locale.
    public static func normalized(_ name: String) -> String {
        guard let dot = name.firstIndex(of: ".") else { return name }
        let codeSet = name[name.index(after: dot)...]
        let modifier = codeSet.firstIndex(of: "@").map { String(codeSet[$0...]) } ?? ""
        let charset = codeSet.prefix { $0 != "@" }.lowercased().filter {
            $0.isLetter || $0.isNumber
        }
        return name[..<dot] + "." + charset + modifier
    }
}
