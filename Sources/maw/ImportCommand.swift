import Darwin
import Foundation
import MawClient
import MawCore
import MawTerminalIO
import MawXPC

/// `maw --import <distro> <file> [-u <user>]`: has the daemon create a distribution from the
/// tar archive in `<file>`, or from standard input for `-`.
///
/// maw opens the file itself and hands the open descriptor to the daemon, which, as a
/// LaunchAgent, lacks the user's privacy permissions for folders such as `~/Desktop`. The daemon
/// records where the archive came from, the path of the file that maw opened, but never opens
/// it.
///
/// Progress goes to standard error, one line per step, redrawn in place only on a terminal, as
/// `--install` shows it. Ctrl-C asks the daemon to cancel; an import that has already registered
/// its distribution finishes. The last lines name the distribution and the user that its
/// sessions run as. When the first start fails, the distribution stays installed, and maw prints
/// the start's error, which names the console log, and exits with a failure status.
struct ImportCommand {
    let name: DistroName
    let file: String
    let user: String?
    /// Connects to the daemon. The tests replace it.
    var connect: @Sendable () async throws(MawError) -> any ImportDaemon = {
        () async throws(MawError) -> any ImportDaemon in
        try await DaemonClient.connect()
    }
    /// Whether standard input is a terminal, and open for reading. The tests replace them.
    var inputIsTerminal: Bool = isatty(STDIN_FILENO) == 1
    var inputIsReadable: Bool = {
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        return flags >= 0 && flags & O_ACCMODE != O_WRONLY
    }()
    var errorIsTerminal: Bool = isatty(STDERR_FILENO) == 1
    /// Opens the archive. The tests replace it.
    var openArchive: @Sendable (String) throws(MawError) -> ArchiveSource = {
        file throws(MawError) in
        try ArchiveSource.open(file)
    }
    /// Where the text goes. The tests replace it.
    var output = OutputQueue()

    /// How long maw waits for the daemon to confirm a cancellation.
    static let cancelTimeout = Duration.seconds(5)

    func run() async throws -> Int32 {
        let signals = SignalMonitor([SIGINT, SIGTERM, SIGHUP])
        return try await run(signals: signals.signals)
    }

    func run(signals: AsyncStream<Int32>) async throws -> Int32 {
        if let user {
            _ = try UserName(user)
        }
        if file == "-", inputIsTerminal {
            throw MawError.importFromTerminal
        }
        if file == "-", !inputIsReadable {
            throw MawError.importInputNotReadable
        }
        let archive = try openArchive(file)
        defer { archive.close() }
        let client = try await connect()
        defer { client.close() }
        let view = InstallProgressView(
            text: InstallProgressText(name: name, displayName: "", operation: .import),
            isTerminal: errorIsTerminal, output: output.writeError)
        let request = ImportRequest(name: name, user: user, archive: archive.description)
        let descriptor = archive.descriptor
        let running = Task { () -> Result<ImportSummary, MawError> in
            do throws(MawError) {
                return .success(try await client.import(request, from: descriptor))
            } catch {
                return .failure(error)
            }
        }

        switch await Self.firstOutcome(
            of: running, events: client.events, view: view, signals: signals)
        {
        case .imported(let summary):
            view.interrupt()
            return await finish(summary)
        case .failed(let error):
            view.interrupt()
            await output.waitUntilWritten()
            throw error
        case .signal(let number):
            view.interrupt()
            output.writeError("Cancelling the import...\n")
            await Self.cancel(on: client)
            // An import that had registered its distribution before the cancellation reached it
            // finishes, and its reply says so (`OperationReply`).
            if case .success(let summary) = await OperationReply.reply(
                of: running, timeout: .milliseconds(500))
            {
                return await finish(summary)
            }
            output.writeError(Maw.failure(for: MawError.importCancelled(name))?.output ?? "")
            await output.waitUntilWritten(timeout: .milliseconds(250))
            return 128 + number
        }
    }

    /// Prints the result, or the first start's failure, and returns the exit status.
    private func finish(_ summary: ImportSummary) async -> Int32 {
        output.write("\n" + Self.summary(summary) + "\n")
        if let failure = summary.firstStartFailure {
            output.writeError(Maw.failure(for: failure)?.output ?? "")
            await output.waitUntilWritten()
            return 1
        }
        await output.waitUntilWritten()
        return 0
    }

    /// The last lines: the new distribution, whether it is the default, and the user that its
    /// sessions run as; with `root` because nothing named another user, how to choose one.
    static func summary(_ summary: ImportSummary) -> String {
        let role = summary.isDefault ? ", and is the default distribution" : ""
        let open = summary.isDefault ? "Run maw" : "Run maw -d \(summary.name)"
        var text =
            "\(summary.name) is imported\(role).\n\(open) to open a shell as "
            + "\(summary.defaultUser)."
        if summary.defaultUserSource == .fallback {
            text +=
                "\nThe archive names no other default user. To choose one, run\n"
                + "maw --unregister \(summary.name), then maw --import \(summary.name) <file> "
                + "-u <user>."
        }
        return text
    }

    enum Outcome {
        case imported(ImportSummary)
        case failed(MawError)
        case signal(Int32)
    }

    /// Waits for the import to end or a signal, showing progress meanwhile.
    static func firstOutcome(
        of running: Task<Result<ImportSummary, MawError>, Never>,
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
                switch await running.value {
                case .success(let summary):
                    await view.waitUntilIdle(timeout: .milliseconds(500))
                    first.settle(.imported(summary))
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
                        first.settle(.failed(.daemonConnectionLost(during: "the import")))
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
    /// import's own reply then says how it ended.
    static func cancel(on client: any ImportDaemon) async {
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

/// The archive that `maw --import` reads: a file that it opens, or standard input for `-`.
struct ArchiveSource: Sendable {
    let descriptor: Int32
    /// What `distro.json` records: the absolute path of the opened file, or "standard input".
    let description: String
    /// Whether maw opened the descriptor and closes it.
    let isOwned: Bool

    /// Opens `file` for reading. A file that cannot be opened, a directory, or a terminal is
    /// refused here, before the daemon is asked.
    static func open(_ file: String) throws(MawError) -> ArchiveSource {
        guard file != "-" else {
            return ArchiveSource(
                descriptor: STDIN_FILENO,
                description: DistroMetadata.ImportOrigin.standardInput, isOwned: false)
        }
        let descriptor = Darwin.open(file, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw .importArchiveNotReadable(path: file, reason: String(cString: strerror(errno)))
        }
        var status = stat()
        if fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR {
            Darwin.close(descriptor)
            throw .importArchiveNotReadable(path: file, reason: "it is a directory")
        }
        if isatty(descriptor) == 1 {
            Darwin.close(descriptor)
            throw .importFromTerminal
        }
        return ArchiveSource(
            descriptor: descriptor, description: path(of: descriptor, opened: file),
            isOwned: true)
    }

    /// The path of the file that `descriptor` reads, as the kernel names it, or `file` made
    /// absolute against the current directory if the kernel names none.
    static func path(of descriptor: Int32, opened file: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if fcntl(descriptor, F_GETPATH, &buffer) == 0 {
            let length = buffer.firstIndex(of: 0) ?? buffer.count
            let path = String(
                decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if path.hasPrefix("/") {
                return path
            }
        }
        if file.hasPrefix("/") {
            return file
        }
        let directory = FileManager.default.currentDirectoryPath
        return URL(filePath: directory, directoryHint: .isDirectory).appending(path: file)
            .standardized.path(percentEncoded: false)
    }

    func close() {
        if isOwned {
            Darwin.close(descriptor)
        }
    }
}

/// What `maw --import` needs from the daemon. The tests supply a fake.
protocol ImportDaemon: Sendable {
    var events: AsyncStream<DaemonClient.Event> { get }
    func `import`(_ request: ImportRequest, from descriptor: Int32) async throws(MawError)
        -> ImportSummary
    func cancel() async throws(MawError) -> Bool
    func close()
}

extension DaemonClient: ImportDaemon {}
