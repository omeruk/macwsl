#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A daemon's launchd label, such as `dev.maw.mawd`, checked so that it names exactly one
/// directory entry: it names the daemon's own staging directory (`MawPaths.stagingDirectory`).
///
/// A valid label is 1 to 128 characters drawn from ASCII letters, digits, `.`, `-` and `_`,
/// starts with a letter or digit, and contains no `..`. It therefore can never be empty, be `.`
/// or `..`, contain `/`, or start with `-`. Labels are compared exactly.
public struct DaemonLabel: Hashable, Sendable, CustomStringConvertible {
    public static let maximumLength = 128

    /// Why a label was refused.
    public struct Invalid: Error, Equatable, LocalizedError {
        public let label: String
        public let reason: String

        public init(label: String, reason: String) {
            self.label = label
            self.reason = reason
        }

        public var errorDescription: String? {
            let shown = label.unicodeScalars.map { $0.escaped(asASCII: true) }.joined()
            return "The daemon label '\(shown)' is not valid: \(reason)."
        }

        public var recoverySuggestion: String? {
            "Use a reverse-DNS label of letters, digits, '.', '-' and '_', such as dev.maw.mawd."
        }
    }

    public let rawValue: String

    public init(_ rawValue: String) throws(Invalid) {
        if let reason = Self.validationFailure(for: rawValue) {
            throw Invalid(label: rawValue, reason: reason)
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// Returns why `label` is invalid, or `nil` if it is valid.
    private static func validationFailure(for label: String) -> String? {
        guard let first = label.unicodeScalars.first else {
            return "the label is empty"
        }
        let length = label.unicodeScalars.count
        if length > maximumLength {
            return "the label is \(length) characters long, and the limit is \(maximumLength)"
        }
        if !isAlphanumeric(first) {
            return "the label must start with a letter or digit"
        }
        if let bad = label.unicodeScalars.first(where: { !isAllowed($0) }) {
            return "the character '\(bad.escaped(asASCII: true))' is not allowed"
        }
        if label.contains("..") {
            return "the label must not contain '..'"
        }
        return nil
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9": true
        default: false
        }
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        isAlphanumeric(scalar) || scalar == "." || scalar == "-" || scalar == "_"
    }
}
