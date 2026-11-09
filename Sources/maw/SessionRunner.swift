import Darwin
import Foundation
import MawClient
import MawCore
import MawProtocol
import MawTerminalIO
import MawXPC

/// Runs a session through the daemon: opens it, runs the plan's command with the guest agent
/// over the connection the daemon hands over, and returns the command's exit status.
///
/// Terminal bytes travel between this process and the guest directly; the daemon only holds
/// the session's lease, through the XPC connection, until this process exits.
///
/// How the session ends, and the error that explains it, is `SessionEnding` in `MawClient`,
/// which the terminal app shares.
struct SessionRunner {
    let plan: SessionPlan
    let mode: SessionMode

    /// Runs the session and returns the command's exit status.
    func run() async throws -> Int32 {
        try await Self.endingOpenLines { try await runSession() }
    }

    /// Runs `body`. An error that it throws is printed after the session's output, so when
    /// that output left a terminal's line open, a line feed goes to standard error first
    /// (`TerminalLine`), and the message starts on a line of its own.
    static func endingOpenLines<T>(
        on line: TerminalLine = .session, _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch {
            if Maw.failure(for: error)?.output.isEmpty == false {
                FileHandle.standardError.write(Data(line.separatorBeforeMessage().utf8))
            }
            throw error
        }
    }

    private func runSession() async throws -> Int32 {
        // Before anything else, so that output to a closed pipe (`| head`) cannot kill maw.
        signal(SIGPIPE, SIG_IGN)
        let client = try await DaemonClient.connect()
        defer { client.close() }
        let events = EventRelay(client.events)
        let session = try await client.openSession(on: plan.machine)
        let request = ExecRequest(
            program: plan.program, user: plan.user,
            locale: GuestLocale.preferred(
                languageCode: Locale.current.language.languageCode?.identifier,
                regionCode: Locale.current.region?.identifier),
            environment: mode.environment(host: ProcessInfo.processInfo.environment),
            workingDirectory: plan.workingDirectory,
            terminal: mode == .terminal
                ? (Terminal.windowSize() ?? TerminalSize(rows: 24, columns: 80)) : nil)

        let ending: SessionEnding
        switch mode {
        case .pipes:
            ending = try await runWithPipes(request, session: session, events: events)
        case .terminal:
            ending = try await runOnTerminal(request, session: session, events: events)
        }
        return try await ending.outcome(events: events, machine: session.info.machine).shellStatus
    }

    // MARK: Modes

    /// Pipes: standard output and error stay separate, and SIGINT, SIGTERM, and SIGHUP go to
    /// the command.
    private func runWithPipes(
        _ request: ExecRequest, session: DaemonSession, events: EventRelay
    ) async throws -> SessionEnding {
        let router = SignalRouter(SignalMonitor([SIGINT, SIGTERM, SIGHUP]))
        let process = try await start(request, session: session)
        router.attach(process)
        Self.forwardStandardInput(to: process)
        return await SessionEnding.first(process: process, events: events, signals: nil)
    }

    /// A terminal: raw mode, window size changes, and the terminal restored on every path.
    /// Ctrl-C is a byte for the guest. SIGINT, SIGTERM, SIGHUP, and SIGQUIT sent to maw from
    /// elsewhere end the session, after which the terminal is restored; the guest agent then
    /// hangs up the guest's terminal, as sshd does.
    private func runOnTerminal(
        _ request: ExecRequest, session: DaemonSession, events: EventRelay
    ) async throws -> SessionEnding {
        let signals = SignalMonitor(SignalMonitor.orderlySignals)
        let resizes = SignalMonitor([SIGWINCH])
        let rawMode = try RawMode(for: "a shell")
        defer { rawMode.restore() }
        let process = try await start(request, session: session)
        Self.forwardStandardInput(to: process)
        let resizing = Task {
            for await _ in resizes.signals {
                if let size = Terminal.windowSize() {
                    process.resize(size)
                }
            }
        }
        defer { resizing.cancel() }
        return await SessionEnding.first(
            process: process, events: events, signals: signals.signals)
    }

    private func start(_ request: ExecRequest, session: DaemonSession) async throws(MawError)
        -> GuestProcess
    {
        try await session.agentClient().exec(request, output: Self.writeOutput)
    }

    // MARK: Standard streams

    /// Writes the command's output to this process's standard output or error. A write error
    /// such as EPIPE discards the output; the command keeps running.
    @Sendable
    static func writeOutput(
        _ stream: GuestAgentClient.OutputStream, _ bytes: UnsafeRawBufferPointer
    ) {
        let descriptor = stream == .stdout ? STDOUT_FILENO : STDERR_FILENO
        try? writeAll(bytes, to: descriptor)
        TerminalLine.session.wrote(bytes, to: descriptor)
    }

    /// Copies standard input to the command on a thread of its own, then ends its input.
    static func forwardStandardInput(to process: GuestProcess) {
        Thread {
            var buffer = [UInt8](repeating: 0, count: 32 << 10)
            while true {
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0, process.write(buffer[..<count]) else { break }
            }
            process.closeInput()
        }.start()
    }
}
