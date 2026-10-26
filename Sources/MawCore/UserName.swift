/// The name of the Linux account that `maw --install` creates.
///
/// The rules are Ubuntu's: `adduser` accepts names that match `NAME_REGEX`,
/// `^[a-z][-a-z0-9_]*\$?$`, and `useradd` accepts at most 32 characters. A name that already
/// exists in the image as a user or a group, such as `root` or `sudo`, is refused too, because
/// the new account gets a group of the same name.
public struct UserName: Hashable, Sendable, CustomStringConvertible {
    public static let maximumLength = 32

    public let rawValue: String

    /// Validates `rawValue` against Ubuntu's rules and the image's existing names.
    public init(_ rawValue: String, reservedNames: [String] = []) throws(MawError) {
        if let reason = Self.validationFailure(for: rawValue, reservedNames: reservedNames) {
            throw .invalidUserName(rawValue, reason: reason)
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    private static func validationFailure(for name: String, reservedNames: [String]) -> String? {
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first else {
            return "the name is empty"
        }
        if scalars.count > maximumLength {
            return "it is \(scalars.count) characters long, and the limit is \(maximumLength)"
        }
        guard ("a"..."z").contains(first) else {
            return "it must start with a lowercase letter"
        }
        for (index, scalar) in scalars.enumerated() {
            let isLast = index == scalars.count - 1
            switch scalar {
            case "a"..."z", "0"..."9", "-", "_":
                continue
            case "$" where isLast:
                continue
            case "A"..."Z":
                return "it must not contain uppercase letters"
            default:
                return "the character '\(scalar.escaped(asASCII: true))' is not allowed"
            }
        }
        if reservedNames.contains(name) {
            return "the distribution already has a user or group with that name"
        }
        return nil
    }
}
