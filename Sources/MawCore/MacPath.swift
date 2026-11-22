/// Translates paths between the Mac and a distribution, whose `/mnt/mac` is the owner's home
/// directory (docs/decisions/0021-mac-share.md). `maw` translates its working directory with
/// it, and `mawpath` translates in the guest.
///
/// The translation is textual: `.` and `..` are resolved first, and the path need not exist.
/// Names pass through unchanged, spaces and non-ASCII letters included. A path is under the
/// home directory only at a component boundary: `/Users/alice2` is not under `/Users/alice`.
public struct MacPath: Equatable, Sendable {
    /// The Mac home directory, absolute and normalized, never `/`.
    public let home: String

    /// `nil` unless `home` is an absolute path other than `/`.
    public init?(home: String) {
        guard home.hasPrefix("/") else { return nil }
        let normalized = Self.normalized(home)
        guard normalized != "/" else { return nil }
        self.home = normalized
    }

    /// The Linux path of `macPath`, an absolute Mac path, or `nil` if it is not under the home
    /// directory.
    public func linuxPath(forMac macPath: String) -> String? {
        guard macPath.hasPrefix("/"),
            let rest = Self.remainder(of: Self.normalized(macPath), under: home)
        else { return nil }
        return rest.isEmpty ? MacShare.linuxPath : MacShare.linuxPath + rest
    }

    /// The Mac path of `linuxPath`, an absolute Linux path, or `nil` if it is not under
    /// `/mnt/mac`.
    public func macPath(forLinux linuxPath: String) -> String? {
        guard linuxPath.hasPrefix("/"),
            let rest = Self.remainder(of: Self.normalized(linuxPath), under: MacShare.linuxPath)
        else { return nil }
        return home + rest
    }

    /// What follows `prefix` in `path`, both normalized: `""` for the prefix itself, `/<rest>`
    /// for a path under it, and `nil` otherwise.
    static func remainder(of path: String, under prefix: String) -> String? {
        if path == prefix { return "" }
        guard path.hasPrefix(prefix + "/") else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// `path` with empty components and `.` removed and each `..` applied to the component
    /// before it, without looking at the file system. An absolute path stays absolute, and `..`
    /// stops at `/`; a relative path stays relative and keeps the `..` it cannot apply. A
    /// trailing slash is dropped. The empty path and `.` give `.`.
    public static func normalized(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else if !isAbsolute {
                    components.append(component)
                }
            default:
                components.append(component)
            }
        }
        let joined = components.joined(separator: "/")
        if isAbsolute { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }

    /// `path` made absolute against `directory`, an absolute path, and normalized.
    public static func absolute(_ path: String, in directory: String) -> String {
        normalized(path.hasPrefix("/") ? path : directory + "/" + path)
    }
}
