import Darwin
import Foundation
import MawClient
import MawCore
import MawTerminalIO
import MawXPC

/// `maw --export <distro> <file> [--format <format>]`: has the daemon write a stopped
/// distribution's root file system to `<file>`, or to standard output for `-`.
///
/// maw opens the file itself and hands the open descriptor to the daemon, which, as a
/// LaunchAgent, lacks the user's privacy permissions for folders such as `~/Desktop`. The file
/// is created only after the daemon has accepted the export, so that a refused export creates
/// none, with mode 600, because the archive holds `/etc/shadow` and every user's files, and
/// never replaces an existing file. It is removed again when the export fails or is cancelled.
///
/// Progress goes to standard error, one line per step, redrawn in place only on a terminal, so
/// that `-` keeps standard output for the archive alone. Ctrl-C asks the daemon to cancel, as
/// `--install` does.
struct ExportCommand {
    let name: DistroName
    let file: String
    let format: ArchiveFormat
    /// Connects to the daemon. The tests replace it.
    var connect: @Sendable () async throws(MawError) -> any ExportDaemon = {
        () async throws(MawError) -> any ExportDaemon in
        try await DaemonClient.connect()
    }
    /// Whether standard output and standard error are terminals. The tests replace them.
    var outputIsTerminal: Bool = isatty(STDOUT_FILENO) == 1
    /// Whether standard output is open for writing. The tests replace it.
    var outputIsWritable: Bool = {
        let flags = fcntl(STDOUT_FILENO, F_GETFL)
        return flags >= 0 && flags & O_ACCMODE != O_RDONLY
    }()
    var errorIsTerminal: Bool = isatty(STDERR_FILENO) == 1
    /// Where the text goes. The tests replace it.
    var output = OutputQueue()

    /// How long maw waits for the daemon to confirm a cancellation.
    static let cancelTimeout = Duration.seconds(5)

    func run() async throws -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let signals = SignalMonitor([SIGINT, SIGTERM, SIGHUP])
        return try await run(signals: signals.signals)
    }

    func run(signals: AsyncStream<Int32>) async throws -> Int32 {
        if file == "-", outputIsTerminal {
            throw MawError.exportToTerminal
        }
        if file == "-", !outputIsWritable {
            throw MawError.exportOutputNotWritable
        }
        let client = try await connect()
        defer { client.close() }
        let stored = try await client.checkExport(name)
        let archive = try ArchiveFile.create(file)
        let view = InstallProgressView(
            text: InstallProgressText(name: stored, displayName: "", operation: .export),
            isTerminal: errorIsTerminal, output: output.writeError)
        let request = ExportRequest(name: stored, format: format)
        let export = Task { () -> Result<ExportSummary, MawError> in
            do throws(MawError) {
                return .success(try await client.export(request, to: archive.descriptor))
            } catch {
                return .failure(error)
            }
        }

        switch await Self.firstOutcome(
            export: export, events: client.events, view: view, signals: signals)
        {
        case .exported(let summary):
            view.interrupt()
            archive.keep()
            output.writeError(Self.summary(summary, file: file) + "\n")
            await output.waitUntilWritten()
            return 0
        case .failed(let error):
            view.interrupt()
            archive.remove()
            await output.waitUntilWritten()
            throw error
        case .signal(let number):
            view.interrupt()
            output.writeError("Cancelling the export...\n")
            await Self.cancel(on: client)
            // An export whose archive was complete before the cancellation reached it succeeds,
            // also when the cancellation came while its machine stopped; its reply has been sent
            // by then, but may still be on its way (`OperationReply`). The file is then complete,
            // and maw keeps it.
            if case .success(let summary) = await OperationReply.reply(
                of: export, timeout: .milliseconds(500))
            {
                archive.keep()
                output.writeError(Self.summary(summary, file: file) + "\n")
                await output.waitUntilWritten()
                return 0
            }
            // Without a confirmation the daemon may still be writing; the file goes in any
            // case, and the daemon ends the export when this connection closes.
            archive.remove()
            output.writeError(Maw.failure(for: MawError.exportCancelled(stored))?.output ?? "")
            await output.waitUntilWritten(timeout: .milliseconds(250))
            return 128 + number
        }
    }

    /// The last line: the distribution, where it went, and the archive's size.
    static func summary(_ summary: ExportSummary, file: String) -> String {
        let place = file == "-" ? "standard output" : file
        return "\(summary.name) was exported to \(place): "
            + "\(ByteSize(bytes: summary.bytes).approximateDescription)."
    }

    enum Outcome {
        case exported(ExportSummary)
        case failed(MawError)
        case signal(Int32)
    }

    /// Waits for the export to end or a signal, showing progress meanwhile.
    static func firstOutcome(
        export: Task<Result<ExportSummary, MawError>, Never>,
        events: AsyncStream<DaemonClient.Event>, view: InstallProgressView,
        signals: AsyncStream<Int32>
    ) async -> Outcome {
        let first = FirstResult<Outcome>()
        return await withCheckedContinuation { continuation in
            first.onResult { outcome in
                view.stop()
                continuation.resume(returning: outcome)
            }
            Task {
                switch await export.value {
                case .success(let summary):
                    await view.waitUntilIdle(timeout: .milliseconds(500))
                    first.settle(.exported(summary))
                case .failure(let error):
                    first.settle(.failed(error))
                }
            }
            Task {
                for await event in events {
                    switch event {
                    case .installProgress(let progress):
                        view.show(progress)
                    case .connectionLost:
                        first.settle(.failed(.daemonConnectionLost(during: "the export")))
                    case .sessionEnded:
                        continue
                    }
                }
            }
            Task {
                for await number in signals {
                    first.settle(.signal(number))
                    return
                }
            }
        }
    }

    /// Asks the daemon to cancel, and waits at most `cancelTimeout` for its answer; the
    /// export's own reply then says how it ended.
    static func cancel(on client: any ExportDaemon) async {
        let first = FirstResult<Void>()
        await withCheckedContinuation { continuation in
            first.onResult { continuation.resume() }
            Task {
                _ = try? await client.cancel()
                first.settle(())
            }
            Task {
                try? await Task.sleep(for: cancelTimeout)
                first.settle(())
            }
        }
    }
}

/// The archive's file, which `maw --export` creates and removes again if the export does not
/// complete, or standard output for `-`.
struct ArchiveFile {
    let descriptor: Int32
    /// The file's path and identity, or `nil` for standard output.
    private let created: (path: String, device: dev_t, inode: ino_t)?

    /// Creates `file` for writing, with mode 600, and never through an existing entry: a file,
    /// a directory, or a symbolic link, dangling or not, makes it fail with `exportFileExists`.
    static func create(_ file: String) throws(MawError) -> ArchiveFile {
        guard file != "-" else {
            return ArchiveFile(descriptor: STDOUT_FILENO, created: nil)
        }
        let descriptor = open(file, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            let code = errno
            if code == EEXIST {
                throw .exportFileExists(path: file)
            }
            throw .fileNotAccessible(path: file, reason: String(cString: strerror(code)))
        }
        // The umask can only remove permissions, but a mode is set explicitly all the same.
        _ = fchmod(descriptor, 0o600)
        var status = stat()
        _ = fstat(descriptor, &status)
        return ArchiveFile(
            descriptor: descriptor, created: (file, status.st_dev, status.st_ino))
    }

    /// Keeps the complete archive.
    func keep() {
        if created != nil {
            close(descriptor)
        }
    }

    /// Removes the file, if its path still names the file that `create` made, and closes it.
    func remove() {
        guard let created else { return }
        var status = stat()
        if lstat(created.path, &status) == 0, status.st_dev == created.device,
            status.st_ino == created.inode
        {
            unlink(created.path)
        }
        close(descriptor)
    }
}

/// What `maw --export` needs from the daemon. The tests supply a fake.
protocol ExportDaemon: Sendable {
    var events: AsyncStream<DaemonClient.Event> { get }
    func checkExport(_ name: DistroName) async throws(MawError) -> DistroName
    func export(_ request: ExportRequest, to descriptor: Int32) async throws(MawError)
        -> ExportSummary
    func cancel() async throws(MawError) -> Bool
    func close()
}

extension DaemonClient: ExportDaemon {}
