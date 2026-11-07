import Darwin
import Foundation
import MawProtocol

/// Writes text to standard output and standard error, in the order it was queued, on a thread
/// of its own.
///
/// A terminal that stops reading, after Ctrl-S or behind a stalled pipe, then blocks only that
/// thread. Callers queue text without waiting, so that nothing that holds a lock, and nothing
/// on the way from Ctrl-C to the exit, waits for the terminal.
final class OutputQueue: @unchecked Sendable {
    private let standardOutput: Int32
    private let standardError: Int32
    private let lock = NSLock()
    private var pending: [(descriptor: Int32, bytes: [UInt8])] = []
    /// Whether a thread is writing; it ends once nothing is pending.
    private var isWriting = false

    init(standardOutput: Int32 = STDOUT_FILENO, standardError: Int32 = STDERR_FILENO) {
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    /// Queues `text` for standard output.
    func write(_ text: String) {
        enqueue(text, to: standardOutput)
    }

    /// Queues `text` for standard error.
    func writeError(_ text: String) {
        enqueue(text, to: standardError)
    }

    /// Waits until everything queued has been written, or until `timeout` has passed. Returns
    /// whether everything was written.
    @discardableResult
    func waitUntilWritten(timeout: Duration? = nil) async -> Bool {
        let deadline = timeout.map { ContinuousClock.now + $0 }
        while lock.withLock({ isWriting }) {
            if let deadline, ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func enqueue(_ text: String, to descriptor: Int32) {
        guard !text.isEmpty else { return }
        let start = lock.withLock {
            pending.append((descriptor, Array(text.utf8)))
            defer { isWriting = true }
            return !isWriting
        }
        if start {
            Thread { [self] in drain() }.start()
        }
    }

    private func drain() {
        while let next = lock.withLock({ () -> (descriptor: Int32, bytes: [UInt8])? in
            guard !pending.isEmpty else {
                isWriting = false
                return nil
            }
            return pending.removeFirst()
        }) {
            // A write error, such as EPIPE, discards the text, as `print` does.
            try? writeAll(next.bytes, to: next.descriptor)
        }
    }
}
