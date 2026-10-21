import ArgumentParser
import Darwin
import Foundation
import MacWSLCore
import MacWSLProtocol
import MacWSLVirtualization
import os

/// `debug-boot --exec` and `--shell`: sessions that run through the guest agent rather than the
/// console. The console still goes to the console log, but not to the terminal.
extension DebugBoot {
    // MARK: --exec

    /// Runs the command in pipe mode, forwarding standard input, output, and error, and
    /// SIGINT, SIGTERM, and SIGHUP. Exits with the command's status after the virtual machine
    /// has shut down.
    func runExec(_ configuration: VMConfiguration) async throws {
        // A closed standard output (`| head`) must not kill debug-boot with the VM running.
        signal(SIGPIPE, SIG_IGN)
        let machine = try VirtualMachine(name: Self.name, configuration: configuration)
        let router = SignalRouter(SignalMonitor([SIGINT, SIGTERM, SIGHUP]))
        let started = ContinuousClock.now
        let banner = Task { await Self.reportBanner(in: machine.consoleLines, since: started) }
        defer { banner.cancel() }

        try await machine.start()
        if let ending = await waitForAgent(on: machine, started: started, router: router) {
            try await finish(machine, after: ending, started: started)
            return
        }

        let client = machine.agentClient(connectTimeout: .seconds(5))
        let request = ExecRequest(argv: command, environment: Self.hostEnvironment(terminal: false))
        let ending: Ending
        do throws(MacWSLError) {
            if let repeatCount {
                ending = try await runRepeatedly(request, count: repeatCount, on: client)
            } else {
                let process = try await client.exec(request, output: Self.writeOutput)
                router.attach(process)
                Self.forwardStandardInput(to: process)
                ending = await Self.firstEnding(
                    of: machine, signals: nil, detach: nil, timeout: nil, process: process)
            }
        } catch {
            // The command did not start. Report it as a shell would, after the shutdown.
            try await finish(machine, after: .processExited(.failure(error)), started: started)
            return
        }
        try await finish(machine, after: ending, started: started)
    }

    /// Runs the request `count` times in a row and reports the round-trip times.
    private func runRepeatedly(
        _ request: ExecRequest, count: Int, on client: GuestAgentClient
    ) async throws(MacWSLError) -> Ending {
        var durations: [Duration] = []
        var status = ExitStatus.exited(code: 0)
        for _ in 0..<count {
            let start = ContinuousClock.now
            let process = try await client.exec(request, output: Self.writeOutput)
            process.closeInput()
            status = try await process.waitForExit()
            durations.append(ContinuousClock.now - start)
        }
        report(Self.describeLatency(durations, command: request.argv.joined(separator: " ")))
        return .processExited(.success(status))
    }

    /// `exec: <n> runs of <command>: median <m> ms, p95 <p> ms`.
    static func describeLatency(_ durations: [Duration], command: String) -> String {
        let milliseconds = durations.map {
            Double($0.components.attoseconds) / 1e15
                + Double($0.components.seconds) * 1e3
        }.sorted()
        let median =
            milliseconds.count % 2 == 1
            ? milliseconds[milliseconds.count / 2]
            : (milliseconds[milliseconds.count / 2 - 1] + milliseconds[milliseconds.count / 2]) / 2
        // The nearest-rank 95th percentile.
        let rank = Int((0.95 * Double(milliseconds.count)).rounded(.up))
        let p95 = milliseconds[max(0, rank - 1)]
        let runs = durations.count == 1 ? "1 run" : "\(durations.count) runs"
        return "exec: \(runs) of \(command): "
            + String(format: "median %.2f ms, p95 %.2f ms", median, p95)
    }

    /// Writes the guest process's output to this process's standard output or error. Errors
    /// such as EPIPE discard the output; the command keeps running.
    @Sendable
    static func writeOutput(
        _ stream: GuestAgentClient.OutputStream, _ bytes: UnsafeRawBufferPointer
    ) {
        try? writeAll(bytes, to: stream == .stdout ? STDOUT_FILENO : STDERR_FILENO)
    }

    /// Copies standard input to the process on a thread of its own, then ends its input.
    private static func forwardStandardInput(to process: GuestProcess) {
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

    // MARK: --shell

    /// Runs `/bin/sh -l` on a pseudo-terminal, with the terminal in raw mode and the escape
    /// sequences of `--interactive`. Window size changes are forwarded.
    func runShell(_ configuration: VMConfiguration) async throws {
        let machine = try VirtualMachine(name: Self.name, configuration: configuration)
        let router = SignalRouter(SignalMonitor())
        let resizes = SignalMonitor([SIGWINCH])
        let escapes = ConsoleEscapes(detachKey: detachKey ?? .default)
        let started = ContinuousClock.now
        let banner = Task { await Self.reportBanner(in: machine.consoleLines, since: started) }
        defer { banner.cancel() }

        try await machine.start()
        if let ending = await waitForAgent(on: machine, started: started, router: router) {
            try await finish(machine, after: ending, started: started)
            return
        }
        banner.cancel()
        report(escapes.instructions)

        let size = Terminal.windowSize() ?? TerminalSize(rows: 24, columns: 80)
        let request = ExecRequest(
            argv: ["/bin/sh", "-l"], environment: Self.hostEnvironment(terminal: true),
            terminal: size)
        let rawMode = try RawMode(for: "--shell")
        defer { rawMode.restore() }

        let process: GuestProcess
        do throws(MacWSLError) {
            process = try await machine.agentClient(connectTimeout: .seconds(5))
                .exec(request, output: Self.writeOutput)
        } catch {
            try await finish(machine, after: .processExited(.failure(error)), started: started) {
                rawMode.restore()
            }
            return
        }
        let detach = Self.forwardStandardInput(escapes: escapes) { bytes in
            process.write(bytes)
        }
        let resizing = Task {
            for await _ in resizes.signals {
                if let size = Terminal.windowSize() {
                    process.resize(size)
                }
            }
        }
        defer { resizing.cancel() }

        let ending = await Self.firstEnding(
            of: machine, signals: router.unrouted, detach: detach, timeout: nil, process: process)
        try await finish(machine, after: ending, started: started) {
            rawMode.restore()
        }
    }

    // MARK: Shared

    /// Waits until the guest agent answers `info` and prints `boot: agent ready after <n> ms`.
    /// Returns `nil` when it is ready, or how the session ended if a signal arrived, the
    /// virtual machine stopped, or the agent did not answer in time.
    func waitForAgent(
        on machine: VirtualMachine, started: ContinuousClock.Instant, router: SignalRouter
    ) async -> Ending? {
        let deadline = ContinuousClock.now + Self.agentReadyTimeout
        // Short attempts, so that a signal during boot ends the wait promptly.
        let client = machine.agentClient(connectTimeout: .milliseconds(250))
        while true {
            if let signal = router.pendingSignal {
                return .signal(signal)
            }
            do throws(MacWSLError) {
                _ = try await client.info()
                report("boot: agent ready after \((ContinuousClock.now - started).milliseconds) ms")
                return nil
            } catch {
                let state = await machine.state
                if state == .stopped || { if case .error = state { true } else { false } }() {
                    return .guestStopped(state)
                }
                guard case .guestAgentUnavailable = error, ContinuousClock.now < deadline else {
                    return .processExited(.failure(error))
                }
            }
        }
    }

    /// TERM (on a terminal) and LANG from this process's environment, for the guest process.
    static func hostEnvironment(terminal: Bool) -> [String: String] {
        let host = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        if terminal {
            environment["TERM"] = host["TERM"] ?? "xterm-256color"
        }
        if let language = host["LANG"] {
            environment["LANG"] = language
        }
        return environment
    }
}

/// Routes the signals that `SignalMonitor` observes. Once a guest process is attached, they
/// are forwarded to it. Until then, or if none is ever attached, they are recorded and yielded
/// on `unrouted`, where they end the session.
final class SignalRouter: Sendable {
    let unrouted: AsyncStream<Int32>
    private let state = OSAllocatedUnfairLock<(process: GuestProcess?, pending: Int32?)>(
        initialState: (nil, nil))
    private let monitor: SignalMonitor

    init(_ monitor: SignalMonitor) {
        self.monitor = monitor
        let (stream, continuation) = AsyncStream.makeStream(of: Int32.self)
        unrouted = stream
        Task { [state] in
            for await number in monitor.signals {
                let process = state.withLock { state -> GuestProcess? in
                    if state.process == nil {
                        state.pending = state.pending ?? number
                    }
                    return state.process
                }
                if let process {
                    process.send(Signal(localNumber: number) ?? .term)
                } else {
                    continuation.yield(number)
                }
            }
        }
    }

    /// The first signal received while no process was attached.
    var pendingSignal: Int32? {
        state.withLock { $0.pending }
    }

    /// Forwards later signals to `process`. A signal that arrived before is forwarded now.
    func attach(_ process: GuestProcess) {
        let pending = state.withLock { state -> Int32? in
            state.process = process
            defer { state.pending = nil }
            return state.pending
        }
        if let pending {
            process.send(Signal(localNumber: pending) ?? .term)
        }
    }
}
