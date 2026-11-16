/// The default user of an imported distribution: the user that its sessions run as when none
/// is given (docs/distributions.md, "What --import configures").
///
/// The candidates are, in order: the user that `-u` names, `[user] default` from the archive's
/// `/etc/maw.conf`, `[user] default` from its `/etc/wsl.conf`, and `root`. A candidate counts
/// only if it passes `UserName`'s rules and is a user in the archive's `/etc/passwd`; `-u` that
/// fails either is an error instead. `root` passes both, so a file or `-u` may name it.
public struct DefaultUserChoice: Equatable, Sendable {
    /// Where the choice came from.
    public enum Source: String, Codable, Equatable, Sendable {
        /// `maw --import -u <user>`.
        case option
        /// `[user] default` in the archive's `/etc/maw.conf`.
        case mawConf
        /// `[user] default` in the archive's `/etc/wsl.conf`.
        case wslConf
        /// Nothing named a user, so sessions run as `root`, as after `wsl.exe --import`.
        case fallback
    }

    /// The user that sessions run as when none is given.
    public static let fallbackUser = "root"
    /// How `userNotFound` names the place where `-u`'s user is missing.
    public static let archiveDescription = "the archive"

    public let user: String
    public let source: Source

    public init(user: String, source: Source) {
        self.user = user
        self.source = source
    }

    /// Chooses the default user. `mawConf` and `wslConf` are the files' text, or `nil` where
    /// the archive has no such file; `passwd` is the text of its `/etc/passwd`.
    ///
    /// Throws `invalidUserName` if `option` fails `UserName`'s rules, and `userNotFound` if it
    /// names no user in `passwd`.
    public static func choose(
        option: String?, mawConf: String?, wslConf: String?, passwd: String
    ) throws(MawError) -> DefaultUserChoice {
        let users = Self.users(inPasswd: passwd)
        if let option {
            let name = try UserName(option)
            guard users.contains(name.rawValue) else {
                throw .userNotFound(name.rawValue, distribution: archiveDescription)
            }
            return DefaultUserChoice(user: name.rawValue, source: .option)
        }
        let files: [(String?, Source)] = [(mawConf, .mawConf), (wslConf, .wslConf)]
        for case (let text?, let source) in files {
            if let named = MawConf(parsing: text).defaultUser,
                (try? UserName(named)) != nil, users.contains(named)
            {
                return DefaultUserChoice(user: named, source: source)
            }
        }
        return DefaultUserChoice(user: fallbackUser, source: .fallback)
    }

    /// The user names in the text of an `/etc/passwd`: the first field of every line that has
    /// the file's seven fields. NIS lines, which start with `+` or `-`, name no local user.
    public static func users(inPasswd text: String) -> Set<String> {
        var users: Set<String> = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 7, let name = fields.first, !name.isEmpty,
                !name.hasPrefix("+"), !name.hasPrefix("-")
            else { continue }
            users.insert(String(name))
        }
        return users
    }

    /// Whether the user lingers, so that a login shell does not wait for the user manager to
    /// start. Every default user lingers except `root`, as at installation, where the new user
    /// lingers and `root` does not.
    public var lingers: Bool {
        user != Self.fallbackUser
    }
}
