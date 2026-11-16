import Foundation
import MawCore
import Testing

@Suite struct DistroMetadataTests {
    static let created = Date(timeIntervalSince1970: 1_792_685_873)

    static func catalogMetadata() throws -> DistroMetadata {
        DistroMetadata(
            name: try DistroName("Ubuntu-24.04"), catalogEntry: try DistroName("Ubuntu-24.04"),
            release: "24.04.5", imageSHA256: String(repeating: "a", count: 64),
            createdAt: created, defaultUser: "ayse", diskSize: 256 << 30,
            macAddress: "02:00:00:12:34:56")
    }

    static func importedMetadata() throws -> DistroMetadata {
        DistroMetadata(
            name: try DistroName("Copy"),
            importedFrom: .init(archive: "/Users/ayse/Desktop/ubuntu.tar"), createdAt: created,
            defaultUser: "ayse", diskSize: 256 << 30, macAddress: "02:00:00:65:43:21")
    }

    /// A schema 1 file, as every build before schema 2 wrote it.
    static let schema1 = """
        {
          "catalogEntry" : "Ubuntu-24.04",
          "createdAt" : "2026-10-22T16:17:53Z",
          "defaultUser" : "ayse",
          "diskSize" : 274877906944,
          "imageSHA256" : "\(String(repeating: "a", count: 64))",
          "installedBy" : "0.1.0",
          "macAddress" : "02:00:00:12:34:56",
          "name" : "Ubuntu-24.04",
          "release" : "24.04.5",
          "schemaVersion" : 1
        }
        """

    @Test func roundTripsThroughJSON() throws {
        let metadata = try Self.catalogMetadata()
        let data = try metadata.encoded()
        #expect(try DistroMetadata.decode(data) == metadata)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"createdAt\" : \"2026-10-22T16:17:53Z\""))
        #expect(text.contains("\"schemaVersion\" : 2"))
        #expect(!text.contains("importedFrom"))
    }

    @Test func recordsTheArchiveOfAnImportInsteadOfACatalogEntry() throws {
        let metadata = try Self.importedMetadata()
        let data = try metadata.encoded()
        #expect(try DistroMetadata.decode(data) == metadata)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"schemaVersion\" : 2"))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let origin = try #require(object["importedFrom"] as? [String: Any])
        #expect(origin["archive"] as? String == "/Users/ayse/Desktop/ubuntu.tar")
        for key in ["catalogEntry", "release", "imageSHA256"] {
            #expect(!text.contains(key), "\(key)")
        }
    }

    @Test func recordsStandardInputByName() throws {
        let metadata = DistroMetadata(
            name: try DistroName("Copy"),
            importedFrom: .init(archive: DistroMetadata.ImportOrigin.standardInput),
            createdAt: Self.created, defaultUser: "root", diskSize: 256 << 30,
            macAddress: "02:00:00:65:43:21")
        let text = String(decoding: try metadata.encoded(), as: UTF8.self)
        #expect(text.contains("\"archive\" : \"standard input\""))
    }

    /// A schema 1 file reads as it is, and keeps its version, because the daemon never
    /// rewrites it.
    @Test func readsASchema1File() throws {
        let metadata = try DistroMetadata.decode(Data(Self.schema1.utf8))
        #expect(metadata.schemaVersion == 1)
        #expect(metadata.catalogEntry?.rawValue == "Ubuntu-24.04")
        #expect(metadata.release == "24.04.5")
        #expect(metadata.importedFrom == nil)
        #expect(metadata.installedBy == "0.1.0")
    }

    /// What a build that knows only schema 1 does with schema 2 files, through a copy of its
    /// `DistroMetadata` (8fb7438, `Sources/MawCore/DistroMetadata.swift`): it reads a catalog
    /// installation's file, which has every key it requires, and cannot read an import's, so
    /// that its `DistributionStore.installed()` skips the imported distribution.
    @Test func showsWhatASchema1BuildReads() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(
            Schema1Metadata.self, from: try Self.catalogMetadata().encoded())
        #expect(catalog.name == "Ubuntu-24.04")
        #expect(catalog.schemaVersion == 2)
        #expect(throws: DecodingError.self) {
            try decoder.decode(Schema1Metadata.self, from: try Self.importedMetadata().encoded())
        }
    }
}

/// The metadata as schema 1 builds declare it, with the types they decode.
private struct Schema1Metadata: Decodable {
    var schemaVersion: Int
    var name: String
    var catalogEntry: String
    var release: String
    var imageSHA256: String
    var createdAt: Date
    var defaultUser: String
    var diskSize: UInt64
    var macAddress: String
    var installedBy: String
}
