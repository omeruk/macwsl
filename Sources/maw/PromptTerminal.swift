import Darwin
import MawCore
import MawXPC

/// The terminal that `maw --install` asks for the account on: the controlling terminal,
/// `/dev/tty`, as `sudo` and `ssh` use it.
///
/// The questions and the answers never pass through standard output or standard error, so they
/// stay visible when both are redirected, as in `maw --install 2>&1 | tee install.log`, and
/// never reach the redirected file. The password is read with `readpassphrase`, which opens the
/// same terminal, turns echo off while it reads, and restores the terminal afterwards.
final class PromptTerminal {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// The controlling terminal. Throws `installNeedsTerminal` if the process has none.
    static func open() throws(MawError) -> PromptTerminal {
        let descriptor = Darwin.open("/dev/tty", O_RDWR | O_CLOEXEC | O_NOCTTY)
        guard descriptor >= 0 else {
            throw .installNeedsTerminal
        }
        return PromptTerminal(descriptor: descriptor)
    }

    /// Writes `text` to the terminal.
    func write(_ text: String) {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress, $0.count)
            }
            if written < 0 {
                if errno == EINTR { continue }
                return
            }
            bytes = bytes.dropFirst(written)
        }
    }

    /// Writes `text` followed by a line break.
    func writeLine(_ text: String) {
        write(text + "\n")
    }

    /// Reads one line typed on the terminal, without its line break, or `nil` at the end of
    /// input (Ctrl-D at the start of a line).
    func readLine() -> String? {
        var line: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0, errno == EINTR {
                continue
            }
            guard count == 1 else {
                return line.isEmpty ? nil : String(decoding: line, as: UTF8.self)
            }
            if byte == UInt8(ascii: "\n") {
                return String(decoding: line, as: UTF8.self)
            }
            line.append(byte)
        }
    }

    /// Reads a password without echoing it. Ctrl-C ends maw, and `readpassphrase` restores the
    /// terminal first. Throws `InstallRequest.passwordTooLong` for a password longer than
    /// `InstallRequest.maximumPasswordBytes`.
    func readSecret(prompt: String) throws(MawError) -> Secret {
        // `readpassphrase` keeps at most one byte less than the buffer and discards the rest
        // of the line. One byte more than the limit, plus the terminating zero, tells a
        // password at the limit from a longer one.
        var buffer = [CChar](repeating: 0, count: InstallRequest.maximumPasswordBytes + 2)
        defer { buffer.withUnsafeMutableBytes { _ = memset($0.baseAddress, 0, $0.count) } }
        guard
            readpassphrase(prompt, &buffer, buffer.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY) != nil
        else {
            throw .invalidPassword(reason: "no password was entered")
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard bytes.count <= InstallRequest.maximumPasswordBytes else {
            throw InstallRequest.passwordTooLong
        }
        return Secret(String(decoding: bytes, as: UTF8.self))
    }
}
