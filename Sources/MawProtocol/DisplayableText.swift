/// Text from the guest made safe to show on a terminal or in the console.
public enum DisplayableText {
    /// `text` with every control, format, line or paragraph separator, surrogate, private-use,
    /// and unassigned scalar replaced by `replacement`, so that it cannot move the cursor,
    /// change colors, reorder text, or show as an icon of a font's own; at most `byteLimit`
    /// bytes of UTF-8 are kept, in whole scalars.
    public static func make(_ text: String, replacement: Unicode.Scalar, byteLimit: Int) -> String {
        var result = String.UnicodeScalarView()
        var size = 0
        for scalar in text.unicodeScalars {
            let shown: Unicode.Scalar
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse,
                .unassigned:
                shown = replacement
            default:
                shown = scalar
            }
            size += shown.utf8.count
            guard size <= byteLimit else { break }
            result.append(shown)
        }
        return String(result)
    }
}
