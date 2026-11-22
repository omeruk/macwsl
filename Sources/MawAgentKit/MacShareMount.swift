import CMawSystem
import MawCore
import MawProtocol

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Mounts the owner's home directory at `/mnt/mac` in a distribution, from the initramfs,
/// before `switch_root` (docs/decisions/0021-mac-share.md). `/init` runs it as
/// `maw-agent mount-mac-share <root> <tag>` when the kernel command line carries
/// `maw.share=<tag>`.
///
/// The root file system may come from an archive that someone else made (`maw --import`), so
/// nothing here follows a link out of it:
///
/// - `/etc/maw.conf` and `/etc/passwd` are resolved inside the root (`InRootFile`): an absolute
///   link starts again at the root, and `..` stops there, as in the imported system itself.
///   Only regular files of at most `fileLimit` bytes are read.
/// - Each component of the mount point, `/mnt` and `/mnt/mac`, is examined without following
///   links and opened with `O_NOFOLLOW`. A link, another kind of file, or a directory that is
///   not empty means no mount. The mount is made on the opened directory itself.
///
/// A failure never stops the boot: the result is a line on the console, and the agent later
/// reports from `/proc/self/mountinfo` whether the share is mounted.
public enum MacShareMount {
    /// The largest `/etc/maw.conf` and `/etc/passwd` read, as the import reads them.
    static let fileLimit = 4 << 20

    /// The owner and group that every file of the share shows: the default user's, or root's.
    struct Owner: Equatable, Sendable {
        var user: String
        var uid: UInt32
        var gid: UInt32
        /// Why root was chosen, when it was chosen because the default user could not be
        /// resolved, or `nil`.
        var fallbackReason: String?

        static func root(because reason: String?) -> Owner {
            Owner(user: "root", uid: 0, gid: 0, fallbackReason: reason)
        }

        /// The kernel's mount data for the patched virtiofs (Guest/kernel/patches).
        var mountOptions: String { "uid=\(uid),gid=\(gid)" }
    }

    /// Mounts `tag` at `/mnt/mac` under `root`, and returns whether it did and the lines for
    /// the console.
    public static func mount(root: String, tag: String) -> (mounted: Bool, lines: [String]) {
        run(root: root, tag: tag)
    }

    /// `mount(root:tag:)`, with the mount call given: it mounts on an open directory and returns
    /// 0 or an errno value. Tests pass a fake.
    static func run(
        root: String, tag: String,
        mount: (_ tag: String, _ directory: Int32, _ options: String) -> Int32 = {
            maw_mount_virtiofs($0, $1, $2)
        }
    ) -> (mounted: Bool, lines: [String]) {
        let prefix = "maw-initramfs: \(MacShare.linuxPath)"
        guard tag == MacShare.tag else {
            return (false, ["\(prefix) is not mounted: the share \(printable(tag)) is unknown"])
        }
        var rootDescriptor: Int32 = -1
        let error = maw_openat(AT_FDCWD, root, O_RDONLY | O_DIRECTORY | O_CLOEXEC, &rootDescriptor)
        guard error == 0 else {
            let reason = "\(printable(root)) cannot be opened (\(describe(error)))"
            return (false, ["\(prefix) is not mounted: \(reason)"])
        }
        let rootDirectory = OwnedDescriptor(rootDescriptor)
        defer { rootDirectory.close() }

        var lines: [String] = []
        let owner = Self.owner(inRoot: rootDirectory.rawValue)
        if let reason = owner.fallbackReason {
            lines.append("\(prefix): files show as root's, because \(reason)")
        }
        let directory: OwnedDescriptor
        switch MountPoint.prepare(inRoot: rootDirectory.rawValue) {
        case .success(let prepared):
            directory = prepared
        case .failure(let refusal):
            lines.append("\(prefix) is not mounted: \(refusal.reason)")
            return (false, lines)
        }
        defer { directory.close() }
        let result = mount(tag, directory.rawValue, owner.mountOptions)
        guard result == 0 else {
            lines.append(
                "\(prefix) is not mounted: mounting the share \(tag) failed (\(describe(result)))")
            return (false, lines)
        }
        lines.append(
            "\(prefix): mounted the share \(tag); files show as \(printable(owner.user))'s"
                + " (uid \(owner.uid), gid \(owner.gid))")
        return (true, lines)
    }

    /// The default user from `/etc/maw.conf`, with its uid and gid from `/etc/passwd`, both
    /// resolved inside the root; root if `/etc/maw.conf` names no user, as sessions then run as
    /// root, and root with the reason if the user cannot be resolved.
    static func owner(inRoot root: Int32) -> Owner {
        let configuration: String
        switch InRootFile.contents(of: "/etc/maw.conf", inRoot: root, limit: fileLimit) {
        case .success(let text):
            configuration = text
        case .failure(.missing):
            return .root(because: nil)
        case .failure(let failure):
            return .root(because: "/etc/maw.conf \(failure.description)")
        }
        guard let name = MawConf(parsing: configuration).defaultUser else {
            return .root(because: nil)
        }
        if name == "root" {
            return .root(because: nil)
        }
        let passwd: String
        switch InRootFile.contents(of: "/etc/passwd", inRoot: root, limit: fileLimit) {
        case .success(let text):
            passwd = text
        case .failure(let failure):
            return .root(because: "/etc/passwd \(failure.description)")
        }
        guard let account = UserDatabase.account(named: name, passwd: passwd, group: "") else {
            return .root(
                because:
                    "the default user \(printable(name)) of /etc/maw.conf is not in /etc/passwd")
        }
        // (uid_t)-1 means "no change" to the kernel, which refuses it as an owner option.
        guard account.uid != UInt32.max, account.gid != UInt32.max else {
            return .root(
                because:
                    "the default user \(printable(name)) has the uid or gid \(UInt32.max),"
                    + " which the kernel refuses")
        }
        return Owner(user: name, uid: account.uid, gid: account.gid, fallbackReason: nil)
    }

    /// Text from the distribution, made safe for the console (`DisplayableText`): unsafe
    /// characters become `?`, and at most 64 bytes are kept.
    static func printable(_ text: String) -> String {
        DisplayableText.make(text, replacement: "?", byteLimit: 64)
    }

    static func describe(_ error: Int32) -> String {
        String(cString: strerror(error))
    }
}

/// What `fdopendir` returns: a pointer to `DIR` on Darwin, an opaque pointer on Linux.
#if canImport(Darwin)
    typealias DirectoryStream = UnsafeMutablePointer<DIR>
#else
    typealias DirectoryStream = OpaquePointer
#endif

/// `/mnt` and `/mnt/mac` under the root, examined and opened without following links.
enum MountPoint {
    /// Why `/mnt` or `/mnt/mac` cannot be the mount point. `errorDescription` is the reason
    /// that the console line gives.
    enum Refusal: LocalizedError, Equatable {
        case cannotExamine(path: String, error: Int32)
        case cannotCreate(path: String, error: Int32)
        case symbolicLink(path: String)
        case notADirectory(path: String)
        case cannotOpen(path: String, error: Int32)
        case notEmpty
        case cannotRead(error: Int32)

        var reason: String {
            switch self {
            case .cannotExamine(let path, let error):
                "\(path) cannot be examined (\(MacShareMount.describe(error)))"
            case .cannotCreate(let path, let error):
                "\(path) cannot be created (\(MacShareMount.describe(error)))"
            case .symbolicLink(let path):
                "\(path) is a symbolic link"
            case .notADirectory(let path):
                "\(path) is not a directory"
            case .cannotOpen(let path, let error):
                "\(path) cannot be opened (\(MacShareMount.describe(error)))"
            case .notEmpty:
                "\(MacShare.linuxPath) is not empty"
            case .cannotRead(let error):
                "\(MacShare.linuxPath) cannot be read (\(MacShareMount.describe(error)))"
            }
        }

        var errorDescription: String? { reason }

        var recoverySuggestion: String? {
            "Move what is at \(MacShare.linuxPath) away, or replace it with an empty directory,"
                + " and start the distribution again."
        }
    }

    /// Opens `/mnt/mac` under `root`, creating `/mnt` and `/mnt/mac` with mode 755 where they
    /// do not exist, and refuses a component that is a link or not a directory, and a
    /// `/mnt/mac` that is not empty.
    static func prepare(inRoot root: Int32) -> Result<OwnedDescriptor, Refusal> {
        let parent: OwnedDescriptor
        switch component("mnt", path: "/mnt", in: root) {
        case .success(let directory): parent = directory
        case .failure(let refusal): return .failure(refusal)
        }
        defer { parent.close() }
        let mountPoint: OwnedDescriptor
        switch component("mac", path: MacShare.linuxPath, in: parent.rawValue) {
        case .success(let directory): mountPoint = directory
        case .failure(let refusal): return .failure(refusal)
        }
        switch isEmpty(mountPoint.rawValue) {
        case .success(true):
            return .success(mountPoint)
        case .success(false):
            mountPoint.close()
            return .failure(.notEmpty)
        case .failure(let refusal):
            mountPoint.close()
            return .failure(refusal)
        }
    }

    /// Opens the directory `name` in `parent`, after creating it if it does not exist.
    private static func component(
        _ name: String, path: String, in parent: Int32
    ) -> Result<OwnedDescriptor, Refusal> {
        var status = stat()
        if fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            let error = errno
            guard error == ENOENT else {
                return .failure(.cannotExamine(path: path, error: error))
            }
            if mkdirat(parent, name, 0o755) != 0 && errno != EEXIST {
                return .failure(.cannotCreate(path: path, error: errno))
            }
            if fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
                return .failure(.cannotExamine(path: path, error: errno))
            }
        }
        switch status.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR):
            break
        case mode_t(S_IFLNK):
            return .failure(.symbolicLink(path: path))
        default:
            return .failure(.notADirectory(path: path))
        }
        var descriptor: Int32 = -1
        let error = maw_openat(
            parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, &descriptor)
        guard error == 0 else {
            return .failure(.cannotOpen(path: path, error: error))
        }
        return .success(OwnedDescriptor(descriptor))
    }

    /// Whether the directory has no entries but `.` and `..`, read through a duplicate of the
    /// descriptor, which `closedir` closes. `readdir` returns `NULL` both at the end and on an
    /// error, which only `errno` tells apart, so `errno` is cleared before each call.
    static func isEmpty(
        _ directory: Int32,
        readEntry: (DirectoryStream) -> UnsafeMutablePointer<dirent>? = { readdir($0) }
    ) -> Result<Bool, Refusal> {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { return .failure(.cannotRead(error: errno)) }
        guard let stream = fdopendir(duplicate) else {
            let error = errno
            close(duplicate)
            return .failure(.cannotRead(error: error))
        }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readEntry(stream) else {
                let error = errno
                return error == 0 ? .success(true) : .failure(.cannotRead(error: error))
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name != "." && name != ".." {
                return .success(false)
            }
        }
    }
}

/// Reads a file of a root file system with every link resolved inside that root, as the
/// system that the root belongs to would resolve it: an absolute link starts again at the
/// root, and `..` never leaves it. Only a regular file is read.
enum InRootFile {
    /// The most links followed for one path, as Linux allows (`MAXSYMLINKS`).
    static let linkLimit = 40

    enum Failure: LocalizedError, Equatable, CustomStringConvertible {
        case missing
        case tooManyLinks
        case notADirectory(String)
        case notARegularFile
        case tooLarge(Int)
        case failed(String, Int32)

        var description: String {
            switch self {
            case .missing:
                return "does not exist"
            case .tooManyLinks:
                return "cannot be followed: more than \(InRootFile.linkLimit) links"
            case .notADirectory(let component):
                return
                    "cannot be followed: \(MacShareMount.printable(component)) is not a directory"
            case .notARegularFile:
                return "is not a regular file"
            case .tooLarge(let limit):
                return "is larger than \(limit) bytes"
            case .failed(let operation, let error):
                return "cannot be read: \(operation) failed (\(MacShareMount.describe(error)))"
            }
        }

        var errorDescription: String? { description }

        var recoverySuggestion: String? {
            "Check the file in the distribution: it must be a regular file of at most"
                + " \(MacShareMount.fileLimit) bytes, reached through at most"
                + " \(InRootFile.linkLimit) links that stay inside the root file system."
        }
    }

    /// The text of `path`, an absolute path inside the root that `root` refers to.
    static func contents(of path: String, inRoot root: Int32, limit: Int) -> Result<String, Failure>
    {
        // The components still to walk, the next one last.
        var pending = Array(components(of: path).reversed())
        // The directories entered so far below the root; the current one is the last.
        var entered: [OwnedDescriptor] = []
        defer {
            for directory in entered { directory.close() }
        }
        var links = 0
        while let name = pending.popLast() {
            if name == "." { continue }
            if name == ".." {
                entered.popLast()?.close()
                continue
            }
            let directory = entered.last?.rawValue ?? root
            var status = stat()
            guard fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                let error = errno
                return .failure(error == ENOENT ? .missing : .failed("fstatat", error))
            }
            switch status.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFLNK):
                links += 1
                guard links <= linkLimit else { return .failure(.tooManyLinks) }
                guard let target = readLink(name, in: directory) else {
                    return .failure(.failed("readlinkat", errno))
                }
                if target.hasPrefix("/") {
                    for directory in entered { directory.close() }
                    entered.removeAll()
                }
                pending.append(contentsOf: components(of: target).reversed())
            case mode_t(S_IFDIR) where !pending.isEmpty:
                var descriptor: Int32 = -1
                let error = maw_openat(
                    directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, &descriptor)
                guard error == 0 else { return .failure(.failed("openat", error)) }
                entered.append(OwnedDescriptor(descriptor))
            case _ where !pending.isEmpty:
                return .failure(.notADirectory(name))
            case mode_t(S_IFREG):
                return readRegularFile(name, in: directory, limit: limit)
            default:
                return .failure(.notARegularFile)
            }
        }
        // The path ended in the root itself or in `..`: a directory.
        return .failure(.notARegularFile)
    }

    private static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func readLink(_ name: String, in directory: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlinkat(directory, name, &buffer, buffer.count - 1)
        guard count >= 0 else { return nil }
        return String(decoding: buffer[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func readRegularFile(
        _ name: String, in directory: Int32, limit: Int
    ) -> Result<String, Failure> {
        var raw: Int32 = -1
        let error = maw_openat(
            directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC, &raw)
        guard error == 0 else { return .failure(.failed("openat", error)) }
        let file = OwnedDescriptor(raw)
        defer { file.close() }
        var status = stat()
        guard fstat(file.rawValue, &status) == 0 else { return .failure(.failed("fstat", errno)) }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            return .failure(.notARegularFile)
        }
        guard status.st_size <= off_t(limit) else { return .failure(.tooLarge(limit)) }
        switch readAll(file.rawValue, limit: limit) {
        case .bytes(let bytes): return .success(String(decoding: bytes, as: UTF8.self))
        case .tooLarge: return .failure(.tooLarge(limit))
        case .failed(let error): return .failure(.failed("read", error))
        }
    }
}

/// Whether `/proc/self/mountinfo` shows the share at `/mnt/mac`: the last mount at that point,
/// the one that processes see, has type `virtiofs` and the share's tag as its source. Reading
/// the table looks nothing up in the share, so no user becomes the first to look at it.
public enum MountTable {
    public static func showsMacShare(mountinfo: String) -> Bool {
        var visible: (type: Substring, source: Substring)?
        for line in mountinfo.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count >= 10, fields[4] == MacShare.linuxPath[...],
                let separator = fields.firstIndex(of: "-"), separator + 2 < fields.count
            else { continue }
            visible = (fields[separator + 1], fields[separator + 2])
        }
        return visible?.type == "virtiofs" && visible?.source == MacShare.tag[...]
    }
}
