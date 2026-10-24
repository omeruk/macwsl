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
