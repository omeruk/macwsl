import MawCore
import Testing

@Suite struct ByteSizeTests {
    @Test(arguments: [
        ("512M", UInt64(512) << 20),
        ("4G", UInt64(4) << 30),
        ("4g", UInt64(4) << 30),
        ("4GB", UInt64(4) << 30),
        ("4GiB", UInt64(4) << 30),
        ("4gib", UInt64(4) << 30),
        ("64K", UInt64(64) << 10),
        ("1T", UInt64(1) << 40),
        (" 2G ", UInt64(2) << 30),
    ])
    func parsesSizesWithBinaryUnits(_ text: String, _ bytes: UInt64) throws {
        #expect(try ByteSize(parsing: text).bytes == bytes)
    }

    @Test(arguments: [
        ("", "it must start with a whole number"),
        ("G", "it must start with a whole number"),
        ("4", "it has no unit"),
        ("1.5G", "'.5G' is not a unit"),
        ("4X", "'X' is not a unit"),
        ("4GBB", "'GBB' is not a unit"),
        ("4 G", "' G' is not a unit"),
        ("0M", "it must be greater than zero"),
        ("99999999999999999999G", "it is too large"),
        ("17179869184G", "it is too large"),
    ])
    func rejectsInvalidSizes(_ text: String, _ reason: String) {
        #expect(throws: MawError.invalidSize(text, reason: reason)) {
            try ByteSize(parsing: text)
        }
    }

    @Test func explainsTheFormat() throws {
        let error = try #require(throws: MawError.self) { try ByteSize(parsing: "4") }
        #expect(error.errorDescription == "'4' is not a valid size: it has no unit.")
        #expect(error.recoverySuggestion?.contains("512M or 4G") == true)
    }

    @Test func describesSizesWithTheLargestExactUnit() {
        #expect(ByteSize.gibibytes(2).description == "2G")
        #expect(ByteSize.mebibytes(1536).description == "1536M")
        #expect(ByteSize.kibibytes(3).description == "3K")
        #expect(ByteSize(bytes: 1000).description == "1000 bytes")
    }

    @Test func roundsDownToMebibytes() {
        #expect(ByteSize(bytes: (5 << 20) + 123).roundedDownToMebibytes == .mebibytes(5))
        #expect(ByteSize.mebibytes(7).roundedDownToMebibytes == .mebibytes(7))
    }
}
