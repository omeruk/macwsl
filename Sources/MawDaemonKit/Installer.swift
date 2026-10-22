#if os(macOS)
    import Foundation
    import MawCore
    import MawVirtualization
    import MawXPC

    /// Downloads distribution images and verifies them. `ImageCache` is the real one.
    public protocol ImageSource: Sendable {
        /// The bytes of `image` already on disk, complete or partial, for the free-space check.
        func downloadedBytes(of image: CatalogImage) -> UInt64
        /// Whether the whole file is in the cache. It is verified again before every use.
        func isComplete(_ image: CatalogImage) -> Bool
        /// Downloads what is missing of `image`, resuming an interrupted download.
        func download(
            _ image: CatalogImage, progress: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws(MawError)
        /// Checks the cached file's size and SHA-256 and returns it. A file that fails is
        /// removed, so that the next attempt downloads it again.
        func verify(_ image: CatalogImage) async throws(MawError) -> URL
    }

    /// What provisioning writes into a new distribution.
    public struct GuestConfiguration: Sendable {
        public var hostname: String
        public var user: UserName
        public var password: Secret
        /// The Mac's language and region, generated in the guest if it supports it.
        public var locale: String?

        public init(hostname: String, user: UserName, password: Secret, locale: String?) {
            self.hostname = hostname
            self.user = user
            self.password = password
            self.locale = locale
        }
    }

    /// The machine that provisions a new distribution's disk: the initramfs with the disk
    /// attached. `VirtualProvisioningMachine` is the real one.
    public protocol ProvisioningMachine: Sendable {
        func boot(disk: URL) async throws(MawError)
        func format() async throws(MawError)
        func extract(image: URL, format: CatalogImage.Format) async throws(MawError)
        func configure(_ configuration: GuestConfiguration) async throws(MawError)
        /// Writes everything to the disk, unmounts it, and powers the machine off.
        func finish() async throws(MawError)
        /// Stops the machine at once. Used on failure and cancellation.
        func discard() async
    }

    /// Creates the provisioning machine for the distribution being installed.
    public typealias ProvisioningMachineFactory =
        @Sendable (DistroName) throws(MawError) -> any ProvisioningMachine

    /// The free space on the volume that holds a URL, and the volume's name.
    public typealias FreeSpaceProbe =
        @Sendable (URL) -> (available: UInt64, volume: String)?

    /// Installs distributions from the catalog (docs/distributions.md).
    ///
    /// The steps run in order: check, download (unless cached), verify, prepare the disk,
    /// format, extract, configure, finish, register, start. Until the registration, everything
    /// lives in a staging directory; on failure or cancellation the provisioning machine is
    /// stopped and the directory removed, so that nothing is left but a partial download, which
    /// the next attempt resumes.
    public actor Installer {
        /// The virtual size of a new distribution's disk.
        public static let diskSize = ByteSize.gibibytes(256)

        private let catalog: DistroCatalog
        private let store: DistributionStore
        private let images: any ImageSource
        private let makeMachine: ProvisioningMachineFactory
        private let freeSpace: FreeSpaceProbe
        private let startMachine: @Sendable (MachineID) async throws(MawError) -> Void
        private let makeMACAddress: @Sendable () -> String
        private let log: DaemonLog
        /// The names of the installations in progress, in lowercase: APFS ignores case, so
        /// `Twin` and `twin` would end in the same directory.
        private var active: Set<String> = []
        /// The SHA-256 of every image being downloaded.
        private var downloadingImages: Set<String> = []

        public init(
            catalog: DistroCatalog = .builtIn, store: DistributionStore, images: any ImageSource,
            makeMachine: @escaping ProvisioningMachineFactory,
            freeSpace: @escaping FreeSpaceProbe,
            startMachine: @escaping @Sendable (MachineID) async throws(MawError) -> Void,
            makeMACAddress: @escaping @Sendable () -> String,
            log: DaemonLog = DaemonLog()
        ) {
            self.catalog = catalog
            self.store = store
            self.images = images
            self.makeMachine = makeMachine
            self.freeSpace = freeSpace
            self.startMachine = startMachine
            self.makeMACAddress = makeMACAddress
            self.log = log
        }

        /// Installs a distribution. Cancelling the calling task cancels the installation and
        /// removes its traces before this throws `installationCancelled`.
        public func install(
            _ request: InstallRequest, progress: @escaping @Sendable (InstallProgress) -> Void
        ) async throws(MawError) -> InstallSummary {
            let started = ContinuousClock.now
            let entry: CatalogEntry
            if let wanted = request.distribution {
                guard let found = catalog.entry(named: wanted) else {
                    throw .unknownDistribution(wanted)
                }
                entry = found
            } else {
                entry = catalog.recommendedEntry
            }
            let name = request.name ?? entry.name
            // The initramfs machine's name, which also names its console log.
            guard name.rawValue.lowercased() != MachineID.initramfs.name else {
                throw .invalidDistroName(name.rawValue, reason: "the name is reserved for maw")
            }
            guard !store.isInstalled(name) else {
                throw .distributionAlreadyInstalled(name)
            }
            let key = name.rawValue.lowercased()
            guard !active.contains(key) else {
                throw .installationInProgress(name)
            }
            let user = try UserName(request.user, reservedNames: entry.reservedNames)
            try Self.checkPassword(request.password)
            try checkFreeSpace(for: entry.image)

            let staging = store.paths.stagingDirectory(for: name, id: UUID().uuidString)
            active.insert(key)
            defer { active.remove(key) }
            log.notice("\(name): installation started for user \(user)")

            // The first installed distribution becomes the default.
            let isDefault = store.defaultDistribution() == nil
            do throws(MawError) {
                let image = try await obtainImage(entry.image, for: name, progress: progress)
                let metadata = try await provision(
                    entry: entry, name: name, image: image, user: user, request: request,
                    staging: staging, progress: progress)
                try checkCancellation(name)
                try store.commit(staging: staging, metadata: metadata)
            } catch {
                removeStaging(staging)
                if Task.isCancelled {
                    log.notice("\(name): installation cancelled; its files were removed")
                    throw .installationCancelled(name)
                }
                log.error("\(name): installation failed: \(error.description)")
                throw error
            }

            if isDefault {
                try? store.setDefaultDistribution(name)
            }
            log.notice("\(name): installed")
            // The first boot is part of the installation, so that the first session is warm.
            // A failure here does not undo the installation; the next session reports it.
            try? await timed(.start, progress: progress) { () throws(MawError) in
                do throws(MawError) {
                    try await startMachine(.distribution(name))
                } catch {
                    log.error("\(name): the first start failed: \(error.description)")
                }
            }
            return InstallSummary(
                name: name, displayName: entry.displayName, defaultUser: user.rawValue,
                isDefault: isDefault,
                milliseconds: UInt64(max(0, (ContinuousClock.now - started).milliseconds)))
        }

        // MARK: Steps

        private func obtainImage(
            _ image: CatalogImage, for name: DistroName,
            progress: @escaping @Sendable (InstallProgress) -> Void
        ) async throws(MawError) -> URL {
            // One download per image: a second installation of the same image waits for the
            // first's download, which would otherwise write the same partial file.
            while downloadingImages.contains(image.sha256) {
                try checkCancellation(name)
                try? await Task.sleep(for: .milliseconds(200))
            }
            if !images.isComplete(image) {
                downloadingImages.insert(image.sha256)
                defer { downloadingImages.remove(image.sha256) }
                try await timed(.download, progress: progress) { () throws(MawError) in
                    try await images.download(image) { progress(.download($0)) }
                }
            }
            return try await timed(.verify, progress: progress) { () throws(MawError) in
                try await images.verify(image)
            }
        }

        private func provision(
            entry: CatalogEntry, name: DistroName, image: URL, user: UserName,
            request: InstallRequest, staging: URL,
            progress: @escaping @Sendable (InstallProgress) -> Void
        ) async throws(MawError) -> DistroMetadata {
            let machine = try makeMachine(name)
            let disk = staging.appending(path: "disk.img")
            // A cancelled installation stops the machine at once, which ends the step that is
            // running. The steps' errors travel out of the handler as a Result, because not every
            // toolchain lets a typed error pass through withTaskCancellationHandler.
            let result: Result<DistroMetadata, MawError> = await withTaskCancellationHandler {
                do throws(MawError) {
                    return .success(
                        try await provisionSteps(
                            entry: entry, name: name, image: image, user: user, request: request,
                            staging: staging, disk: disk, machine: machine, progress: progress))
                } catch {
                    return .failure(error)
                }
            } onCancel: {
                Task { await machine.discard() }
            }
            return try result.get()
        }

        private func provisionSteps(
            entry: CatalogEntry, name: DistroName, image: URL, user: UserName,
            request: InstallRequest, staging: URL, disk: URL, machine: any ProvisioningMachine,
            progress: @escaping @Sendable (InstallProgress) -> Void
        ) async throws(MawError) -> DistroMetadata {
            do throws(MawError) {
                try await timed(.prepare, progress: progress) { () throws(MawError) in
                    do {
                        try FileManager.default.createDirectory(
                            at: staging, withIntermediateDirectories: true)
                    } catch {
                        throw .provisioningFailed(
                            step: "creating the distribution's directory",
                            reason: error.localizedDescription)
                    }
                    try DiskImage.createSparse(at: disk, size: Self.diskSize)
                    try await machine.boot(disk: disk)
                }
                try checkCancellation(name)
                try await timed(.format, progress: progress) { () throws(MawError) in
                    try await machine.format()
                }
                try checkCancellation(name)
                try await timed(.extract, progress: progress) { () throws(MawError) in
                    try await machine.extract(image: image, format: entry.image.format)
                }
                try checkCancellation(name)
                try await timed(.configure, progress: progress) { () throws(MawError) in
                    try await machine.configure(
                        GuestConfiguration(
                            hostname: Self.hostname(for: name), user: user,
                            password: request.password, locale: request.locale))
                }
                try checkCancellation(name)
                try await timed(.finish, progress: progress) { () throws(MawError) in
                    try await machine.finish()
                }
            } catch {
                await machine.discard()
                throw error
            }
            return DistroMetadata(
                name: name, catalogEntry: entry.name, release: entry.release,
                imageSHA256: entry.image.sha256, createdAt: Date(),
                defaultUser: user.rawValue, diskSize: Self.diskSize.bytes,
                macAddress: makeMACAddress())
        }

        /// Runs `body` between a `started` and a `finished` event, and logs its duration.
        private func timed<T>(
            _ step: InstallStep, progress: @escaping @Sendable (InstallProgress) -> Void,
            _ body: () async throws(MawError) -> T
        ) async throws(MawError) -> T {
            progress(.started(step))
            let started = ContinuousClock.now
            let result = try await body()
            let milliseconds = UInt64(max(0, (ContinuousClock.now - started).milliseconds))
            progress(.finished(step, milliseconds: milliseconds))
            log.notice("installation step \(step.rawValue): \(milliseconds) ms")
            return result
        }

        private func checkCancellation(_ name: DistroName) throws(MawError) {
            if Task.isCancelled {
                throw .installationCancelled(name)
            }
        }

        private func checkFreeSpace(for image: CatalogImage) throws(MawError) {
            let required = InstallSpace.required(
                for: image, alreadyDownloaded: images.downloadedBytes(of: image))
            // The cache and the distribution live on the same volume, the user's home.
            guard let space = freeSpace(store.paths.homeDirectory) else { return }
            try InstallSpace.check(
                required: required, available: ByteSize(bytes: space.available),
                volume: space.volume)
        }

        private func removeStaging(_ staging: URL) {
            try? FileManager.default.removeItem(at: staging)
        }

        // MARK: Rules

        /// Ubuntu's `chpasswd` reads `user:password` lines, so a password must be a single
        /// line; it must not be empty, so that `sudo` asks for something.
        static func checkPassword(_ password: Secret) throws(MawError) {
            if password.value.isEmpty {
                throw .invalidPassword(reason: "it is empty")
            }
            if password.value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }
            ) {
                throw .invalidPassword(reason: "it contains a line break or a control character")
            }
        }

        /// The guest's host name: the distribution's name in lowercase, with every character
        /// that a host name cannot contain replaced by `-`, such as `ubuntu-24-04`.
        static func hostname(for name: DistroName) -> String {
            var result = ""
            for scalar in name.rawValue.lowercased().unicodeScalars {
                let isAllowed = ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
                if isAllowed {
                    result.unicodeScalars.append(scalar)
                } else if !result.isEmpty, !result.hasSuffix("-") {
                    result += "-"
                }
            }
            while result.hasSuffix("-") {
                result.removeLast()
            }
            return result.isEmpty ? "maw" : String(result.prefix(63))
        }
    }
#endif
