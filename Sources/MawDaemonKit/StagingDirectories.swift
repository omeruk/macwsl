#if os(macOS)
    import Darwin
    import Foundation
    import MawCore
    import MawProtocol

    /// The staging directories of the daemon that owns a `DistributionStore`:
    /// `distros/.staging/<label>/<name>-<id>/` (`MawPaths.stagingDirectory(for:id:label:)`).
    ///
    /// Several daemons, one per label, can run at once and share `distros/`. Each one creates and
    /// removes staging directories only under its own label, so that none removes another's
    /// installation in progress.
    ///
    /// Creation and removal work relative to directory descriptors opened with `O_NOFOLLOW`, from
    /// `distros/` down: if `.staging`, the label's directory, or anything inside them is a
    /// symbolic link, they never follow it. A link inside is removed as a link; a link in place
    /// of `.staging` or of the label's directory stops the operation.
    extension DistributionStore {
        /// Where a new installation of `name` by this daemon is built. Nothing is created.
        public func stagingDirectory(for name: DistroName, id: UUID = UUID()) -> URL {
            paths.stagingDirectory(for: name, id: id, label: daemonLabel)
        }

        /// Creates `staging`, which `stagingDirectory(for:id:)` returned, and `.staging` and the
        /// label's directory above it, each with mode 0700. Fails if `staging` exists already or
        /// if a directory above it is a symbolic link.
        public func createStagingDirectory(_ staging: URL) throws(MawError) {
            let path = staging.path(percentEncoded: false)
            func failure(_ reason: String) -> MawError {
                .provisioningFailed(
                    step: "creating the distribution's directory", reason: "\(path): \(reason)")
            }
            guard let leaf = ownLeaf(of: staging) else {
                throw failure("it is not in this daemon's staging directory")
            }
            do {
                try FileManager.default.createDirectory(
                    at: paths.distrosDirectory, withIntermediateDirectories: true)
            } catch {
                throw failure(error.localizedDescription)
            }
            let directory = openLabelDirectory(create: true)
            guard directory.descriptor >= 0 else { throw failure(directory.reason) }
            defer { close(directory.descriptor) }
            guard mkdirat(directory.descriptor, leaf, 0o700) == 0 else {
                throw failure(SystemError("mkdir").description)
            }
        }

        /// Removes `staging`, which `stagingDirectory(for:id:)` returned, and everything in it,
        /// without following a symbolic link. Does nothing if it does not exist.
        public func removeStagingDirectory(_ staging: URL) {
            guard let leaf = ownLeaf(of: staging) else { return }
            let directory = openLabelDirectory(create: false)
            guard directory.descriptor >= 0 else { return }
            defer { close(directory.descriptor) }
            _ = Self.removeEntry(leaf, in: directory.descriptor)
        }

        /// Removes this daemon's staging directories that an interrupted installation left
        /// behind, and nothing of any other label's. Returns their names. Call it only while
        /// this daemon's lock is held, before any installation starts.
        @discardableResult
        public func removeStagingLeftovers() -> [String] {
            let directory = openLabelDirectory(create: false)
            guard directory.descriptor >= 0 else { return [] }
            defer { close(directory.descriptor) }
            return Self.entries(of: directory.descriptor).filter {
                Self.removeEntry($0, in: directory.descriptor)
            }
        }

        /// The staging directories of earlier builds, `distros/.staging-<name>-<id>`, whose names
        /// say nothing about which daemon made them.
        public func legacyStagingDirectories() -> [String] {
            let distros = Self.openDistros(paths)
            guard distros >= 0 else { return [] }
            defer { close(distros) }
            return Self.entries(of: distros).filter {
                $0.hasPrefix(MawPaths.legacyStagingPrefix)
            }.sorted()
        }

        /// Removes the staging directories of earlier builds. Call it only when no other
        /// daemon runs, of any label: any of them might be the one installing there. Returns
        /// their names.
        @discardableResult
        public func removeLegacyStagingDirectories() -> [String] {
            let distros = Self.openDistros(paths)
            guard distros >= 0 else { return [] }
            defer { close(distros) }
            return Self.entries(of: distros).filter {
                $0.hasPrefix(MawPaths.legacyStagingPrefix) && Self.removeEntry($0, in: distros)
            }.sorted()
        }

        // MARK: Descriptors

        /// The last path component of `staging` if its parent is this daemon's label directory.
        private func ownLeaf(of staging: URL) -> String? {
            func normalized(_ url: URL) -> String {
                var path = url.standardizedFileURL.path(percentEncoded: false)
                while path.count > 1 && path.hasSuffix("/") {
                    path.removeLast()
                }
                return path
            }
            let leaf = staging.lastPathComponent
            guard !leaf.isEmpty, leaf != ".", leaf != "..", !leaf.contains("/"),
                normalized(staging.deletingLastPathComponent())
                    == normalized(paths.stagingDirectory(label: daemonLabel))
            else { return nil }
            return leaf
        }

        /// Opens `distros/.staging/<label>`, creating the two directories if `create` is set.
        /// Returns -1 and the reason if either is missing, is not a directory, or is a symbolic
        /// link.
        private func openLabelDirectory(create: Bool) -> (descriptor: Int32, reason: String) {
            let distros = Self.openDistros(paths)
            guard distros >= 0 else {
                return (
                    -1,
                    SystemError("open \(paths.distrosDirectory.path(percentEncoded: false))")
                        .description
                )
            }
            defer { close(distros) }
            let root = Self.openDirectory(MawPaths.stagingRootName, in: distros, create: create)
            guard root >= 0 else {
                return (-1, SystemError("open \(MawPaths.stagingRootName)").description)
            }
            defer { close(root) }
            let label = Self.openDirectory(daemonLabel.rawValue, in: root, create: create)
            guard label >= 0 else {
                return (-1, SystemError("open \(daemonLabel.rawValue)").description)
            }
            return (label, "")
        }

        /// `distros/` itself may be a symbolic link that the user set up; what is inside it is
        /// not followed.
        private static func openDistros(_ paths: MawPaths) -> Int32 {
            open(
                paths.distrosDirectory.path(percentEncoded: false),
                O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }

        private static func openDirectory(_ name: String, in parent: Int32, create: Bool) -> Int32 {
            if create && mkdirat(parent, name, 0o700) != 0 && errno != EEXIST {
                return -1
            }
            return openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }

        /// The names in the directory open at `descriptor`, without `.` and `..`.
        private static func entries(of descriptor: Int32) -> [String] {
            let copy = dup(descriptor)
            guard copy >= 0 else { return [] }
            guard let stream = fdopendir(copy) else {
                close(copy)
                return []
            }
            defer { closedir(stream) }
            var names: [String] = []
            while let entry = readdir(stream) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                    String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                if name != "." && name != ".." {
                    names.append(name)
                }
            }
            return names
        }

        /// Removes `name` from the directory open at `parent`: a directory with everything in
        /// it, depth first, and anything else, a symbolic link included, by unlinking it.
        /// Returns whether it is gone.
        private static func removeEntry(_ name: String, in parent: Int32) -> Bool {
            var status = stat()
            guard fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                return errno == ENOENT
            }
            if status.st_mode & S_IFMT == S_IFDIR {
                let directory = openat(
                    parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard directory >= 0 else { return false }
                for entry in entries(of: directory) {
                    _ = removeEntry(entry, in: directory)
                }
                close(directory)
                return unlinkat(parent, name, AT_REMOVEDIR) == 0 || errno == ENOENT
            }
            return unlinkat(parent, name, 0) == 0 || errno == ENOENT
        }
    }
#endif
