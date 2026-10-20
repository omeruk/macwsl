import ArgumentParser
import Darwin
import Foundation
import MacWSLCore
import MacWSLVirtualization

/// `macwsld debug-boot`: boots the guest kernel and initramfs for development.
struct DebugBoot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug-boot",
        abstract: "Boot the guest kernel and initramfs in a virtual machine (development tool).",
        discussion: """
            Boots Image and initramfs.cpio.gz from the kernel directory with \
            Virtualization.framework, copies the guest console to standard output, and waits \
            until the guest powers off. The console is also written to \
            ~/Library/Logs/MacWSL/debug-boot-console.log. SIGINT and SIGTERM stop the virtual \
            machine first.

            With --interactive, the terminal is connected to the guest console. Ctrl-C is passed \
            to the guest. To stop the virtual machine and detach, type ~. at the start of a line \
            (after Enter), or press the detach key, Ctrl-] by default. ~? lists the escape \
            sequences, and ~~ sends a single ~. The ~ sequences work on every keyboard layout; \
            Ctrl-] needs the Option key on many non-US layouts.

            The executable must be signed with the virtualization entitlement. Build it with \
            scripts/sign-dev.sh, which builds and signs; a plain swift build removes the \
            signature. scripts/fetch-guest.sh installs the kernel files.
            """
    )

    /// The virtual machine's name, which also names its console log.
    static let name = "debug-boot"
    /// How long `stop(timeout:)` waits for the guest after asking it to power off.
    static let stopTimeout = Duration.seconds(5)

    @Option(
        name: .customLong("kernel-dir"),
        help: ArgumentHelp(
            "Directory with Image, initramfs.cpio.gz, and manifest.json "
                + "(default: ~/Library/Application Support/MacWSL/kernel).",
            valueName: "dir"))
    var kernelDirectory: String?

    @Option(
        help: ArgumentHelp(
            "Kernel command-line arguments, appended to console=hvc0.", valueName: "string"))
    var cmdline: String?

    @Option(
        help: ArgumentHelp(
            "Number of virtual CPUs (default: the smaller of 4 and the number of host CPUs).",
            valueName: "n"))
    var cpus: Int?

    @Option(
        help: ArgumentHelp("Memory size, for example 512M or 4G (default: 2G).", valueName: "size"),
        transform: { try ByteSize(parsing: $0) })
    var memory: ByteSize?

    @Option(
        name: .customLong("disk"),
        help: ArgumentHelp(
            "Attach a raw disk image as the next virtio block device (/dev/vda, /dev/vdb, ...). "
                + "Repeatable.",
            valueName: "path"))
    var disks: [String] = []

    @Option(
        name: .customLong("create-disk"),
        help: ArgumentHelp(
            "Create each --disk image that does not exist as a sparse file of this size.",
            valueName: "size"),
        transform: { try ByteSize(parsing: $0) })
    var createDiskSize: ByteSize?

    @Flag(
        help: "Connect the terminal to the guest console. ~. at the start of a line detaches.")
    var interactive = false

    @Option(
        name: .customLong("detach-key"),
        help: ArgumentHelp(
            "The control key that detaches an interactive session, such as ^Q, or none "
                + "(default: ^]). ~. always works as well.",
            valueName: "key"),
        transform: { try DetachKey(parsing: $0) })
    var detachKey: DetachKey?

    @Option(
        help: ArgumentHelp(
            "Fail if the guest has not stopped within this many seconds. Not with --interactive.",
            valueName: "seconds"))
    var timeout: Int?

    func validate() throws {
        if interactive && timeout != nil {
            throw ValidationError("--timeout cannot be combined with --interactive.")
        }
        if detachKey != nil && !interactive {
            throw ValidationError("--detach-key needs --interactive.")
        }
        if createDiskSize != nil && disks.isEmpty {
            throw ValidationError("--create-disk needs at least one --disk.")
        }
        if let cpus, cpus < 1 {
            throw ValidationError("--cpus must be at least 1.")
        }
        if let timeout, timeout < 1 {
            throw ValidationError("--timeout must be at least 1 second.")
        }
    }

    func run() async throws {
        // Before anything else, so that nothing touches termios or starts a VM without a terminal.
        if interactive {
            try Terminal.requireTerminals()
        }

        let guest = try GuestFiles(directory: kernelDirectoryURL)
        report(guest.summary)

        let configuration = VMConfiguration(
            kernelURL: guest.kernelURL,
            initramfsURL: guest.initramfsURL,
            consoleLogURL: MacWSLPaths().logsDirectory.appending(path: "\(Self.name)-console.log"),
            cpuCount: cpus ?? VMConfiguration.defaultCPUCount(),
            memorySize: memory ?? VMConfiguration.defaultMemorySize,
            commandLine: VMConfiguration.commandLine(appending: cmdline),
            disks: try prepareDisks())
        reportLimits(of: configuration)
        report("console log: \(configuration.consoleLogURL.path(percentEncoded: false))")

        if interactive {
            try await runInteractive(configuration)
        } else {
            try await runAttached(configuration)
        }
    }

    var kernelDirectoryURL: URL {
        kernelDirectory.map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? MacWSLPaths().kernelDirectory
    }

    // MARK: Sessions

    /// What ended a session.
    enum Ending: Sendable {
        case guestStopped(VirtualMachine.State)
        case signal(Int32)
        case detached
        case timedOut
    }

    /// Prints the guest console to standard output and waits for the guest to stop, a signal,
    /// or the timeout.
    private func runAttached(_ configuration: VMConfiguration) async throws {
        let machine = try VirtualMachine(
            name: Self.name, configuration: configuration,
            consoleIO: .init(output: .standardOutput))
        let signals = SignalMonitor()
        let started = ContinuousClock.now
        let banner = Task { await Self.reportBanner(in: machine.consoleLines, since: started) }
        defer { banner.cancel() }

        try await machine.start()
        let ending = await Self.firstEnding(
            of: machine, signals: signals.signals, detach: nil,
            timeout: timeout.map { .seconds($0) })
        try await finish(machine, after: ending, started: started)
    }

    /// Connects the terminal to the guest console in raw mode until the guest stops, the user
    /// detaches (see `ConsoleEscapes`), or a signal arrives. The terminal is restored on every path (see `RawMode`).
    private func runInteractive(_ configuration: VMConfiguration) async throws {
        let toGuest = Pipe()
        let machine = try VirtualMachine(
            name: Self.name, configuration: configuration,
            consoleIO: .init(input: toGuest.fileHandleForReading, output: .standardOutput))
        let signals = SignalMonitor()
        let escapes = ConsoleEscapes(detachKey: detachKey ?? .default)
        report(escapes.instructions)

        let rawMode = try RawMode()
        defer { rawMode.restore() }
        let detach = Self.forwardStandardInput(to: toGuest.fileHandleForWriting, escapes: escapes)
        let started = ContinuousClock.now
        let banner = Task {
            await Self.reportBanner(in: machine.consoleLines, since: started, lineEnding: "\r\n")
        }
        defer { banner.cancel() }

        try await machine.start()
        let ending = await Self.firstEnding(
            of: machine, signals: signals.signals, detach: detach, timeout: nil)
        try await finish(machine, after: ending, started: started) {
            rawMode.restore()
        }
    }

    /// Stops the machine if it is still running, reports how the session ended, and turns the
    /// ending into the command's result. `beforeReport` runs once the machine has stopped.
    private func finish(
        _ machine: VirtualMachine, after ending: Ending, started: ContinuousClock.Instant,
        beforeReport: () -> Void = {}
    ) async throws {
        var outcome: VirtualMachine.StopOutcome?
        switch ending {
        case .guestStopped:
            break
        case .signal, .detached, .timedOut:
            outcome = try await machine.stop(timeout: Self.stopTimeout)
        }
        await machine.waitUntilStopped()
        beforeReport()

        if let outcome {
            // The guest was stopped while running, usually at its shell prompt, whose line
            // has no newline yet. Start the report on a line of its own.
            Self.writeToStandardError("\n")
            report(Self.describe(outcome))
        }
        report("vm: stopped after \((ContinuousClock.now - started).milliseconds) ms")
        switch ending {
        case .guestStopped(.error(let error)):
            throw error
        case .guestStopped, .detached:
            return
        case .signal(let number):
            throw ExitCode(128 + number)
        case .timedOut:
            throw MacWSLError.guestStopTimedOut(seconds: timeout ?? 0)
        }
    }

    /// Waits for whichever happens first: the guest stops, a signal, a detach, or the timeout.
    static func firstEnding(
        of machine: VirtualMachine,
        signals: AsyncStream<Int32>,
        detach: AsyncStream<Void>?,
        timeout: Duration?
    ) async -> Ending {
        await withTaskGroup(of: Ending?.self) { group in
            group.addTask {
                for await state in machine.states {
                    switch state {
                    case .stopped, .error: return .guestStopped(state)
                    case .starting, .running, .stopping: continue
                    }
                }
                return .guestStopped(await machine.state)
            }
            group.addTask {
                for await number in signals {
                    return .signal(number)
                }
                return nil
            }
            if let detach {
                group.addTask {
                    for await _ in detach {
                        return .detached
                    }
                    return nil
                }
            }
            if let timeout {
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return Task.isCancelled ? nil : .timedOut
                }
            }
            var ending: Ending = .guestStopped(.stopped)
            while let next = await group.next() {
                if let next {
                    ending = next
                    break
                }
            }
            group.cancelAll()
            return ending
        }
    }

    // MARK: Console

    /// Copies standard input to the guest, interpreting the escape sequences, until the user
    /// detaches. Returns a stream that yields once when the user detaches, or when standard
    /// input ends.
    private static func forwardStandardInput(
        to destination: FileHandle, escapes: ConsoleEscapes
    ) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        Thread {
            var escapes = escapes
            var buffer = [UInt8](repeating: 0, count: 1024)
            reading: while true {
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                for action in escapes.process(buffer[..<count]) {
                    switch action {
                    case .send(let bytes):
                        try? destination.write(contentsOf: Data(bytes))
                    case .showHelp:
                        // The terminal is in raw mode, which does not translate "\n".
                        writeToStandardError("\r\n" + escapes.help(lineEnding: "\r\n"))
                    case .detach:
                        break reading
                    }
                }
            }
            continuation.yield()
            continuation.finish()
        }.start()
        return stream
    }

    /// Prints `boot: banner after <n> ms` when the initramfs banner appears.
    static func reportBanner(
        in lines: AsyncStream<String>, since started: ContinuousClock.Instant,
        lineEnding: String = "\n"
    ) async {
        for await line in lines where isBanner(line) {
            let elapsed = (ContinuousClock.now - started).milliseconds
            writeToStandardError("boot: banner after \(elapsed) ms\(lineEnding)")
            return
        }
    }

    /// Whether `line` is the initramfs banner: `macwsl-initramfs <version> kernel=<release>`.
    static func isBanner(_ line: String) -> Bool {
        let fields = line.split(separator: " ")
        return fields.count == 3 && fields[0] == "macwsl-initramfs"
            && fields[2].hasPrefix("kernel=")
    }

    // MARK: Disks

    private func prepareDisks() throws(MacWSLError) -> [VMConfiguration.Disk] {
        var prepared: [VMConfiguration.Disk] = []
        for path in disks {
            let url = URL(filePath: path).standardizedFileURL
            if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                guard let createDiskSize else {
                    throw .diskImageNotFound(path: url.path(percentEncoded: false))
                }
                try DiskImage.createSparse(at: url, size: createDiskSize)
                report(
                    "created sparse disk image \(url.path(percentEncoded: false)) (\(createDiskSize))"
                )
            }
            prepared.append(VMConfiguration.Disk(url: url))
        }
        return prepared
    }

    // MARK: Reporting

    private func reportLimits(of configuration: VMConfiguration) {
        let limits = VMConfiguration.Limits.host
        let clamped = configuration.clamped(to: limits)
        if clamped.cpuCount != configuration.cpuCount {
            report(
                "using \(clamped.cpuCount) CPUs; this Mac allows \(limits.cpuCount.lowerBound) "
                    + "to \(limits.cpuCount.upperBound)")
        }
        if clamped.memorySize != configuration.memorySize {
            report(
                "using \(clamped.memorySize) of memory; this Mac allows "
                    + "\(limits.memorySize.lowerBound) to \(limits.memorySize.upperBound)")
        }
    }

    static func describe(_ outcome: VirtualMachine.StopOutcome) -> String {
        switch outcome {
        case .alreadyStopped:
            "shutdown: the virtual machine had already stopped"
        case .clean(let elapsed):
            "shutdown: clean after \(elapsed.milliseconds) ms"
        case .forced(let elapsed):
            "shutdown: forced after \(elapsed.milliseconds) ms (the guest did not power off when asked)"
        }
    }

    /// Writes a status line to standard error. In an interactive session the terminal is in
    /// raw mode, which does not translate "\n", so status lines are written before and after it.
    private func report(_ message: String) {
        Self.writeToStandardError("debug-boot: \(message)\n")
    }

    static func writeToStandardError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

/// The kernel, initramfs, and manifest in a kernel directory.
struct GuestFiles {
    struct Manifest: Decodable {
        struct Kernel: Decodable {
            var release: String
        }
        var guestVersion: String
        var gitCommit: String
        var kernel: Kernel
    }

    let kernelURL: URL
    let initramfsURL: URL
    let manifest: Manifest?

    init(directory: URL) throws(MacWSLError) {
        for file in ["Image", "initramfs.cpio.gz", "manifest.json"] {
            let path = directory.appending(path: file).path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: path) else {
                throw .kernelNotFound(path: path)
            }
        }
        kernelURL = directory.appending(path: "Image")
        initramfsURL = directory.appending(path: "initramfs.cpio.gz")
        manifest = try? JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
    }

    var summary: String {
        guard let manifest else {
            return "kernel: manifest.json could not be read"
        }
        return "kernel \(manifest.kernel.release), guest \(manifest.guestVersion), "
            + "commit \(manifest.gitCommit.prefix(12))"
    }
}
