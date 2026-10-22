#if os(macOS)
    import Foundation
    import MawCore

    /// The installed distributions on disk, and which one is the default.
    ///
    /// A distribution is installed when `distros/<name>/distro.json` exists. An installation
    /// builds it in a staging directory and renames that directory into place as its last step,
    /// so that an interrupted installation never leaves a half-installed distribution: what is
    /// left is a staging directory, which `removeStagingLeftovers()` deletes.
    public struct DistributionStore: Sendable {
        /// `state.json`: the daemon's settings.
        struct State: Codable, Equatable {
            var defaultDistribution: DistroName?
        }

        public let paths: MawPaths

        public init(paths: MawPaths) {
            self.paths = paths
        }

        /// Every installed distribution's metadata, by name. Unreadable entries are skipped.
        public func installed() -> [DistroMetadata] {
            let entries =
                (try? FileManager.default.contentsOfDirectory(
                    at: paths.distrosDirectory, includingPropertiesForKeys: nil)) ?? []
            return entries.compactMap { entry -> DistroMetadata? in
                guard let name = try? DistroName(entry.lastPathComponent) else { return nil }
                return try? metadata(for: name)
            }.sorted { $0.name < $1.name }
        }

        /// The metadata of `name`, or `nil` if it is not installed.
        public func metadata(for name: DistroName) throws(MawError) -> DistroMetadata? {
            let file = paths.metadataFile(for: name)
            guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
                return nil
            }
            do {
                return try DistroMetadata.decode(Data(contentsOf: file))
            } catch {
                throw .daemonProtocolError(
                    reason: "\(file.path(percentEncoded: false)) cannot be read: "
                        + error.localizedDescription)
            }
        }

        public func isInstalled(_ name: DistroName) -> Bool {
            FileManager.default.fileExists(
                atPath: paths.metadataFile(for: name).path(percentEncoded: false))
        }

        /// The default distribution: the one `state.json` names if it is installed, otherwise
        /// the first installed one by name, otherwise `nil`.
        public func defaultDistribution() -> DistroName? {
            let installed = self.installed().map(\.name)
            if let chosen = readState().defaultDistribution, installed.contains(chosen) {
                return chosen
            }
            return installed.first
        }

        public func setDefaultDistribution(_ name: DistroName) throws(MawError) {
            var state = readState()
            state.defaultDistribution = name
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try FileManager.default.createDirectory(
                    at: paths.applicationSupportDirectory, withIntermediateDirectories: true)
                try encoder.encode(state).write(to: paths.stateFile, options: .atomic)
            } catch {
                throw .provisioningFailed(
                    step: "recording the default distribution", reason: error.localizedDescription)
            }
        }

        /// Writes `metadata` into `staging` and renames it to the distribution's directory.
        /// The rename is the moment the distribution becomes installed.
        public func commit(staging: URL, metadata: DistroMetadata) throws(MawError) {
            let destination = paths.distroDirectory(for: metadata.name)
            do {
                try metadata.encoded().write(
                    to: staging.appending(path: "distro.json"), options: .atomic)
                try FileManager.default.moveItem(at: staging, to: destination)
            } catch {
                throw .provisioningFailed(
                    step: "registering the distribution", reason: error.localizedDescription)
            }
        }

        /// Deletes staging directories that an interrupted installation left behind. Returns
        /// their names.
        @discardableResult
        public func removeStagingLeftovers(except active: Set<URL> = []) -> [String] {
            let entries =
                (try? FileManager.default.contentsOfDirectory(
                    at: paths.distrosDirectory, includingPropertiesForKeys: nil,
                    options: [])) ?? []
            var removed: [String] = []
            for entry in entries
            where entry.lastPathComponent.hasPrefix(MawPaths.stagingPrefix)
                && !active.contains(entry.standardizedFileURL)
            {
                if (try? FileManager.default.removeItem(at: entry)) != nil {
                    removed.append(entry.lastPathComponent)
                }
            }
            return removed
        }

        private func readState() -> State {
            guard let data = try? Data(contentsOf: paths.stateFile),
                let state = try? JSONDecoder().decode(State.self, from: data)
            else {
                return State()
            }
            return state
        }
    }
#endif
