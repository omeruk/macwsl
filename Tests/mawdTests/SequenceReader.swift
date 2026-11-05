import Darwin
import Foundation
import os

/// Reads the output of `seq 1 inf` from a descriptor on a thread of its own, and checks as it
/// reads that each line is the next number, so that a line lost, repeated, or corrupted on the
/// way is found. It keeps no output, so memory stays bounded however much arrives. A terminal's
/// carriage returns are ignored.
///
/// Once the output stops being the sequence, it keeps the bytes from the first one that does
/// not match, up to `capturedLimit`, so that a failure shows what arrived instead: for a
/// terminal session, an error message from `maw` or from the guest.
///
/// It starts paused, as a reader that does not read; `resume()` starts reading. The caller
/// keeps the descriptor open until `stop()` has returned.
final class SequenceReader: @unchecked Sendable {
    /// Bytes kept after the output stops being the sequence.
    static let capturedLimit = 4096

    struct Progress: Equatable, CustomStringConvertible {
        /// Complete lines that matched.
        var lines = 0
        var bytes = 0
        /// The first line that did not match, or a read error.
        var error: String?
        /// After a mismatch: the digits read of the line that did not match, then the bytes from
        /// the first one that did not match, at most `capturedLimit` in all.
        var captured: [UInt8] = []
        /// The descriptor reached end-of-file.
        var atEnd = false

        var description: String {
            var text = "lines: \(lines), bytes: \(bytes), at end: \(atEnd)"
            if let error {
                text += ", error: \(error)"
                text += ", then \(captured.count) bytes: \"\(Self.escaped(captured))\""
            }
            return text
        }

        /// Printable ASCII as it is, and every other byte escaped.
        static func escaped(_ bytes: [UInt8]) -> String {
            var text = ""
            for byte in bytes {
                switch byte {
                case UInt8(ascii: "\n"): text += "\\n"
                case UInt8(ascii: "\r"): text += "\\r"
                case UInt8(ascii: "\t"): text += "\\t"
                case UInt8(ascii: "\\"): text += "\\\\"
                case UInt8(ascii: "\""): text += "\\\""
                case 0x20..<0x7F: text.unicodeScalars.append(Unicode.Scalar(byte))
                default: text += "\\x" + (byte < 0x10 ? "0" : "") + String(byte, radix: 16)
                }
            }
            return text
        }
    }

    private struct State {
        var progress = Progress()
        var reading = false
        var stopping = false
        // The line being read.
        var value = 0
        var digits = 0
    }

    private let descriptor: Int32
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let finished = DispatchSemaphore(value: 0)

    init(descriptor: Int32, reading: Bool = false) {
        self.descriptor = descriptor
        state.withLock { $0.reading = reading }
        Thread { [self] in run() }.start()
    }

    var progress: Progress { state.withLock { $0.progress } }

    func resume() {
        state.withLock { $0.reading = true }
    }

    /// Stops reading and waits for the thread to end.
    func stop() {
        state.withLock { $0.stopping = true }
        finished.wait()
    }

    /// Waits until at least `count` lines have matched, at most `timeout`.
    func waitForLines(_ count: Int, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let progress = self.progress
            if progress.lines >= count { return true }
            if progress.error != nil || progress.atEnd { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return progress.lines >= count
    }

    /// Waits until the bytes after a mismatch have been captured: the descriptor reached its
    /// end, or `capturedLimit` bytes arrived, or no byte arrived for `quiet`; at most `timeout`.
    func waitForCapture(
        quiet: Duration = .milliseconds(500), timeout: Duration = .seconds(5)
    ) async {
        let deadline = ContinuousClock.now + timeout
        var last = progress.bytes
        var since = ContinuousClock.now
        while ContinuousClock.now < deadline {
            let progress = self.progress
            if progress.atEnd || progress.captured.count >= Self.capturedLimit { return }
            if progress.bytes != last {
                last = progress.bytes
                since = .now
            } else if ContinuousClock.now - since >= quiet {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Waits until no byte has arrived for `quiet`, at most `timeout`: the writer is blocked.
    /// Returns whether the output stopped.
    func waitUntilStalled(quiet: Duration = .milliseconds(500), timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        var last = progress.bytes
        var since = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            let bytes = progress.bytes
            if bytes != last {
                last = bytes
                since = .now
            } else if ContinuousClock.now - since >= quiet {
                return true
            }
        }
        return false
    }

    private func run() {
        defer { finished.signal() }
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let (reading, stopping) = state.withLock { ($0.reading, $0.stopping) }
            if stopping { return }
            if !reading {
                usleep(10_000)
                continue
            }
            var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&entry, 1, 100)
            if ready < 0 && errno != EINTR {
                state.withLock { $0.progress.error = "poll: errno \(errno)" }
                return
            }
            guard ready > 0 else { continue }
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                // A terminal's primary side reports EIO once the program has closed it.
                let code = errno
                state.withLock {
                    if code == EIO {
                        $0.progress.atEnd = true
                    } else {
                        $0.progress.error = "read: errno \(code)"
                    }
                }
                return
            }
            if count == 0 {
                state.withLock { $0.progress.atEnd = true }
                return
            }
            let chunk = buffer[..<count]
            state.withLock { Self.check(chunk, in: &$0) }
        }
    }

    private static func check(_ bytes: ArraySlice<UInt8>, in state: inout State) {
        state.progress.bytes += bytes.count
        guard state.progress.error == nil else {
            capture(bytes, in: &state)
            return
        }
        for (index, byte) in zip(bytes.indices, bytes) {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                state.value = state.value * 10 + Int(byte - UInt8(ascii: "0"))
                state.digits += 1
                if state.digits > 18 {
                    state.progress.error = "a line longer than 18 digits"
                    mismatch(at: bytes.index(after: index), of: bytes, in: &state)
                    return
                }
            case UInt8(ascii: "\r"):
                continue
            case UInt8(ascii: "\n"):
                let expected = state.progress.lines + 1
                guard state.digits > 0, state.value == expected else {
                    state.progress.error =
                        "line \(expected) was \(state.digits == 0 ? "empty" : "\(state.value)")"
                    mismatch(at: index, of: bytes, in: &state)
                    return
                }
                state.progress.lines = expected
                state.value = 0
                state.digits = 0
            default:
                state.progress.error =
                    "byte \(byte) after line \(state.progress.lines), which is not a digit"
                mismatch(at: index, of: bytes, in: &state)
                return
            }
        }
    }

    /// Starts the capture with the line read so far and the rest of the chunk.
    private static func mismatch(
        at index: Int, of bytes: ArraySlice<UInt8>, in state: inout State
    ) {
        if state.digits > 0 {
            state.progress.captured = Array(String(state.value).utf8)
        }
        capture(bytes[index...], in: &state)
    }

    private static func capture(_ bytes: ArraySlice<UInt8>, in state: inout State) {
        let room = capturedLimit - state.progress.captured.count
        state.progress.captured += bytes.prefix(max(room, 0))
    }
}
