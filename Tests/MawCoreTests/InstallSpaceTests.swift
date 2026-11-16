import Foundation
import MawCore
import Testing

@Suite struct InstallSpaceTests {
    let image = CatalogImage(
        url: URL(string: "https://example.com/image.tar.gz")!, format: .tarGzip,
        size: 400_000_000, sha256: String(repeating: "0", count: 64), installedSize: 1_400_000_000)

    @Test func countsTheRestOfTheDownloadTheRootFileSystemAndTheMargin() {
        #expect(
            InstallSpace.required(for: image, alreadyDownloaded: 0).bytes
                == 400_000_000 + 1_400_000_000 + (1 << 30))
        #expect(
            InstallSpace.required(for: image, alreadyDownloaded: 100_000_000).bytes
                == 300_000_000 + 1_400_000_000 + (1 << 30))
        #expect(
            InstallSpace.required(for: image, alreadyDownloaded: 400_000_000).bytes
                == 1_400_000_000 + (1 << 30))
    }

    @Test func refusesWhenTheVolumeIsTooFull() {
        let required = InstallSpace.required(for: image, alreadyDownloaded: 0)
        #expect(
            throws: MawError.insufficientDiskSpace(
                required: required.bytes, available: 2_000_000_000, volume: "Macintosh HD",
                for: .install)
        ) {
            try InstallSpace.check(
                required: required, available: ByteSize(bytes: 2_000_000_000),
                volume: "Macintosh HD", for: .install)
        }
        #expect(throws: Never.self) {
            try InstallSpace.check(
                required: required, available: ByteSize(bytes: required.bytes),
                volume: "Macintosh HD", for: .install)
        }
    }

    @Test func describesTheErrorWithReadableSizes() {
        let error = MawError.insufficientDiskSpace(
            required: 2_873_741_824, available: 2_000_000_000, volume: "Macintosh HD",
            for: .install)
        #expect(
            error.errorDescription
                == "The installation needs 2.9 GB of free space on Macintosh HD,\nbut only 2 GB "
                + "is available.")
        #expect(
            error.recoverySuggestion
                == "Free up space on the volume, then run maw --install again.")
    }

    /// An import's error names the import and its command.
    @Test func namesTheOperationThatNeedsTheSpace() {
        let error = MawError.insufficientDiskSpace(
            required: 2_873_741_824, available: 2_000_000_000, volume: "Macintosh HD",
            for: .import)
        #expect(
            error.errorDescription
                == "The import needs 2.9 GB of free space on Macintosh HD,\nbut only 2 GB "
                + "is available.")
        #expect(
            error.recoverySuggestion
                == "Free up space on the volume, then run maw --import again.")
    }

    @Test(arguments: [
        (UInt64(0), "0 bytes"), (1, "1 byte"), (999, "999 bytes"), (1_000, "1 KB"),
        (388_300_496, "388.3 MB"), (1_372_721_152, "1.4 GB"), (999_960_000, "1000 MB"),
    ])
    func formatsSizesInDecimalUnits(_ bytes: UInt64, _ text: String) {
        #expect(ByteSize(bytes: bytes).approximateDescription == text)
    }
}
