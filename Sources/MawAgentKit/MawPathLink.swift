import CMawSystem
import MawCore
import MawProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// The link `/usr/local/bin/mawpath` → `/run/maw/maw-agent`, which puts `mawpath` on every
/// session's PATH, as WSL links `/usr/bin/wslpath` to `/init`. The agent makes it when it
/// starts in a distribution, before it serves a session; it is the one file that maw adds to
/// a distribution's disk for `mawpath`, and it dangles while the distribution does not run.
///
/// `/usr`, `/usr/local`, and `/usr/local/bin` must be directories, not links: each is examined
/// without following links and opened with `O_NOFOLLOW`, and the link is made in the opened
/// directory. An existing `mawpath` that is not this link is left as it is.
public enum MawPathLink {
    public static let directory = SessionPlanner.mawpathDirectory
    public static let target = SessionPlanner.agentPath

    /// What `install` did.
    public enum Outcome: Equatable, Sendable {
        case created
        case alreadyPresent
        /// Nothing was changed, for this reason, which the console shows.
        case refused(String)
    }

    /// Makes the link under `root`, `/` in a distribution.
    public static func install(root: String = "/") -> Outcome {
        var rootDescriptor: Int32 = -1
        let error = maw_openat(AT_FDCWD, root, O_RDONLY | O_DIRECTORY | O_CLOEXEC, &rootDescriptor)
        guard error == 0 else {
            return .refused("\(root) cannot be opened (\(describe(error)))")
        }
        var current = OwnedDescriptor(rootDescriptor)
        defer { current.close() }
        var path = ""
        for component in directory.split(separator: "/").map(String.init) {
            path += "/" + component
            var status = stat()
            guard fstatat(current.rawValue, component, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                let error = errno
                return .refused(
                    error == ENOENT
                        ? "\(path) does not exist"
                        : "\(path) cannot be examined (\(describe(error)))")
            }
            switch status.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR): break
            case mode_t(S_IFLNK): return .refused("\(path) is a symbolic link")
            default: return .refused("\(path) is not a directory")
            }
            var next: Int32 = -1
            let error = maw_openat(
                current.rawValue, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, &next)
            guard error == 0 else {
                return .refused("\(path) cannot be opened (\(describe(error)))")
            }
            current.close()
            current = OwnedDescriptor(next)
        }

        let name = MawPathCommand.name
        let linkPath = "\(directory)/\(name)"
        var status = stat()
        if fstatat(current.rawValue, name, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
                readLink(name, in: current.rawValue) == target
            else {
                return .refused("\(linkPath) exists and is not maw's link; it is left as it is")
            }
            return .alreadyPresent
        }
        guard errno == ENOENT else {
            return .refused("\(linkPath) cannot be examined (\(describe(errno)))")
        }
        guard symlinkat(target, current.rawValue, name) == 0 else {
            return .refused("\(linkPath) cannot be created (\(describe(errno)))")
        }
        return .created
    }

    /// The console line for `outcome`, or `nil` when there is nothing to say.
    public static func consoleLine(_ outcome: Outcome) -> String? {
        guard case .refused(let reason) = outcome else { return nil }
        return "maw-agent: mawpath is not on PATH: "
            + DisplayableText.make(reason, replacement: "?", byteLimit: 256)
    }

    private static func readLink(_ name: String, in directory: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlinkat(directory, name, &buffer, buffer.count - 1)
        guard count >= 0 else { return nil }
        return String(decoding: buffer[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func describe(_ error: Int32) -> String {
        String(cString: strerror(error))
    }
}
