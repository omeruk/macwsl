import Foundation

/// The size of a terminal grid.
public struct TerminalSize: Hashable, Sendable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    public static let `default` = TerminalSize(columns: 80, rows: 24)

    /// `cols×rows`, as the status shows it.
    public var description: String { "\(columns)×\(rows)" }
}

/// How a session's process ended.
public enum TerminationStatus: Hashable, Sendable {
    case exited(Int32)
    case signaled(Int32)
    /// The status could not be read, for example because the process was reaped elsewhere.
    case unknown

    /// Decodes a status from `waitpid`.
    public init(waitStatus status: Int32) {
        let low = status & 0x7F
        if low == 0 {
            self = .exited((status >> 8) & 0xFF)
        } else if low != 0x7F {
            self = .signaled(low)
        } else {
            self = .unknown
        }
    }

    /// A short description for the pane, such as `exited with status 1`.
    public var description: String {
        switch self {
        case .exited(0): "exited"
        case .exited(let code): "exited with status \(code)"
        case .signaled(let signal):
            if let name = strsignal(signal) {
                "ended by signal \(signal) (\(String(cString: name).lowercased()))"
            } else {
                "ended by signal \(signal)"
            }
        case .unknown: "ended"
        }
    }
}

/// Errors starting or running a session.
public enum TerminalSessionError: Error, Hashable, Sendable {
    /// The shell or program does not exist or is not executable.
    case programNotFound(path: String)
    case startFailed(reason: String)
    /// Any other error, kept as its message and suggested fix, so that the window does not
    /// depend on the kind of session that failed.
    case failed(message: String, suggestion: String?)

    /// The error's message and suggested fix, as `LocalizedError` gives them.
    public init(_ error: some LocalizedError) {
        self = .failed(
            message: error.errorDescription ?? String(describing: error),
            suggestion: error.recoverySuggestion)
    }
}

/// What runs in the foreground of a session's terminal, for close and quit confirmations.
public enum ForegroundReport: Hashable, Sendable {
    /// The shell itself, waiting at its prompt, or nothing because the session has ended.
    case none
    /// A program other than the shell. `name` is `nil` if it is not known, for example because
    /// the leader of the foreground process group has exited.
    case program(name: String?)
    /// The session did not answer in time, so a program may be running.
    case noAnswer
}

extension TerminalSessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .programNotFound(let path): "\(path) does not exist or is not executable"
        case .startFailed(let reason): "The session could not start: \(reason)"
        case .failed(let message, _): message
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .programNotFound:
            "Choose another shell for the local profile in settings, under general."
        case .startFailed:
            "Open a new tab to try again."
        case .failed(_, let suggestion): suggestion
        }
    }
}

/// Receives a session's output and state changes. All calls arrive on the main actor, in
/// order. A session delivers output only as fast as the delegate consumes it, so a flood of
/// output slows the producing process down instead of growing a buffer.
@MainActor
public protocol TerminalSessionDelegate: AnyObject {
    func session(_ session: any TerminalSession, didReceive bytes: ArraySlice<UInt8>)
    func session(_ session: any TerminalSession, didChangeTitle title: String)
    func session(_ session: any TerminalSession, didChangeWorkingDirectory directory: String)
    func session(_ session: any TerminalSession, didTerminateWith status: TerminationStatus)
    /// The session could not open, or something other than its program ended it, such as the
    /// machine of a Linux session stopping. No `didTerminateWith` follows.
    func session(_ session: any TerminalSession, didFailWith error: TerminalSessionError)
}

/// A program running behind a terminal pane: the local shell (`LocalShellSession`) or a Linux
/// distribution's login shell (`LinuxSession`).
///
/// Nothing outside the session layer depends on which kind of session it is. The terminal view
/// decodes escape sequences, so title (OSC 0 and 2) and working-directory (OSC 7) reports reach
/// the session through `terminalReportedTitle(_:)` and `terminalReportedWorkingDirectory(_:)`,
/// and the session decides what they mean for it and tells its delegate.
@MainActor
public protocol TerminalSession: AnyObject {
    /// Stable for the session's lifetime.
    var id: UUID { get }
    /// The name in tab and pane titles, such as `zsh`.
    var displayName: String { get }
    var delegate: (any TerminalSessionDelegate)? { get set }
    /// The current working directory, if known.
    var workingDirectory: String? { get }
    var isRunning: Bool { get }
    /// Whether a program other than the shell itself is in the foreground, such as `vim` or a
    /// build. Closing the pane or quitting asks first when this is true.
    var hasForegroundProcess: Bool { get }
    /// The name of the foreground program, for confirmation messages.
    var foregroundProcessName: String? { get }
    /// What runs in the foreground now, answered within `timeout`. Never cached, so that a
    /// program that has just ended does not count. The main actor only awaits it.
    func foregroundProgram(within timeout: Duration) async -> ForegroundReport

    /// Starts the program with the terminal at `size`.
    func start(size: TerminalSize) throws(TerminalSessionError)
    /// Sends input, such as typed keys or pasted text, to the program.
    func send(_ bytes: ArraySlice<UInt8>)
    /// Tells the program the terminal's new size.
    func resize(to size: TerminalSize)
    /// Ends the program, as closing a terminal window does: SIGHUP to the session.
    func terminate()

    /// OSC 0 or 2 from the program.
    func terminalReportedTitle(_ title: String)
    /// OSC 7 from the program: the raw URL.
    func terminalReportedWorkingDirectory(_ url: String)
    /// Called about twice a second while the session is visible, so that a session can refresh
    /// state that it has to poll for.
    func refresh(isVisible: Bool)
}
