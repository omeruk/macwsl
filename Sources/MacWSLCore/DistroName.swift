/// The name of an installed or installable Linux distribution, such as `Ubuntu-24.04`.
///
/// A valid name is 1 to 64 characters drawn from ASCII letters, digits, `.`, `-` and `_`, and
/// starts with a letter or digit. The first-character rule keeps names from being mistaken for
/// command-line options (`-v`) and from naming special directories (`.`, `..`), since each
/// distribution is stored in a directory of the same name.
///
/// Names are compared exactly; `Ubuntu` and `ubuntu` are different distributions.
public struct DistroName: Hashable, Comparable, Sendable {
    public static let maximumLength = 64

    public let rawValue: String

    public init(_ rawValue: String) throws(MacWSLError) {
        if let reason = Self.validationFailure(for: rawValue) {
            throw .invalidDistroName(rawValue, reason: reason)
        }
        self.rawValue = rawValue
    }

    public static func < (lhs: DistroName, rhs: DistroName) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Returns why `name` is invalid, or `nil` if it is valid.
    private static func validationFailure(for name: String) -> String? {
        guard let first = name.unicodeScalars.first else {
            return "the name is empty"
        }
        let length = name.unicodeScalars.count
        if length > maximumLength {
            return "the name is \(length) characters long, and the limit is \(maximumLength)"
        }
        if !isAlphanumeric(first) {
            return "the name must start with a letter or digit"
        }
        if let bad = name.unicodeScalars.first(where: { !isAllowed($0) }) {
            return "the character '\(bad.escaped(asASCII: true))' is not allowed"
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

extension DistroName: CustomStringConvertible {
    public var description: String { rawValue }
}

extension DistroName: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
