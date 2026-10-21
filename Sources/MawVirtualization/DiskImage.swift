#if os(macOS)
    import Darwin
    import Foundation
    import MawCore

    /// Raw disk images for distributions. Phase 05 formats them inside the guest; the host only
    /// creates and attaches them.
    public enum DiskImage {
        /// Creates a raw disk image of `size` bytes at `url` as a sparse file: APFS allocates
        /// blocks only as the guest writes them.
        ///
        /// Throws `diskImageExists` rather than overwrite an existing file, and
        /// `sparseFilesUnsupported` if the volume cannot store sparse files, because the image
        /// would then occupy its full size immediately.
        public static func createSparse(at url: URL, size: ByteSize) throws(MawError) {
            try createSparse(at: url, size: size) { directory in
                let values = try directory.resourceValues(forKeys: [.volumeSupportsSparseFilesKey])
                return values.volumeSupportsSparseFiles == true
            }
        }

        /// `createSparse(at:size:)` with the volume check injected, for tests.
        static func createSparse(
            at url: URL,
            size: ByteSize,
            volumeSupportsSparseFiles: (URL) throws -> Bool
        ) throws(MawError) {
            let path = url.path(percentEncoded: false)
            guard size.bytes <= UInt64(Int64.max) else {
                throw .diskImageCreationFailed(path: path, reason: "\(size) is too large")
            }

            let supportsSparseFiles: Bool
            do {
                supportsSparseFiles = try volumeSupportsSparseFiles(url.deletingLastPathComponent())
            } catch {
                throw .diskImageCreationFailed(
                    path: path,
                    reason: "its directory cannot be inspected (\(error.localizedDescription))")
            }
            guard supportsSparseFiles else {
                throw .sparseFilesUnsupported(path: path)
            }

            // O_EXCL refuses an existing file atomically, without a check-then-create race.
            let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else {
                let code = errno
                if code == EEXIST {
                    throw .diskImageExists(path: path)
                }
                throw .diskImageCreationFailed(path: path, reason: String(cString: strerror(code)))
            }
            defer { close(descriptor) }

            // Extending an empty file with ftruncate allocates no blocks on APFS.
            if ftruncate(descriptor, off_t(size.bytes)) != 0 {
                let reason = String(cString: strerror(errno))
                unlink(path)
                throw .diskImageCreationFailed(path: path, reason: reason)
            }
        }
    }
#endif
