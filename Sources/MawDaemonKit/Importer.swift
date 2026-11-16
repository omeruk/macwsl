#if os(macOS)
    import Darwin
    import Foundation
    import MawCore
    import MawProtocol
    import MawVirtualization
    import MawXPC

    /// The machine that provisions an imported distribution's disk: the initramfs with the new
    /// disk attached, as at installation. `VirtualProvisioningMachine` is the real one.
    public protocol ImportingMachine: Sendable {
        func boot(disk: URL) async throws(MawError)
        func format() async throws(MawError)
        /// Extracts the archive that `source` reads, if it is a tar archive once decompressed,
        /// and returns the bytes of the uncompressed archive that reached the guest. Takes over
        /// `source`.
        func extract(archive source: OwnedDescriptor) async throws(MawError) -> ArchiveExtraction
        /// Runs `ImportInspection.script` and returns its output.
        func inspect() async throws(MawError) -> String
        /// The text of a file that the inspection resolved inside the root.
        func readFile(_ path: String) async throws(MawError) -> String
        /// Writes the system files, and `mawConf` as `/etc/maw.conf` unless it is `nil`.
        /// Returns a path that could not be resolved inside the root, and why.
        func configureImport(hostname: String, defaultUser: DefaultUserChoice, mawConf: String?)
            async throws(MawError) -> (path: String, reason: String)?
        /// Writes everything to the disk, unmounts it, and powers the machine off.
        func finish() async throws(MawError)
        /// Stops the machine at once. Used on failure and cancellation.
        func discard() async
    }

    /// How an import's extraction ended.
    public enum ArchiveExtraction: Equatable, Sendable {
        /// The archive was extracted; `bytes` of it, uncompressed, reached the guest.
        case extracted(bytes: UInt64)
        /// Once decompressed, it is not a tar archive, and nothing of it reached the guest.
        case notATarArchive
    }

    /// Creates the machine that imports the distribution `name`.
    public typealias ImportingMachineFactory =
        @Sendable (DistroName) throws(MawError) -> any ImportingMachine

    /// Imports distributions from archives (docs/daemon.md, "Importing a distribution").
    ///
    /// The steps run in order: prepare (a new disk and the provisioning machine), format,
    /// extract (`ImportStream` decompresses the client's archive on the Mac, and `bsdtar`
    /// extracts it in the guest), inspect (the checks of the root file system, and the choice
    /// of its default user), configure, finish, register, start. Until the registration,
    /// everything lives in a staging directory; on a refusal, a failure, or a cancellation the
    /// provisioning machine is stopped and the directory removed. The import holds its name
    /// from the check to the end of the first start, as an installation does.
    public struct Importer: Sendable {
        private let store: DistributionStore
        private let operations: DistributionOperations
        private let makeMachine: ImportingMachineFactory
        private let freeSpace: FreeSpaceProbe
        private let startMachine: @Sendable (MachineID) async throws(MawError) -> Void
        private let makeMACAddress: @Sendable () -> String
        private let registered: @Sendable () async -> Void
        private let logDirectory: URL
        private let log: DaemonLog

        /// - Parameters:
        ///   - registered: Called once the distribution is registered, before its first start,
        ///     so that watchers see it.
        ///   - logDirectory: Where the distribution's console log goes, which a failed first
        ///     start names.
        public init(
            store: DistributionStore, operations: DistributionOperations,
            makeMachine: @escaping ImportingMachineFactory,
            freeSpace: @escaping FreeSpaceProbe,
            startMachine: @escaping @Sendable (MachineID) async throws(MawError) -> Void,
            makeMACAddress: @escaping @Sendable () -> String,
            registered: @escaping @Sendable () async -> Void = {}, logDirectory: URL,
            log: DaemonLog = DaemonLog()
        ) {
            self.store = store
            self.operations = operations
            self.makeMachine = makeMachine
            self.freeSpace = freeSpace
            self.startMachine = startMachine
            self.makeMACAddress = makeMACAddress
            self.registered = registered
            self.logDirectory = logDirectory
            self.log = log
        }

        /// Imports the archive that `source` reads, which this takes over and closes before it
        /// returns. Cancelling the calling task before the registration cancels the import and
        /// removes its traces before this throws `importCancelled`.
        public func `import`(
            _ request: ImportRequest, from source: OwnedDescriptor, for processID: Int32,
            progress: @escaping @Sendable (InstallProgress) -> Void
        ) async throws(MawError) -> ImportSummary {
            defer { source.close() }
            let started = ContinuousClock.now
            guard request.hasValidArchive else {
                throw .daemonProtocolError(
                    reason: "the import request names its archive neither by an absolute path "
                        + "nor as standard input")
            }
            let name = request.name
            try Installer.checkNewName(name, store: store, operations: operations, for: .import)
            if let user = request.user {
                _ = try UserName(user)
            }
            try checkFreeSpace(for: source)
            let claim = try operations.claim(name, for: .import)
            defer { operations.release(claim) }
            log.notice(
                "\(name): import started for process \(processID) from "
                    + Self.loggable(request.archive))

            let staging = store.stagingDirectory(for: name)
            let outcome: (metadata: DistroMetadata, choice: DefaultUserChoice, bytes: UInt64)
            let isDefault: Bool
            do throws(MawError) {
                let machine = try makeMachine(name)
                // The steps' errors travel out of the handler as a Result, as the installer's
                // do (Installer.provision).
                let result:
                    Result<
                        (metadata: DistroMetadata, choice: DefaultUserChoice, bytes: UInt64),
                        MawError
                    > =
                        await withTaskCancellationHandler {
                            do throws(MawError) {
                                return .success(
                                    try await steps(
                                        request, name: name, source: source, staging: staging,
                                        machine: machine, progress: progress))
                            } catch {
                                return .failure(error)
                            }
                        } onCancel: {
                            Task { await machine.discard() }
                        }
                outcome = try result.get()
                try checkCancellation(name)
                isDefault = try store.register(staging: staging, metadata: outcome.metadata)
            } catch {
                store.removeStagingDirectory(staging)
                if Task.isCancelled {
                    log.notice(
                        "\(name): import for process \(processID) cancelled; its files were removed"
                    )
                    throw .importCancelled(name)
                }
                let mapped = Self.importError(error, of: name)
                log.error("\(name): import for process \(processID) failed: \(mapped.description)")
                throw mapped
            }

            log.notice(
                "\(name): imported \(outcome.bytes) bytes; default user \(outcome.choice.user) "
                    + "from \(outcome.choice.source.rawValue)")
            await registered()
            // The first boot is part of the import, so that the first session is warm. A
            // failure here does not undo the registration; the reply reports it.
            var firstStartFailure: MawError?
            progress(.started(.start))
            let starting = ContinuousClock.now
            do throws(MawError) {
                try await startMachine(.distribution(name))
            } catch {
                log.error("\(name): the first start failed: \(error.description)")
                firstStartFailure = .importStartFailed(
                    name,
                    consoleLog: MawPaths.consoleLogFile(
                        forMachineNamed: name.rawValue, in: logDirectory
                    ).path(percentEncoded: false), reason: error.description)
            }
            if firstStartFailure == nil {
                progress(.finished(.start, milliseconds: Self.milliseconds(since: starting)))
            }
            return ImportSummary(
                name: name, defaultUser: outcome.choice.user,
                defaultUserSource: outcome.choice.source, isDefault: isDefault,
                extractedBytes: outcome.bytes, milliseconds: Self.milliseconds(since: started),
                firstStartFailure: firstStartFailure)
        }

        // MARK: Steps

        private func steps(
            _ request: ImportRequest, name: DistroName, source: OwnedDescriptor, staging: URL,
            machine: any ImportingMachine, progress: @escaping @Sendable (InstallProgress) -> Void
        ) async throws(MawError) -> (
            metadata: DistroMetadata, choice: DefaultUserChoice, bytes: UInt64
        ) {
            let disk = staging.appending(path: "disk.img")
            let bytes: UInt64
            let choice: DefaultUserChoice
            do throws(MawError) {
                try await timed(.prepare, progress: progress) { () throws(MawError) in
                    try store.createStagingDirectory(staging)
                    try DiskImage.createSparse(at: disk, size: Installer.diskSize)
                    try await machine.boot(disk: disk)
                }
                try checkCancellation(name)
                try await timed(.format, progress: progress) { () throws(MawError) in
                    try await machine.format()
                }
                try checkCancellation(name)
                bytes = try await timed(.extract, progress: progress) {
                    () throws(MawError) -> UInt64 in
                    switch try await machine.extract(archive: source) {
                    case .extracted(let bytes): return bytes
                    case .notATarArchive: throw .importNotATarArchive(name)
                    }
                }
                try checkCancellation(name)
                let mawConf: String?
                (choice, mawConf) = try await timed(.inspect, progress: progress) {
                    () throws(MawError) -> (DefaultUserChoice, String?) in
                    try await inspect(request, name: name, machine: machine)
                }
                try checkCancellation(name)
                try await timed(.configure, progress: progress) { () throws(MawError) in
                    if let unresolvable = try await machine.configureImport(
                        hostname: Installer.hostname(for: name), defaultUser: choice,
                        mawConf: mawConf)
                    {
                        throw .importPathNotResolvable(
                            name, path: unresolvable.path, reason: unresolvable.reason)
                    }
                }
                try checkCancellation(name)
                try await timed(.finish, progress: progress) { () throws(MawError) in
                    try await machine.finish()
                }
            } catch {
                await machine.discard()
                throw error
            }
            let metadata = DistroMetadata(
                name: name, importedFrom: .init(archive: request.archive), createdAt: Date(),
                defaultUser: choice.user, diskSize: Installer.diskSize.bytes,
                macAddress: makeMACAddress())
            return (metadata, choice, bytes)
        }

        /// Checks the extracted root file system, reads the files that choose its default user,
        /// and returns the choice and the new text of `/etc/maw.conf`, or `nil` if the file
        /// already names the user.
        private func inspect(
            _ request: ImportRequest, name: DistroName, machine: any ImportingMachine
        ) async throws(MawError) -> (DefaultUserChoice, String?) {
            let report = ImportInspection.Report(parsing: try await machine.inspect())
            try report.evaluate(for: name)
            let files = report.files
            guard let passwdPath = files[.passwd] else {
                // evaluate(for:) refuses a root without /etc/passwd.
                throw .importNotARootFileSystem(name, found: "it has no etc/passwd")
            }
            let passwd = try await machine.readFile(passwdPath)
            var mawConf: String?
            if let path = files[.mawConf] {
                mawConf = try await machine.readFile(path)
            }
            var wslConf: String?
            if let path = files[.wslConf] {
                wslConf = try await machine.readFile(path)
            }
            let choice = try DefaultUserChoice.choose(
                option: request.user, mawConf: mawConf, wslConf: wslConf, passwd: passwd)
            return (choice, MawConf.settingDefaultUser(choice.user, in: mawConf ?? ""))
        }

        /// Runs `body` between a `started` and a `finished` event, and logs its duration.
        private func timed<T>(
            _ step: InstallStep, progress: @escaping @Sendable (InstallProgress) -> Void,
            _ body: () async throws(MawError) -> T
        ) async throws(MawError) -> T {
            progress(.started(step))
            let started = ContinuousClock.now
            let result = try await body()
            let milliseconds = Self.milliseconds(since: started)
            progress(.finished(step, milliseconds: milliseconds))
            log.notice("import step \(step.rawValue): \(milliseconds) ms")
            return result
        }

        private func checkCancellation(_ name: DistroName) throws(MawError) {
            if Task.isCancelled {
                throw .importCancelled(name)
            }
        }

        /// Checks the free space for the archive that `source` reads (`ImportSpace`): from its
        /// size and its first bytes when it is a regular file, read with `pread` from its
        /// current offset so that the offset stays where the client left it.
        private func checkFreeSpace(for source: OwnedDescriptor) throws(MawError) {
            let archive = Self.archiveSize(of: source.rawValue)
            let required = ImportSpace.required(
                archiveSize: archive.size, compression: archive.compression)
            // The distributions live on the volume of the user's home.
            guard let space = freeSpace(store.paths.homeDirectory) else { return }
            try InstallSpace.check(
                required: required, available: ByteSize(bytes: space.available),
                volume: space.volume, for: .import)
        }

        /// The size of the archive that `descriptor` reads from its current offset, and its
        /// compression, or `nil` and `.other` for a pipe, a socket, or anything else that is
        /// not a regular file.
        static func archiveSize(of descriptor: Int32) -> (
            size: UInt64?, compression: ImportSpace.Compression
        ) {
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
                return (nil, .other)
            }
            let offset = max(0, lseek(descriptor, 0, SEEK_CUR))
            var first = [UInt8](repeating: 0, count: ImportSpace.inspectedByteCount)
            let count = first.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, $0.count, offset)
            }
            let size = UInt64(max(0, status.st_size - offset))
            return (size, ImportSpace.compression(ofFirstBytes: Array(first.prefix(max(0, count)))))
        }

        // MARK: Errors

        /// A provisioning step's failure, named as the import's.
        static func importError(_ error: MawError, of name: DistroName) -> MawError {
            if case .provisioningFailed(let step, let reason) = error {
                return .importFailed(name, step: step, reason: reason)
            }
            return error
        }

        /// `archive` for `mawd.log`: control characters escaped, so that a file name cannot
        /// add lines to the log.
        static func loggable(_ archive: String) -> String {
            var result = ""
            for scalar in archive.unicodeScalars {
                if scalar.properties.generalCategory == .control {
                    result += scalar.escaped(asASCII: true)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
            return result
        }

        private static func milliseconds(since start: ContinuousClock.Instant) -> UInt64 {
            UInt64(max(0, (ContinuousClock.now - start).milliseconds))
        }
    }
#endif
