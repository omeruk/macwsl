/// A user account from the guest's `/etc/passwd`, with its groups from `/etc/group`.
struct Account: Equatable, Sendable {
    var name: String
    var uid: UInt32
    var gid: UInt32
    var home: String
    var shell: String
    /// The primary group followed by every group that lists the user as a member, as
    /// `initgroups(3)` computes them.
    var groups: [UInt32]
}

/// Reads accounts from the text of `/etc/passwd` and `/etc/group`.
///
/// The agent reads the files itself instead of calling `getpwnam(3)`: it is linked against musl,
/// whose lookups would read the same files anyway, and it must compute the groups before
/// `fork`, because only async-signal-safe calls may run between `fork` and `exec`.
enum UserDatabase {
    /// The shell used when the account names none, as `login(1)` does.
    static let defaultShell = "/bin/sh"

    static func account(named name: String, passwd: String, group: String) -> Account? {
        for line in passwd.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count >= 7, fields[0] == name,
                let uid = UInt32(fields[2]), let gid = UInt32(fields[3])
            else {
                continue
            }
            let shell = fields[6].isEmpty ? defaultShell : String(fields[6])
            return Account(
                name: name, uid: uid, gid: gid, home: String(fields[5]), shell: shell,
                groups: groups(of: name, primary: gid, group: group))
        }
        return nil
    }

    /// The ID of the group `name`, such as `tty`, or `nil` if it does not exist.
    static func groupID(named name: String, group: String) -> UInt32? {
        for line in group.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            if fields.count >= 3, fields[0] == name, let gid = UInt32(fields[2]) {
                return gid
            }
        }
        return nil
    }

    static func groups(of name: String, primary: UInt32, group: String) -> [UInt32] {
        var groups = [primary]
        for line in group.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count >= 4, let gid = UInt32(fields[2]) else { continue }
            let members = fields[3].split(separator: ",").map { $0.trimmingWhitespace() }
            if members.contains(where: { $0 == name }), !groups.contains(gid) {
                groups.append(gid)
            }
        }
        return groups
    }
}

/// The `PATH` that `/etc/login.defs` gives login sessions: `ENV_SUPATH` for root and `ENV_PATH`
/// for everyone else, as `su -l` and `runuser -l` apply them.
enum LoginDefinitions {
    static let defaultRootPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    static let defaultUserPath = "/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games"

    static func path(forRoot isRoot: Bool, loginDefs: String?) -> String {
        let key = isRoot ? "ENV_SUPATH" : "ENV_PATH"
        for line in (loginDefs ?? "").split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == key else { continue }
            let value = fields[1]
            return value.hasPrefix("PATH=") ? String(value.dropFirst(5)) : String(value)
        }
        return isRoot ? defaultRootPath : defaultUserPath
    }
}

extension Substring {
    fileprivate func trimmingWhitespace() -> Substring {
        let start = firstIndex { $0 != " " && $0 != "\t" } ?? endIndex
        let end = lastIndex { $0 != " " && $0 != "\t" }.map(index(after:)) ?? start
        return self[start..<end]
    }
}
