#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The distributions that maw can install, built into the binary.
///
/// Each entry pins one image by URL, size, and SHA-256. `docs/distributions.md` describes how
/// an image is chosen, and `docs/decisions/0012-ubuntu-image.md` why the SHA-256 is pinned and
/// how the catalog is updated when the distribution publishes a new image.
public struct DistroCatalog: Codable, Equatable, Sendable {
    /// The entry that `maw --install` installs when no name is given.
    public var recommended: DistroName
    public var entries: [CatalogEntry]

    public init(recommended: DistroName, entries: [CatalogEntry]) {
        self.recommended = recommended
        self.entries = entries
    }

    /// The catalog built into this binary.
    public static let builtIn: DistroCatalog = {
        do {
            return try JSONDecoder().decode(DistroCatalog.self, from: Data(catalogJSON.utf8))
        } catch {
            preconditionFailure("The built-in catalog cannot be decoded: \(error)")
        }
    }()

    /// The entry whose name or alias is `name`, ignoring case, as `wsl --install` does.
    public func entry(named name: String) -> CatalogEntry? {
        let wanted = name.lowercased()
        return entries.first { entry in
            ([entry.name] + entry.aliases).contains { $0.rawValue.lowercased() == wanted }
        }
    }

    /// The recommended entry. `validate()` guarantees that it exists.
    public var recommendedEntry: CatalogEntry {
        guard let entry = entry(named: recommended.rawValue) else {
            preconditionFailure("The catalog's recommended entry \(recommended) does not exist.")
        }
        return entry
    }

    /// Problems that would make the catalog unusable or unsafe, as sentences; empty if none.
    public func problems() -> [String] {
        var problems: [String] = []
        if entry(named: recommended.rawValue) == nil {
            problems.append("The recommended entry \(recommended) does not exist.")
        }
        var seen: Set<String> = []
        for entry in entries {
            for name in [entry.name] + entry.aliases
            where !seen.insert(name.rawValue.lowercased()).inserted {
                problems.append("The name \(name) is used more than once.")
            }
            problems.append(contentsOf: entry.image.problems().map { "\(entry.name): \($0)" })
        }
        return problems
    }
}

/// One installable distribution.
public struct CatalogEntry: Codable, Equatable, Sendable {
    /// The name the distribution is installed under, such as `Ubuntu-24.04`.
    public var name: DistroName
    /// Other names that select this entry, such as `Ubuntu` for the current LTS release.
    public var aliases: [DistroName]
    /// The name shown in lists, such as `Ubuntu 24.04 LTS`.
    public var displayName: String
    /// The image's release or build, such as `24.04.5`, recorded in `distro.json`.
    public var release: String
    public var image: CatalogImage
    /// User and group names that exist in the image. A new user cannot take one of them.
    public var reservedNames: [String]

    public init(
        name: DistroName, aliases: [DistroName], displayName: String, release: String,
        image: CatalogImage, reservedNames: [String]
    ) {
        self.name = name
        self.aliases = aliases
        self.displayName = displayName
        self.release = release
        self.image = image
        self.reservedNames = reservedNames
    }
}

/// A root file system archive, pinned by its SHA-256.
public struct CatalogImage: Codable, Equatable, Sendable {
    public enum Format: String, Codable, Sendable {
        /// A gzip-compressed tar archive, such as Ubuntu's `.wsl` images.
        case tarGzip = "tar.gz"
    }

    public var url: URL
    public var format: Format
    /// The size of the download in bytes.
    public var size: UInt64
    /// The SHA-256 of the download, 64 lowercase hexadecimal digits.
    public var sha256: String
    /// The space the extracted root file system occupies on its disk, measured when the image
    /// was pinned. The free-space check before an install uses it.
    public var installedSize: UInt64

    public init(url: URL, format: Format, size: UInt64, sha256: String, installedSize: UInt64) {
        self.url = url
        self.format = format
        self.size = size
        self.sha256 = sha256
        self.installedSize = installedSize
    }

    /// The file name the verified image has in the cache: its SHA-256, so that a changed image
    /// never matches an old file.
    public var cacheFileName: String { "\(sha256).\(format.rawValue)" }

    func problems() -> [String] {
        var problems: [String] = []
        if url.scheme != "https" {
            problems.append("The image URL \(url) does not use HTTPS.")
        }
        if !Self.isSHA256(sha256) {
            problems.append("'\(sha256)' is not a SHA-256 in lowercase hexadecimal.")
        }
        if size == 0 || installedSize == 0 {
            problems.append("The image's sizes must not be zero.")
        }
        return problems
    }

    static func isSHA256(_ text: String) -> Bool {
        text.utf8.count == 64
            && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
