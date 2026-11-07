#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// `distros/<name>/distro.json`: what maw records about an installed distribution.
public struct DistroMetadata: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var name: DistroName
    /// The catalog entry it was installed from, and the image's release and SHA-256.
    public var catalogEntry: DistroName
    public var release: String
    public var imageSHA256: String
    public var createdAt: Date
    /// The user that `maw.conf` named at installation. The guest's `/etc/maw.conf` is the
    /// authority; this copy serves lists on the Mac.
    public var defaultUser: String
    /// The disk image's virtual size in bytes.
    public var diskSize: UInt64
    /// The virtual network device's MAC address, fixed so that the guest keeps its address.
    public var macAddress: String
    /// The maw version that installed it.
    public var installedBy: String

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
