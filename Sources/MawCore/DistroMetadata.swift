#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// `distros/<name>/distro.json`: what maw records about an installed distribution.
///
/// Schema 2 records where a distribution came from: a catalog entry and its image, or an
/// archive that `maw --import` read. Schema 1 files, which every distribution installed before
/// schema 2 has, are read unchanged and never rewritten, so that a build that knows only schema
/// 1 keeps reading them. That build also reads a schema 2 file of a catalog installation, which
/// has every key that schema 1 requires, but not one of an import, which has no catalog entry.
public struct DistroMetadata: Codable, Equatable, Sendable {
    /// The schema that this build writes.
    public static let currentSchemaVersion = 2

    /// Where an imported distribution came from.
    public struct ImportOrigin: Codable, Equatable, Sendable {
        /// What `archive` is when the archive came from `maw`'s standard input.
        public static let standardInput = "standard input"

        /// The absolute path of the file that `maw` opened, or `standardInput`. The daemon
        /// only records it; it never opens it.
        public var archive: String

        public init(archive: String) {
            self.archive = archive
        }
    }

    public var schemaVersion: Int
    public var name: DistroName
    /// The catalog entry it was installed from, and the image's release and SHA-256. All three
    /// are present for a distribution installed from the catalog, and absent for an imported
    /// one.
    public var catalogEntry: DistroName?
    public var release: String?
    public var imageSHA256: String?
    /// The archive an imported distribution came from; absent for one from the catalog.
    public var importedFrom: ImportOrigin?
    public var createdAt: Date
    /// The user that `maw.conf` named at installation or import. The guest's `/etc/maw.conf` is
    /// the authority; this copy serves lists on the Mac.
    public var defaultUser: String
    /// The disk image's virtual size in bytes.
    public var diskSize: UInt64
    /// The virtual network device's MAC address, fixed so that the guest keeps its address.
    public var macAddress: String
    /// The maw version that installed or imported it.
    public var installedBy: String

    /// A distribution installed from the catalog.
    public init(
        name: DistroName, catalogEntry: DistroName, release: String, imageSHA256: String,
        createdAt: Date, defaultUser: String, diskSize: UInt64, macAddress: String,
        installedBy: String = MawVersion.current
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.name = name
        self.catalogEntry = catalogEntry
        self.release = release
        self.imageSHA256 = imageSHA256
        importedFrom = nil
        self.createdAt = createdAt
        self.defaultUser = defaultUser
        self.diskSize = diskSize
        self.macAddress = macAddress
        self.installedBy = installedBy
    }

    /// A distribution imported from an archive.
    public init(
        name: DistroName, importedFrom: ImportOrigin, createdAt: Date, defaultUser: String,
        diskSize: UInt64, macAddress: String, installedBy: String = MawVersion.current
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.name = name
        catalogEntry = nil
        release = nil
        imageSHA256 = nil
        self.importedFrom = importedFrom
        self.createdAt = createdAt
        self.defaultUser = defaultUser
        self.diskSize = diskSize
        self.macAddress = macAddress
        self.installedBy = installedBy
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> DistroMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DistroMetadata.self, from: data)
    }
}
