/// The formats that `maw --export` writes: a tar archive, uncompressed or compressed on the
/// Mac by `/usr/bin/tar`.
public enum ArchiveFormat: String, Codable, Equatable, Sendable, CaseIterable {
    case tar = "tar"
    case tarGzip = "tar.gz"
    case tarXz = "tar.xz"

    /// The file name endings that select each compressed format when `--format` is not given,
    /// compared in lowercase, as `tar -a` compares them. `.tar.gz` ends in `.gz`, and `.tar.xz`
    /// in `.xz`.
    public static let gzipSuffixes = [".tgz", ".gz"]
    public static let xzSuffixes = [".txz", ".xz"]

    /// The format that `maw --export <distro> <file>` writes: `given`, the value of
    /// `--format`, whenever it is present, even against the file's extension; otherwise the
    /// format that the file name selects (`format(forFile:)`).
    public static func format(given: ArchiveFormat?, file: String) -> ArchiveFormat {
        given ?? format(forFile: file)
    }

    /// The format that a file name selects, as `tar -a` selects it, without regard to case:
    /// `.tgz` and `.gz`, `.tar.gz` among them, give `tar.gz`; `.txz` and `.xz`, `.tar.xz` among
    /// them, give `tar.xz`; every other name gives `tar`, and so does `-`, standard output.
    public static func format(forFile file: String) -> ArchiveFormat {
        let name = file.lowercased()
        if gzipSuffixes.contains(where: { name.hasSuffix($0) }) {
            return .tarGzip
        }
        if xzSuffixes.contains(where: { name.hasSuffix($0) }) {
            return .tarXz
        }
        return .tar
    }
}
