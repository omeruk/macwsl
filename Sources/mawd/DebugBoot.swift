import ArgumentParser
import Darwin
import Foundation
import MawCommandLine
import MawCore
import MawProtocol
import MawTerminalIO
import MawVirtualization

/// `mawd debug-boot`: boots the guest kernel and initramfs for development.
struct DebugBoot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug-boot",
        abstract: "Boot the guest kernel and initramfs in a virtual machine (development tool).",
        discussion: """
            Boots Image and initramfs.cpio.gz from the kernel directory with \
            Virtualization.framework, copies the guest console to standard output, and waits \
            until the guest powers off. The console is also written to \
            ~/Library/Logs/maw/debug-boot-console.log. SIGINT and SIGTERM stop the virtual \
            machine first.

            With --exec -- <command> [<argument>...], runs one command in the guest through the \
            guest agent instead of showing the console. Standard input, output, and error are \
            connected to the command, SIGINT, SIGTERM, and SIGHUP are passed to it, and \
            debug-boot exits with its exit status after the virtual machine has shut down.

            With --shell, runs /bin/sh -l in the guest on a pseudo-terminal, through the guest \
            agent. With --interactive, the terminal is connected to the guest console (hvc0) \
            instead, where the kernel command line gets maw.debug=shell. In both, Ctrl-C is \
            passed to the guest. To stop the virtual machine and detach, type ~. at the start of \
            a line (after Enter), or press the detach key, Ctrl-] by default. ~? lists the \
            escape sequences, and ~~ sends a single ~. The ~ sequences work on every keyboard \
            layout; Ctrl-] needs the Option key on many non-US layouts.

            The executable must be signed with the virtualization entitlement. Build it with \
            scripts/sign-dev.sh, which builds and signs; a plain swift build removes the \
            signature. scripts/fetch-guest.sh installs the kernel files.
            """
    )

    /// The virtual machine's name, which also names its console log.
    static let name = "debug-boot"
    /// How long `stop(timeout:)` waits for the guest after each request to power off.
    static let stopTimeout = Duration.seconds(5)
    /// How long --exec and --shell wait for the guest agent after the virtual machine starts.
    static let agentReadyTimeout = Duration.seconds(30)

    @Option(
        name: .customLong("kernel-dir"),
        help: ArgumentHelp(
            "Directory with Image, initramfs.cpio.gz, and manifest.json "
                + "(default: ~/Library/Application Support/maw/kernel).",
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

    @Flag(
        help: ArgumentHelp(
            "Run the command after -- in the guest through the guest agent, and exit with its "
                + "status."))
    var exec = false

    @Flag(
        help: ArgumentHelp(
            "Run /bin/sh -l in the guest on a pseudo-terminal through the guest agent. ~. at "
                + "the start of a line detaches."))
    var shell = false

    @Option(
        name: .customLong("detach-key"),
        help: ArgumentHelp(
            "The control key that detaches an --interactive or --shell session, such as ^Q, or "
                + "none (default: ^]). ~. always works as well.",
            valueName: "key"),
        transform: { try DetachKey(parsing: $0) })
    var detachKey: DetachKey?

    @Option(
        help: ArgumentHelp(
            "Fail if the guest has not stopped within this many seconds. Only without "
                + "--interactive, --exec, and --shell.",
            valueName: "seconds"))
    var timeout: Int?

    /// For measurements: runs the --exec command this many times in the same virtual machine
    /// and reports the median and 95th-percentile round-trip time.
    @Option(name: .customLong("repeat"), help: .hidden)
    var repeatCount: Int?

    @Argument(
        parsing: .postTerminator,
        help: ArgumentHelp(
            "With --exec, the command to run and its arguments.", valueName: "command"))
    var command: [String] = []

    /// The session the options select.
    enum Mode: Equatable {
        /// The console on standard output until the guest powers off.
        case attached
        case interactive
        case exec
        case shell
    }

    var mode: Mode {
        if interactive { return .interactive }
        if exec { return .exec }
        if shell { return .shell }
        return .attached
    }

    func validate() throws {
        let modes = [("--interactive", interactive), ("--exec", exec), ("--shell", shell)]
            .filter(\.1).map(\.0)
        if modes.count > 1 {
            throw ValidationError("\(modes.joined(separator: " and ")) cannot be combined.")
        }
        if timeout != nil, let selected = modes.first {
            throw ValidationError("--timeout cannot be combined with \(selected).")
        }
        if detachKey != nil && !interactive && !shell {
            throw ValidationError("--detach-key needs --interactive or --shell.")
        }
        if exec && command.isEmpty {
            throw ValidationError(
                "--exec needs a command after --, for example --exec -- uname -a.")
        }
        if !exec && !command.isEmpty {
            throw ValidationError("A command after -- needs --exec.")
        }
        if let repeatCount {
            if !exec {
                throw ValidationError("--repeat needs --exec.")
            }
            if repeatCount < 1 {
                throw ValidationError("--repeat must be at least 1.")
            }
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
        switch mode {
        case .interactive:
            try Terminal.requireTerminals(for: "--interactive")
        case .shell:
            try Terminal.requireTerminals(for: "--shell")
        case .attached, .exec:
            break
        }

        let guest = try GuestFiles(directory: kernelDirectoryURL)
        report(guest.summary)

        let configuration = VMConfiguration(
            kernelURL: guest.kernelURL,
            initramfsURL: guest.initramfsURL,
            consoleLogURL: MawPaths().logsDirectory.appending(path: "\(Self.name)-console.log"),
            cpuCount: cpus ?? VMConfiguration.defaultCPUCount(),
            memorySize: memory ?? VMConfiguration.defaultMemorySize,
            commandLine: VMConfiguration.commandLine(appending: kernelArguments),
            disks: try prepareDisks())
        reportLimits(of: configuration)
        report("console log: \(configuration.consoleLogURL.path(percentEncoded: false))")

        switch mode {
        case .attached:
            try await runAttached(configuration)
        case .interactive:
            try await runInteractive(configuration)
        case .exec:
            try await runExec(configuration)
        case .shell:
            try await runShell(configuration)
        }
    }

    /// --cmdline, plus maw.debug=shell for --interactive, which makes the guest's init run
    /// a shell on the console.
    var kernelArguments: String? {
        let arguments = [cmdline, interactive ? "maw.debug=shell" : nil].compactMap { $0 }
        return arguments.isEmpty ? nil : arguments.joined(separator: " ")
    }

    var kernelDirectoryURL: URL {
        kernelDirectory.map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? MawPaths().kernelDirectory
    }

    // MARK: Sessions

    /// What ended a session.
    enum Ending: Sendable {
        case guestStopped(VirtualMachine.State)
        case signal(Int32)
        case detached
        case timedOut
        /// The command run through the agent ended, or its connection failed.
        case processExited(Result<ExitStatus, MawError>)
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

        let rawMode = try RawMode(for: "--interactive")
        defer { rawMode.restore() }
        let console = toGuest.fileHandleForWriting
        let detach = Self.forwardStandardInput(escapes: escapes) { bytes in
            try? console.write(contentsOf: Data(bytes))
            return true
        }
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
    func finish(
        _ machine: VirtualMachine, after ending: Ending, started: ContinuousClock.Instant,
        beforeReport: () -> Void = {}
    ) async throws {
        var outcome: VirtualMachine.StopOutcome?
        switch ending {
        case .guestStopped:
            break
        case .signal, .detached, .timedOut, .processExited:
            outcome = try await machine.stop(timeout: Self.stopTimeout)
        }
        await machine.waitUntilStopped()
        beforeReport()

        if let outcome {
            if mode != .exec {
                // The guest was stopped while running, usually at its shell prompt, whose
                // line has no newline yet. Start the report on a line of its own.
                Self.writeToStandardError("\n")
            }
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
            throw MawError.guestStopTimedOut(seconds: timeout ?? 0)
        case .processExited(.success(let status)):
            if status.shellStatus != 0 {
                throw ExitCode(status.shellStatus)
            }
        case .processExited(.failure(let error)):
            // A command that cannot be started ends as it would in a shell: 127 if it does not
            // exist, 126 otherwise.
            let status: Int32
            switch error {
            case .guestCommandNotFound: status = 127
            case .guestCommandNotStarted: status = 126
            default: throw error
            }
            Self.writeToStandardError(Self.failure(for: error)?.output ?? "")
            throw ExitCode(status)
        }
    }

    /// Waits for whichever happens first: the guest stops, a signal, a detach, the timeout, or
    /// the guest process ends.
    static func firstEnding(
        of machine: VirtualMachine,
        signals: AsyncStream<Int32>?,
        detach: AsyncStream<Void>?,
        timeout: Duration?,
        process: GuestProcess? = nil
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
            if let signals {
                group.addTask {
                    for await number in signals {
                        return .signal(number)
                    }
                    return nil
                }
            }
            if let process {
                // The group waits for every task after cancelling them, and waitForExit() does
                // not end on cancellation. A stream does, so the exit is observed through one.
                let (exits, continuation) = AsyncStream.makeStream(
                    of: Result<ExitStatus, MawError>.self)
                Task {
                    do throws(MawError) {
                        continuation.yield(.success(try await process.waitForExit()))
                    } catch {
                        continuation.yield(.failure(error))
                    }
                    continuation.finish()
                }
                group.addTask {
                    for await result in exits {
                        return .processExited(result)
                    }
                    return nil
                }
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

    /// Copies standard input to `send`, interpreting the escape sequences, until the user
    /// detaches or `send` returns false. Returns a stream that yields once when the user
    /// detaches, or when standard input ends.
    static func forwardStandardInput(
        escapes: ConsoleEscapes, send: @escaping @Sendable ([UInt8]) -> Bool
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
                        if !send(bytes) {
                            break reading
                        }
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

    /// Whether `line` is the initramfs banner: `maw-initramfs <version> kernel=<release>`.
    static func isBanner(_ line: String) -> Bool {
        let fields = line.split(separator: " ")
        return fields.count == 3 && fields[0] == "maw-initramfs"
            && fields[2].hasPrefix("kernel=")
    }

    // MARK: Disks

    private func prepareDisks() throws(MawError) -> [VMConfiguration.Disk] {
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
        case .clean(let elapsed, let request):
            "shutdown: clean after \(elapsed.milliseconds) ms via \(request)"
        case .forced(let elapsed):
            "shutdown: forced after \(elapsed.milliseconds) ms (the guest did not power off when asked)"
        }
    }

    /// Writes a status line to standard error. In an interactive session the terminal is in
    /// raw mode, which does not translate "\n", so status lines are written before and after it.
    func report(_ message: String) {
        Self.writeToStandardError("debug-boot: \(message)\n")
    }

    static func writeToStandardError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
