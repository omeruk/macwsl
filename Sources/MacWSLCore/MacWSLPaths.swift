#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Every location MacWSL reads or writes on the host.
///
/// All paths derive from the user's home directory, which tests replace with a temporary
/// directory. Nothing here touches the file system; callers create directories as needed.
public struct MacWSLPaths: Sendable, Equatable {
    /// The home directory every other path is relative to.
    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    /// `~/Library/Application Support/MacWSL`
    public var applicationSupportDirectory: URL {
        homeDirectory.appending(
            path: "Library/Application Support/MacWSL", directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/MacWSL/distros`
    public var distrosDirectory: URL {
        applicationSupportDirectory.appending(path: "distros", directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/MacWSL/distros/<name>`
    public func distroDirectory(for name: DistroName) -> URL {
        distrosDirectory.appending(path: name.rawValue, directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/MacWSL/distros/<name>/disk.img`, the sparse raw ext4 disk.
    public func diskImage(for name: DistroName) -> URL {
        distroDirectory(for: name).appending(path: "disk.img", directoryHint: .notDirectory)
    }

    /// `~/Library/Application Support/MacWSL/distros/<name>/distro.json`, the distro metadata.
    public func metadataFile(for name: DistroName) -> URL {
        distroDirectory(for: name).appending(path: "distro.json", directoryHint: .notDirectory)
    }

    /// `~/Library/Application Support/MacWSL/kernel`, holding the guest kernel and initramfs.
    public var kernelDirectory: URL {
        applicationSupportDirectory.appending(path: "kernel", directoryHint: .isDirectory)
    }

    /// `~/Library/Logs/MacWSL`, holding daemon and per-VM console logs.
    public var logsDirectory: URL {
        homeDirectory.appending(path: "Library/Logs/MacWSL", directoryHint: .isDirectory)
    }

    /// `~/.macwslconfig`, the global settings file.
    public var globalConfigFile: URL {
        homeDirectory.appending(path: ".macwslconfig", directoryHint: .notDirectory)
    }
}
