import Darwin
import Foundation

/// Whether a session's last write to a terminal left its line open, so that an error printed
/// after the session starts on a line of its own instead of after the command's last,
/// unfinished line.
///
/// Only writes to a standard stream that is a terminal count, and only the most recent of
/// them: standard output and standard error are often the same terminal. A line is open after
/// a write that ends with anything but a line feed, a carriage return included.
final class TerminalLine: @unchecked Sendable {
    /// The session's state, which `SessionRunner.writeOutput` updates.
    static let session = TerminalLine { isatty($0) == 1 }

    private let lock = NSLock()
    private let isTerminal: @Sendable (Int32) -> Bool
    private var terminals: [Int32: Bool] = [:]
    private var lineIsOpen = false

    init(isTerminal: @escaping @Sendable (Int32) -> Bool) {
        self.isTerminal = isTerminal
    }

    /// Records a write of `bytes` to `descriptor`.
    func wrote(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) {
        guard let last = bytes.last else { return }
        lock.withLock {
            guard isTerminalLocked(descriptor) else { return }
            lineIsOpen = last != UInt8(ascii: "\n")
        }
    }

    /// What to write to standard error before an error message: a line feed if standard error
    /// is a terminal and the last write to a terminal left its line open, and otherwise
    /// nothing.
    func separatorBeforeMessage() -> String {
        lock.withLock {
            isTerminalLocked(STDERR_FILENO) && lineIsOpen ? "\n" : ""
        }
    }

    private func isTerminalLocked(_ descriptor: Int32) -> Bool {
        if let known = terminals[descriptor] {
            return known
        }
        let answer = isTerminal(descriptor)
        terminals[descriptor] = answer
        return answer
    }
}
