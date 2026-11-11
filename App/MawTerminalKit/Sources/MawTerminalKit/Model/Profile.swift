import Foundation

/// A kind of session that a new tab or pane can start: the default Linux distribution, a named
/// one, or the local login shell.
public struct Profile: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// The user's login shell on this Mac. `shell` is the executable's path.
        case localShell(shell: String)
        /// The distribution that `maw --set-default` chose, resolved by the daemon each time a
        /// session opens.
        case defaultDistribution
        /// The distribution that `name` names, which the daemon looks up without regard to case
        /// when a session opens.
        case distribution(name: String)
    }

    /// Stable across launches, so that settings can name the default profile.
    public var id: String
    public var kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// The identifier of the local shell profile.
    public static let localShellID = "local"

    /// The identifier of the default distribution's profile.
    public static let defaultDistributionID = "default-distribution"

    /// The prefix of a named distribution's identifier, `distribution:<name>`.
    public static let distributionIDPrefix = "distribution:"

    public static let defaultDistribution = Profile(
        id: defaultDistributionID, kind: .defaultDistribution)

    /// The profile of the distribution that `name` names.
    public static func distribution(_ name: String) -> Profile {
        Profile(id: distributionIDPrefix + name, kind: .distribution(name: name))
    }

    /// The name in a `distribution:<name>` identifier, or `nil` if `id` is not one or names
    /// nothing.
    public static func distributionName(in id: String) -> String? {
        guard id.hasPrefix(distributionIDPrefix) else { return nil }
        let name = id.dropFirst(distributionIDPrefix.count)
        return name.isEmpty ? nil : String(name)
    }

    /// The local shell profile for `shell`.
    public static func localShell(_ shell: String) -> Profile {
        Profile(id: localShellID, kind: .localShell(shell: shell))
    }

    /// The short name in tab and pane titles, for example `zsh`. A Linux session's title
    /// becomes the distribution's name once it opens.
    public var name: String {
        switch kind {
        case .localShell(let shell): (shell as NSString).lastPathComponent
        case .defaultDistribution: "linux"
        case .distribution(let name): name
        }
    }

    /// The name in the command palette and the settings, for example `zsh on this mac`.
    public var paletteName: String {
        switch kind {
        case .localShell: "\(name) on this mac"
        case .defaultDistribution: "default distribution"
        case .distribution(let name): name
        }
    }

    /// Whether `id` names this profile: the same identifier, or for a distribution the same
    /// name without regard to case, as the daemon looks names up.
    public func isNamed(by id: String) -> Bool {
        guard case .distribution(let name) = kind, let named = Self.distributionName(in: id) else {
            return id == self.id
        }
        return named.lowercased() == name.lowercased()
    }

    /// The user's login shell from the user database, or `/bin/zsh` if it has none.
    public static func userLoginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }
}
