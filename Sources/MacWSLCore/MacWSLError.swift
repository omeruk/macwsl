import Foundation

/// Errors shared by every MacWSL component.
///
/// Each case carries a user-facing message (`errorDescription`) and, where one exists, a concrete
/// next step (`recoverySuggestion`). Front ends print both; they never print a raw Swift error.
public enum MacWSLError: Error, Equatable, Sendable {
    /// A distribution name failed validation. `reason` explains which rule it broke.
    case invalidDistroName(String, reason: String)
    /// The requested feature exists in the command surface but has no implementation yet.
    case notImplemented(feature: String)
}

extension MacWSLError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDistroName(let name, let reason):
            "'\(name)' is not a valid distribution name: \(reason)."
        case .notImplemented(let feature):
            "\(feature) is not implemented yet"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidDistroName:
            "Use 1 to \(DistroName.maximumLength) letters, digits, '.', '-' or '_', "
                + "starting with a letter or digit (for example 'Ubuntu-24.04')."
        case .notImplemented:
            nil
        }
    }
}

extension MacWSLError: CustomStringConvertible {
    public var description: String {
        errorDescription ?? String(describing: self)
    }
}
