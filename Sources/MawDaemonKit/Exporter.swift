#if os(macOS)
    import Foundation
    import MawCore
    import MawProtocol
    import MawXPC

    /// The machine that reads a distribution's disk for an export: the initramfs with the disk
    /// attached, as at installation. `VirtualProvisioningMachine` is the real one.
    public protocol ExportingMachine: Sendable {
        func boot(disk: URL) async throws(MawError)
        /// Runs the root file system's check that a start runs, and returns its marker.
        func checkFileSystem() async throws(MawError) -> RootFileSystemCheck
        /// Mounts the checked disk read-only.
        func mountReadOnly() async throws(MawError)
        /// Writes the root file system as a pax archive to `consume`, which returns false to
        /// stop it.
        func archive(into consume: @escaping @Sendable (UnsafeRawBufferPointer) -> Bool)
            async throws(MawError)
        /// Unmounts the disk and powers the machine off.
        func finish() async throws(MawError)
        /// Stops the machine at once. Used on failure and cancellation.
        func discard() async
    }

    /// Creates the machine that exports the distribution `name`.
    public typealias ExportingMachineFactory =
        @Sendable (DistroName) throws(MawError) -> any ExportingMachine

    /// Exports installed distributions (docs/daemon.md, "Exporting a distribution").
    ///
    /// The steps run in order: prepare (the provisioning machine boots with the distribution's
    /// disk attached), check (`maw-check-root`, as at a start, and a read-only mount), archive
    /// (`bsdtar -c` in the guest, compressed on the Mac if asked, written to the client's
    /// descriptor), and finish (the machine stops). While it runs, the export holds the
    /// distribution's name, so that its machine does not start and no removal or second export
    /// begins. Cancelling the calling task stops the machine at once and ends the archive.
    public struct Exporter: Sendable {
        private let store: DistributionStore
        private let operations: DistributionOperations
        private let makeMachine: ExportingMachineFactory
        private let isStopped: @Sendable (MachineID) async -> Bool
        private let logDirectory: URL
        private let log: DaemonLog

        /// - Parameters:
        ///   - isStopped: Whether a machine is stopped; the registry's `isStopped(_:)`.
        ///   - logDirectory: Where the export's console log goes, in `export/<name>.log`.
        public init(
            store: DistributionStore, operations: DistributionOperations,
            makeMachine: @escaping ExportingMachineFactory,
            isStopped: @escaping @Sendable (MachineID) async -> Bool, logDirectory: URL,
            log: DaemonLog = DaemonLog()
        ) {
            self.store = store
            self.operations = operations
            self.makeMachine = makeMachine
            self.isStopped = isStopped
            self.logDirectory = logDirectory
            self.log = log
        }

        /// Checks that `requested` names an installed distribution, matched without regard to
        /// case, that no other operation holds and whose machine is stopped. Returns its stored
        /// spelling.
        public func check(_ requested: DistroName) async throws(MawError) -> DistroName {
            let name = try installedName(requested)
            try operations.check(name, for: .export)
            guard await isStopped(.distribution(name)) else {
                throw .distributionRunning(name)
            }
            return name
        }

        /// Exports the distribution to `destination`, which this takes over and closes before it
        /// returns, so that the client may remove its file once the reply has arrived.
        public func export(
            _ request: ExportRequest, to destination: OwnedDescriptor, for processID: Int32,
            progress: @escaping @Sendable (InstallProgress) -> Void
        ) async throws(MawError) -> ExportSummary {
            defer { destination.close() }
            let started = ContinuousClock.now
            let name = try installedName(request.name)
            let claim = try operations.claim(name, for: .export)
            defer { operations.release(claim) }
            // With the name held, no start can follow this check (MachineRegistry.start(_:)).
            guard await isStopped(.distribution(name)) else {
                throw .distributionRunning(name)
            }
            log.notice(
                "\(name): export as \(request.format.rawValue) started for process \(processID)")

            let bytes: UInt64
            do throws(MawError) {
                let output: ArchiveOutput
                do throws(ArchiveOutput.Failure) {
                    output = try ArchiveOutput(format: request.format, destination: destination)
                } catch {
                    throw Self.error(for: error, of: name)
                }
                let machine = try makeMachine(name)
                // The steps' errors travel out of the handler as a Result, as the installer's
                // do (Installer.provision).
                let result: Result<UInt64, MawError> = await withTaskCancellationHandler {
                    do throws(MawError) {
                        return .success(
                            try await steps(
                                name: name, machine: machine, output: output, progress: progress))
                    } catch {
                        return .failure(error)
                    }
                } onCancel: {
                    output.abort()
                    Task { await machine.discard() }
                }
                bytes = try result.get()
            } catch {
                if Task.isCancelled {
                    log.notice("\(name): export for process \(processID) cancelled")
                    throw .exportCancelled(name)
                }
                let mapped = Self.exportError(error, of: name)
                log.error("\(name): export for process \(processID) failed: \(mapped.description)")
                throw mapped
            }
            let milliseconds = UInt64(max(0, (ContinuousClock.now - started).milliseconds))
            log.notice(
                "\(name): exported \(bytes) bytes as \(request.format.rawValue) in "
                    + "\(milliseconds) ms for process \(processID)")
            return ExportSummary(
                name: name, format: request.format, bytes: bytes, milliseconds: milliseconds)
        }

        // MARK: Steps

        private func steps(
            name: DistroName, machine: any ExportingMachine, output: ArchiveOutput,
            progress: @escaping @Sendable (InstallProgress) -> Void
        ) async throws(MawError) -> UInt64 {
            var bytes: UInt64 = 0
            do throws(MawError) {
                try await timed(.prepare, progress: progress) { () throws(MawError) in
                    try await machine.boot(disk: store.paths.diskImage(for: name))
                }
                try checkCancellation(name)
                try await timed(.check, progress: progress) { () throws(MawError) in
                    let check = try await machine.checkFileSystem()
                    guard check.allowsBoot else {
                        throw .rootFileSystemCheckFailed(
                            distribution: name, e2fsckStatus: check.e2fsckStatus,
                            diskImage: store.paths.diskImage(for: name).path(percentEncoded: false),
                            consoleLog: MawPaths.exportLogFile(for: name, in: logDirectory)
                                .path(percentEncoded: false))
                    }
                    try await machine.mountReadOnly()
                }
                try checkCancellation(name)
                bytes = try await timed(.archive, progress: progress) {
                    () throws(MawError) -> UInt64 in
                    var archiveError: MawError?
                    do throws(MawError) {
                        try await machine.archive { output.write($0) }
                    } catch {
                        archiveError = error
                    }
                    // The archive's own failure, such as a reader that closed its pipe, comes
                    // first: it is why bsdtar was stopped.
                    let outcome = await output.finish()
                    if let failure = outcome.failure {
                        throw Self.error(for: failure, of: name)
                    }
                    if let archiveError {
                        throw archiveError
                    }
                    return outcome.bytes
                }
            } catch {
                output.abort()
                _ = await output.finish()
                await machine.discard()
                throw error
            }
            // The archive is complete and its descriptor closed. A cancellation from here on, or a
            // machine that does not stop cleanly, does not undo it: the disk was mounted
            // read-only, so stopping the machine at once loses nothing.
            do throws(MawError) {
                try await timed(.finish, progress: progress) { () throws(MawError) in
                    try await machine.finish()
                }
            } catch {
                log.error(
                    "\(name): the export's machine did not stop cleanly, and was stopped at once: "
                        + error.description)
                await machine.discard()
            }
            return bytes
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
            log.notice("export step \(step.rawValue): \(milliseconds) ms")
            return result
        }

        private func checkCancellation(_ name: DistroName) throws(MawError) {
            if Task.isCancelled {
                throw .exportCancelled(name)
            }
        }

        private func installedName(_ requested: DistroName) throws(MawError) -> DistroName {
            guard let metadata = try store.installedDistribution(named: requested) else {
                throw .distributionNotInstalled(requested)
            }
            return metadata.name
        }

        // MARK: Errors

        /// The error of a failed archive write.
        static func error(for failure: ArchiveOutput.Failure, of name: DistroName) -> MawError {
            switch failure {
            case .readerClosed:
                .exportOutputClosed(name)
            case .writeFailed(let reason):
                .exportFailed(name, step: "writing the archive", reason: reason)
            case .compressorFailed(let reason):
                .exportFailed(name, step: "compressing the archive", reason: reason)
            case .aborted:
                .exportCancelled(name)
            }
        }

        /// A provisioning step's failure, named as the export's.
        static func exportError(_ error: MawError, of name: DistroName) -> MawError {
            if case .provisioningFailed(let step, let reason) = error {
                return .exportFailed(name, step: step, reason: reason)
            }
            return error
        }
    }
#endif
