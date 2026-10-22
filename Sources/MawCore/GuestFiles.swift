#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The kernel, initramfs, and manifest in a kernel directory, as scripts/fetch-guest.sh
/// installs them.
public struct GuestFiles: Sendable {
    /// The parts of `manifest.json` that maw reports.
    public struct Manifest: Decodable, Equatable, Sendable {
        public struct Kernel: Decodable, Equatable, Sendable {
            public var release: String
        }
        public var guestVersion: String
        public var gitCommit: String
        public var kernel: Kernel
    }

    public let kernelURL: URL
    public let initramfsURL: URL
    /// `nil` if `manifest.json` exists but cannot be read.
    public let manifest: Manifest?

    /// Throws `kernelNotFound` if a file is missing.
    public init(directory: URL) throws(MawError) {
        for file in ["Image", "initramfs.cpio.gz", "manifest.json"] {
            let path = directory.appending(path: file).path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: path) else {
                throw .kernelNotFound(path: path)
            }
        }
        kernelURL = directory.appending(path: "Image")
        initramfsURL = directory.appending(path: "initramfs.cpio.gz")
        manifest = try? JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
    }

    /// For example `kernel 6.18.57-maw, guest 2026.10.21, commit 0123456789ab`.
    public var summary: String {
        guard let manifest else {
            return "kernel: manifest.json could not be read"
        }
        return "kernel \(manifest.kernel.release), guest \(manifest.guestVersion), "
            + "commit \(manifest.gitCommit.prefix(12))"
    }
}
