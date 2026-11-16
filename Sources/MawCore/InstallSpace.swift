/// The free space an installation needs on the Mac, checked before the download starts.
public enum InstallSpace {
    /// Room left for macOS and the distribution's first package updates.
    public static let margin = ByteSize.gibibytes(1)

    /// The rest of the download, the extracted root file system, and `margin`.
    public static func required(for image: CatalogImage, alreadyDownloaded: UInt64) -> ByteSize {
        let remaining = image.size > alreadyDownloaded ? image.size - alreadyDownloaded : 0
        return ByteSize(bytes: remaining + image.installedSize + margin.bytes)
    }

    /// Throws `insufficientDiskSpace` unless `available` covers `required`.
    public static func check(
        required: ByteSize, available: ByteSize, volume: String
    ) throws(MawError) {
        guard available >= required else {
            throw .insufficientDiskSpace(
                required: required.bytes, available: available.bytes, volume: volume)
        }
    }
}

extension ByteSize {
    /// The size in decimal units with up to one decimal, as Finder shows sizes: `388.3 MB`,
    /// `1.4 GB`, `512 KB`.
    public var approximateDescription: String {
        let units: [(UInt64, String)] = [
            (1_000_000_000_000, "TB"), (1_000_000_000, "GB"), (1_000_000, "MB"), (1_000, "KB"),
        ]
        for (scale, unit) in units where bytes >= scale {
            let tenths = (bytes * 10 + scale / 2) / scale
            return tenths % 10 == 0
                ? "\(tenths / 10) \(unit)" : "\(tenths / 10).\(tenths % 10) \(unit)"
        }
        return bytes == 1 ? "1 byte" : "\(bytes) bytes"
    }
}

/// The free space an import needs on the Mac, checked before its first step.
///
/// The extracted root file system's size is not known before the extraction, so it is estimated
/// from the archive's size and its compression, which the archive's first bytes show: the
/// archive itself for a plain tar archive, four times it for gzip, and six times it for every
/// other compression, recognized or not. An archive that comes through a pipe or a socket has
/// no size to read, so only the margin is required.
public enum ImportSpace {
    /// What the archive's first bytes show.
    public enum Compression: Equatable, Sendable {
        /// A tar archive without compression: `ustar` at offset 257 of its first block.
        case none
        /// gzip: `1f 8b`.
        case gzip
        /// Anything else: bzip2, zstd, xz, or bytes that are not recognized.
        case other

        /// How many times the archive's size its extracted files may need.
        public var expansionFactor: UInt64 {
            switch self {
            case .none: 1
            case .gzip: 4
            case .other: 6
            }
        }
    }

    /// The bytes of an archive that `compression(ofFirstBytes:)` needs: up to the end of the
    /// five bytes `ustar` at offset 257 of a tar header.
    public static let inspectedByteCount = 262

    /// The compression that an archive's first bytes show. Fewer than `inspectedByteCount`
    /// bytes can still show gzip, but never a plain tar archive.
    public static func compression(ofFirstBytes bytes: [UInt8]) -> Compression {
        if bytes.count >= 2, bytes[0] == 0x1F, bytes[1] == 0x8B {
            return .gzip
        }
        // POSIX ustar has "ustar\0" there and GNU tar "ustar "; both start with "ustar".
        if bytes.count >= 262, Array(bytes[257..<262]) == Array("ustar".utf8) {
            return .none
        }
        return .other
    }

    /// The free space an import needs: `InstallSpace.margin`, plus the archive's size times
    /// its compression's factor when the archive is a regular file of `archiveSize` bytes.
    /// `archiveSize` is `nil` for a pipe or a socket.
    public static func required(archiveSize: UInt64?, compression: Compression) -> ByteSize {
        guard let archiveSize else { return InstallSpace.margin }
        let (estimate, overflow) = archiveSize.multipliedReportingOverflow(
            by: compression.expansionFactor)
        let (total, overflowAgain) = estimate.addingReportingOverflow(InstallSpace.margin.bytes)
        return ByteSize(bytes: overflow || overflowAgain ? .max : total)
    }
}
