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

            // O_EXCL refuses an existing file atomically, without a check-then-create race. Only
            // the owner may read or write it: the disk holds the distribution's files, including
            // its password hashes.
            let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
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

        /// Whether another process holds a lock on the disk image, as Virtualization.framework
        /// does while a virtual machine uses it. Asks with `F_GETLK`, which takes no lock.
        public static func isLocked(_ url: URL) -> Bool {
            let descriptor = open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            var lock = flock()
            lock.l_type = Int16(F_WRLCK)
            lock.l_whence = Int16(SEEK_SET)
            lock.l_start = 0
            lock.l_len = 0
            guard fcntl(descriptor, F_GETLK, &lock) == 0 else { return false }
            return lock.l_type != Int16(F_UNLCK)
        }

        /// Waits until no virtual machine holds the disk image, for at most `timeout`. A
        /// machine whose daemon was killed keeps its disk until its process exits, which took
        /// 1.2 s when measured. Throws `diskImageInUse` if it is still held.
        public static func waitUntilUnlocked(_ url: URL, timeout: Duration) async throws(MawError) {
            let deadline = ContinuousClock.now + timeout
            while isLocked(url) {
                guard ContinuousClock.now < deadline else {
                    throw .diskImageInUse(path: url.path(percentEncoded: false))
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
#endif
