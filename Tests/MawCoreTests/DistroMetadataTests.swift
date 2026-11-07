import Foundation
import MawCore
import Testing

@Suite struct DistroMetadataTests {
    @Test func roundTripsThroughJSON() throws {
        let metadata = DistroMetadata(
            name: try DistroName("Ubuntu-24.04"), catalogEntry: try DistroName("Ubuntu-24.04"),
            release: "24.04.5", imageSHA256: String(repeating: "a", count: 64),
            createdAt: Date(timeIntervalSince1970: 1_792_685_873), defaultUser: "ayse",
            diskSize: 256 << 30, macAddress: "02:00:00:12:34:56")
        let data = try metadata.encoded()
        #expect(try DistroMetadata.decode(data) == metadata)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"createdAt\" : \"2026-10-22T16:17:53Z\""))
        #expect(text.contains("\"schemaVersion\" : 1"))
    }
}
