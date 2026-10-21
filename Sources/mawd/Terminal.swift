import Darwin
import Dispatch
import MawCore
import MawProtocol

/// Terminal handling for `debug-boot --interactive`.
enum Terminal {
    /// Throws unless both descriptors refer to terminals. Called before anything else in an
    /// interactive session, so that nothing touches termios or starts a VM without a terminal.
    /// `option` names the option that needs the terminal.
    static func requireTerminals(
        for option: String, input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO
    ) throws(MawError) {
        guard isatty(input) == 1 else {
            throw .notATerminal(option: option, stream: "standard input")
        }
        guard isatty(output) == 1 else {
            throw .notATerminal(option: option, stream: "standard output")
        }
    }

    /// The terminal's window size, or `nil` if `descriptor` is not a terminal or reports none.
    static func windowSize(of descriptor: Int32 = STDOUT_FILENO) -> TerminalSize? {
        var size = winsize()
        guard ioctl(descriptor, TIOCGWINSZ, &size) == 0, size.ws_row > 0, size.ws_col > 0 else {
            return nil
        }
        return TerminalSize(rows: size.ws_row, columns: size.ws_col)
    }
}

// The terminal state that `RawMode` must restore, in plain globals, so that the crash-signal
// handler and the atexit hook can reach it with nothing but async-signal-safe calls.
nonisolated(unsafe) private var rawModeDescriptor: Int32 = -1
nonisolated(unsafe) private var rawModeOriginal = termios()

/// Restores the saved terminal state, if raw mode is active. Async-signal-safe.
private func restoreSavedTerminal() {
    if rawModeDescriptor >= 0 {
        tcsetattr(rawModeDescriptor, TCSANOW, &rawModeOriginal)
    }
}

/// Puts a terminal into raw mode, and restores its original state on every exit path:
///
/// - `restore()`, which callers run in a `defer`, covers returns and thrown errors;
/// - an `atexit` hook covers `exit()` from anywhere;
/// - a handler for SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, and SIGTRAP (which a Swift
///   runtime trap raises) restores the terminal, then re-raises the signal with its default
///   action, so that crashes are still reported normally.
///
/// SIGINT, SIGTERM, SIGHUP, and SIGQUIT are handled by the caller as orderly shutdowns (see
/// `SignalMonitor`). In raw mode, Ctrl-C and Ctrl-Z generate no signals; they are bytes for the
/// guest. SIGKILL cannot be handled; after it, `stty sane` restores the terminal.
final class RawMode {
    private static let crashSignals = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP]
    nonisolated(unsafe) private static var installedHandlers = false

    private let descriptor: Int32

    init(for option: String, descriptor: Int32 = STDIN_FILENO) throws(MawError) {
        var original = termios()
        guard tcgetattr(descriptor, &original) == 0 else {
            throw .notATerminal(option: option, stream: "standard input")
        }
        self.descriptor = descriptor
        rawModeOriginal = original
        rawModeDescriptor = descriptor
        Self.installHandlers()

        var raw = original
        cfmakeraw(&raw)
        tcsetattr(descriptor, TCSAFLUSH, &raw)
    }

    /// Restores the original state. Safe to call more than once.
    func restore() {
        guard rawModeDescriptor == descriptor else { return }
        tcsetattr(descriptor, TCSAFLUSH, &rawModeOriginal)
        rawModeDescriptor = -1
    }

    private static func installHandlers() {
        guard !installedHandlers else { return }
        installedHandlers = true
        atexit { restoreSavedTerminal() }
        for signal in crashSignals {
            Darwin.signal(signal) { received in
                restoreSavedTerminal()
                Darwin.signal(received, SIG_DFL)
                raise(received)
            }
        }
    }
}

/// Turns SIGINT, SIGTERM, SIGHUP, and SIGQUIT into an async stream, so that `debug-boot` can
/// stop the virtual machine in an orderly way instead of dying with it. Dispatch sources are
/// the system's way to observe signals outside a signal handler; their queue stays inside this
/// type.
final class SignalMonitor: Sendable {
    static let orderlySignals = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]

    let signals: AsyncStream<Int32>
    private let sources: [any DispatchSourceSignal]

    init(_ signals: [Int32] = SignalMonitor.orderlySignals) {
        let (stream, continuation) = AsyncStream.makeStream(of: Int32.self)
        self.signals = stream
        self.sources = signals.map { number in
            // Ignore the default action, which would terminate the process, and observe the
            // signal through the dispatch source instead.
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { continuation.yield(number) }
            source.resume()
            return source
        }
    }
}
