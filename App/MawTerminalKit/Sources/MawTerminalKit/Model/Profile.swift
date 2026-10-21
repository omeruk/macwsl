import Foundation

/// A kind of session that a new tab or pane can start. This phase has one profile, the local
/// login shell. Linux distributions become profiles in a later phase.
public struct Profile: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// The user's login shell on this Mac. `shell` is the executable's path.
        case localShell(shell: String)
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

    /// The local shell profile for `shell`.
    public static func localShell(_ shell: String) -> Profile {
        Profile(id: localShellID, kind: .localShell(shell: shell))
    }

    /// The short name in tab and pane titles, for example `zsh`.
    public var name: String {
        switch kind {
        case .localShell(let shell): (shell as NSString).lastPathComponent
        }
    }

    /// The name in the command palette, for example `zsh on this mac`.
    public var paletteName: String {
        switch kind {
        case .localShell: "\(name) on this mac"
        }
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
