import MawCore
import Testing

@Suite struct ArchiveFormatTests {
    /// Each ending that selects a compressed format, in lowercase and in uppercase, as `tar -a`
    /// selects it.
    @Test(arguments: [
        ("ubuntu.tar.gz", ArchiveFormat.tarGzip), ("UBUNTU.TAR.GZ", .tarGzip),
        ("ubuntu.tgz", .tarGzip), ("UBUNTU.TGZ", .tarGzip),
        ("ubuntu.gz", .tarGzip), ("UBUNTU.GZ", .tarGzip), ("Ubuntu.Tar.Gz", .tarGzip),
        ("ubuntu.tar.xz", .tarXz), ("UBUNTU.TAR.XZ", .tarXz),
        ("ubuntu.txz", .tarXz), ("UBUNTU.TXZ", .tarXz),
        ("ubuntu.xz", .tarXz), ("UBUNTU.XZ", .tarXz), ("Ubuntu.Tar.Xz", .tarXz),
        ("/Users/ayse/Desktop/backup.tgz", .tarGzip),
    ])
    func selectsACompressedFormatByTheEnding(_ file: String, _ format: ArchiveFormat) {
        #expect(ArchiveFormat.format(forFile: file) == format)
    }

    /// Every other name is a plain tar archive: `.tar` in either case, a name without an
    /// ending, an ending that only resembles one, and `-`, standard output.
    @Test(arguments: [
        "ubuntu.tar", "UBUNTU.TAR", "ubuntu", "ubuntu.tar.bz2", "ubuntu.tar.zst", "ubuntu.gzip",
        "ubuntu.tar.gz.part", "gz", "xz", "backup.gz/", "-",
    ])
    func choosesTarForEveryOtherName(_ file: String) {
        #expect(ArchiveFormat.format(forFile: file) == .tar)
    }

    /// A `--format` that is given wins, also against a contrary ending.
    @Test(arguments: [
        (ArchiveFormat.tar, "ubuntu.tar.gz"), (.tar, "ubuntu.txz"), (.tarGzip, "ubuntu.tar"),
        (.tarGzip, "ubuntu.tar.xz"), (.tarXz, "ubuntu.tgz"), (.tarXz, "-"), (.tarGzip, "-"),
    ])
    func letsAGivenFormatWin(_ given: ArchiveFormat, _ file: String) {
        #expect(ArchiveFormat.format(given: given, file: file) == given)
    }

    @Test func usesTheFileWithoutAGivenFormat() {
        #expect(ArchiveFormat.format(given: nil, file: "ubuntu.TGZ") == .tarGzip)
        #expect(ArchiveFormat.format(given: nil, file: "-") == .tar)
    }

    /// The raw values are the values of `--format`.
    @Test func namesTheFormatsAsFormatAcceptsThem() {
        #expect(ArchiveFormat.allCases.map(\.rawValue) == ["tar", "tar.gz", "tar.xz"])
    }
}
