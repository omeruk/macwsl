#if os(macOS)
    import Foundation

    /// The free space on a Mac volume.
    public enum FreeSpace {
        /// The space available for important use, as Finder reports it, which counts purgeable
        /// space that macOS frees on demand, and the volume's name.
        public static let probe: FreeSpaceProbe = { url in
            guard
                let values = try? url.resourceValues(forKeys: [
                    .volumeAvailableCapacityForImportantUsageKey, .volumeNameKey,
                ]),
                let available = values.volumeAvailableCapacityForImportantUsage
            else {
                return nil
            }
            return (UInt64(max(0, available)), values.volumeName ?? "the volume")
        }
    }
#endif
