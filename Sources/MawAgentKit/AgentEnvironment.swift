import MawCore
import MawProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

extension GuestSystem {
    /// The files of the system the agent runs on.
    public static let live: GuestSystem = {
        let locales = LocaleCache()
        return GuestSystem(
            readFile: { path in readTextFile(path) },
            isDirectory: { path in fileType(path) == S_IFDIR },
            isExecutable: { path in fileType(path) == S_IFREG && access(path, X_OK) == 0 },
            exists: { path in fileType(path) != nil },
            availableLocales: { locales.names() },
            initSystem: { InitSystem.detect { fileType($0) == S_IFDIR } },
            currentUserID: UInt32(geteuid()))
    }()
}

/// The locales in `/usr/lib/locale`: the names in `locale-archive`, which `locale-gen`
/// writes, and the directories next to it, such as `C.utf8`. Read again only when the archive
/// changes.
private final class LocaleCache: @unchecked Sendable {
    static let directory = "/usr/lib/locale"
    private let lock = ConditionLock()
    private var archiveStamp: (seconds: Int, nanoseconds: Int, size: Int)?
    private var cached: [String] = []

    func names() -> [String] {
        let archive = Self.directory + "/locale-archive"
        var status = stat()
        var stamp: (Int, Int, Int)?
        if stat(archive, &status) == 0 {
            #if canImport(Darwin)
                let modified = status.st_mtimespec
            #else
                let modified = status.st_mtim
            #endif
            stamp = (Int(modified.tv_sec), Int(modified.tv_nsec), Int(status.st_size))
        }
        return lock.withLock {
            if let stamp, let archiveStamp, stamp == archiveStamp {
                return cached
            }
            var names = directoryEntries(Self.directory).filter { $0 != "locale-archive" }
            if let bytes = readBytes(archive, limit: 256 << 20) {
                names += LocaleArchive.names(in: bytes)
            }
            archiveStamp = stamp
            cached = names
            return names
        }
    }
}

private func fileType(_ path: String) -> mode_t? {
    var status = stat()
    guard stat(path, &status) == 0 else { return nil }
    return status.st_mode & S_IFMT
}

/// A small configuration file's text, or `nil`. Files over 1 MiB are not read.
private func readTextFile(_ path: String) -> String? {
    readBytes(path, limit: 1 << 20).map { String(decoding: $0, as: UTF8.self) }
}

private func readBytes(_ path: String, limit: Int) -> [UInt8]? {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 64 << 10)
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { return nil }
        if count == 0 { return bytes }
        bytes.append(contentsOf: buffer[..<count])
        if bytes.count > limit { return nil }
    }
}

private func directoryEntries(_ path: String) -> [String] {
    guard let directory = opendir(path) else { return [] }
    defer { closedir(directory) }
    var names: [String] = []
    while let entry = readdir(directory) {
        let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        if name != "." && name != ".." {
            names.append(name)
        }
    }
    return names
}

/// Facts about the system the agent runs on, for `info`.
enum SystemInfo {
    /// `uname -r`.
    static func kernelRelease() -> String {
        var names = utsname()
        guard uname(&names) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &names.release) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Time since boot, including time suspended where the platform counts it.
    static func uptimeMilliseconds() -> UInt64 {
        var time = timespec()
        #if os(Linux)
            let clock = CLOCK_BOOTTIME
        #else
            let clock = CLOCK_MONOTONIC
        #endif
        guard clock_gettime(clock, &time) == 0 else { return 0 }
        return UInt64(time.tv_sec) * 1_000 + UInt64(time.tv_nsec) / 1_000_000
    }
}
