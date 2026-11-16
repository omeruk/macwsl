import MawCore
import Testing

/// The free space an import needs (prompts/06b-distro-removal-and-transfer.md, decision 6 of
/// pull request B's plan).
@Suite struct ImportSpaceTests {
    /// A first block of `count` zero bytes with `bytes` at its start and `magic` at offset 257.
    static func block(_ bytes: [UInt8] = [], magic: String? = nil, count: Int = 512) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: count)
        block.replaceSubrange(0..<bytes.count, with: bytes)
        if let magic {
            block.replaceSubrange(257..<(257 + magic.utf8.count), with: Array(magic.utf8))
        }
        return block
    }

    @Test func recognizesAPlainTarArchiveByItsUstarMagic() {
        // POSIX ustar and GNU tar.
        #expect(ImportSpace.compression(ofFirstBytes: Self.block(magic: "ustar\0")) == .none)
        #expect(ImportSpace.compression(ofFirstBytes: Self.block(magic: "ustar ")) == .none)
        // Exactly the bytes that the check reads.
        #expect(
            ImportSpace.compression(
                ofFirstBytes: Self.block(magic: "ustar", count: ImportSpace.inspectedByteCount))
                == .none)
    }

    @Test func recognizesGzip() {
        #expect(ImportSpace.compression(ofFirstBytes: Self.block([0x1F, 0x8B, 0x08])) == .gzip)
        #expect(ImportSpace.compression(ofFirstBytes: [0x1F, 0x8B]) == .gzip)
    }

    /// Every other compression, recognized or not, gets the largest factor.
    @Test func treatsEveryOtherCompressionAsOther() {
        let others: [[UInt8]] = [
            [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00],  // xz
            Array("BZh9".utf8),  // bzip2
            [0x28, 0xB5, 0x2F, 0xFD],  // zstd
            Array("vhdxfile".utf8),  // a WSL disk, which tar cannot read
        ]
        for bytes in others {
            #expect(ImportSpace.compression(ofFirstBytes: Self.block(bytes)) == .other, "\(bytes)")
        }
        // An old tar archive without the ustar magic, a short file, and an empty one.
        #expect(ImportSpace.compression(ofFirstBytes: Self.block()) == .other)
        #expect(ImportSpace.compression(ofFirstBytes: Array("ustar".utf8)) == .other)
        #expect(ImportSpace.compression(ofFirstBytes: []) == .other)
        // The magic one byte too early.
        var early = Self.block()
        early.replaceSubrange(256..<261, with: Array("ustar".utf8))
        #expect(ImportSpace.compression(ofFirstBytes: early) == .other)
    }

    @Test func multipliesTheArchiveSizeByItsFactorAndAddsTheMargin() {
        let margin = InstallSpace.margin.bytes
        let size: UInt64 = 1_000_000_000
        #expect(ImportSpace.required(archiveSize: size, compression: .none).bytes == size + margin)
        #expect(
            ImportSpace.required(archiveSize: size, compression: .gzip).bytes == 4 * size + margin)
        #expect(
            ImportSpace.required(archiveSize: size, compression: .other).bytes == 6 * size + margin
        )
        #expect(margin == 1 << 30)
    }

    /// A pipe or a socket has no size to read.
    @Test func requiresOnlyTheMarginWithoutASize() {
        for compression in [ImportSpace.Compression.none, .gzip, .other] {
            #expect(
                ImportSpace.required(archiveSize: nil, compression: compression)
                    == InstallSpace.margin)
        }
    }

    @Test func saturatesInsteadOfOverflowing() {
        #expect(
            ImportSpace.required(archiveSize: .max / 2, compression: .other).bytes == .max)
        #expect(ImportSpace.required(archiveSize: .max, compression: .none).bytes == .max)
    }
}
