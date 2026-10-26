#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Every location maw reads or writes on the host.
///
/// All paths derive from the user's home directory, which tests replace with a temporary
/// directory. Nothing here touches the file system; callers create directories as needed.
public struct MawPaths: Sendable, Equatable {
    /// The home directory every other path is relative to.
    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    /// `~/Library/Application Support/maw`
    public var applicationSupportDirectory: URL {
        homeDirectory.appending(
            path: "Library/Application Support/maw", directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/maw/distros`
    public var distrosDirectory: URL {
        applicationSupportDirectory.appending(path: "distros", directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/maw/distros/<name>`
    public func distroDirectory(for name: DistroName) -> URL {
        distrosDirectory.appending(path: name.rawValue, directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/maw/distros/<name>/disk.img`, the sparse raw ext4 disk.
    public func diskImage(for name: DistroName) -> URL {
        distroDirectory(for: name).appending(path: "disk.img", directoryHint: .notDirectory)
    }

    /// `~/Library/Application Support/maw/distros/<name>/distro.json`, the distro metadata.
    public func metadataFile(for name: DistroName) -> URL {
        distroDirectory(for: name).appending(path: "distro.json", directoryHint: .notDirectory)
    }

    /// `~/Library/Application Support/maw/distros/.staging-<name>-<id>`, where an installation
    /// builds a distribution before it renames the directory to `distroDirectory(for:)`.
    /// Distribution names cannot start with `.`, so it never collides with one.
    public func stagingDirectory(for name: DistroName, id: String) -> URL {
        distrosDirectory.appending(
            path: "\(Self.stagingPrefix)\(name.rawValue)-\(id)", directoryHint: .isDirectory)
    }

    /// The prefix of every staging directory's name.
    public static let stagingPrefix = ".staging-"

    /// `~/Library/Application Support/maw/state.json`, the daemon's settings, such as the
    /// default distribution.
    public var stateFile: URL {
        applicationSupportDirectory.appending(path: "state.json", directoryHint: .notDirectory)
    }

    /// `~/Library/Caches/maw/images`, holding verified distribution images and partial
    /// downloads.
    public var imageCacheDirectory: URL {
        homeDirectory.appending(path: "Library/Caches/maw/images", directoryHint: .isDirectory)
    }

    /// `~/Library/Logs/maw/install-<name>.log`, the console of the machine that provisions the
    /// distribution `name`, with the daemon's notes about it.
    public func installLogFile(for name: DistroName) -> URL {
        logsDirectory.appending(path: "install-\(name.rawValue).log", directoryHint: .notDirectory)
    }

    /// `~/Library/Application Support/maw/kernel`, holding the guest kernel and initramfs.
    public var kernelDirectory: URL {
        applicationSupportDirectory.appending(path: "kernel", directoryHint: .isDirectory)
    }

    /// `~/Library/Logs/maw`, holding daemon and per-VM console logs.
    public var logsDirectory: URL {
        homeDirectory.appending(path: "Library/Logs/maw", directoryHint: .isDirectory)
    }

    /// `~/Library/Logs/maw/mawd.log`, where launchd sends the daemon's output.
    public var daemonLogFile: URL {
        logsDirectory.appending(path: "mawd.log", directoryHint: .notDirectory)
    }

    /// `~/Library/LaunchAgents/<label>.plist`, the daemon's LaunchAgent.
    public func launchAgentFile(label: String) -> URL {
        homeDirectory.appending(
            path: "Library/LaunchAgents/\(label).plist", directoryHint: .notDirectory)
    }

    /// `~/Library/Application Support/maw/<label>.lock`, which the running daemon holds locked,
    /// so that clients can tell whether it runs without connecting (and so starting it).
    public func daemonLockFile(label: String) -> URL {
        applicationSupportDirectory.appending(path: "\(label).lock", directoryHint: .notDirectory)
    }

    /// `~/.mawconfig`, the global settings file.
    public var globalConfigFile: URL {
        homeDirectory.appending(path: ".mawconfig", directoryHint: .notDirectory)
    }
}
