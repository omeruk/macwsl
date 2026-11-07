import Darwin
import Foundation
import MawCore
import MawXPC
import Testing
import os

@testable import maw

/// `PromptTerminal.readSecret` on a pseudo-terminal that is the controlling terminal, typed
/// on as a user would: a password up to `InstallRequest.maximumPasswordBytes` is read whole,
/// and a longer one is refused, never cut short.
///
/// Each test runs in a child process, which can take a new controlling terminal.
@Suite struct PromptTerminalTests {
    @Test(.timeLimit(.minutes(1)))
    func readsAPasswordAtTheLimitWhole() async {
        await #expect(processExitsWith: .success) {
            await PromptTerminalTests.read(String(repeating: "a", count: 511), expecting: .whole)
        }
    }

    /// The limit counts bytes: 509 ASCII bytes and a two-byte "ğ".
    @Test(.timeLimit(.minutes(1)))
    func countsBytesRatherThanCharacters() async {
        await #expect(processExitsWith: .success) {
            await PromptTerminalTests.read(
                String(repeating: "a", count: 509) + "ğ", expecting: .whole)
        }
        await #expect(processExitsWith: .success) {
            await PromptTerminalTests.read(
                String(repeating: "a", count: 510) + "ğ", expecting: .tooLong)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func refusesAPasswordOneByteOverTheLimit() async {
        await #expect(processExitsWith: .success) {
            await PromptTerminalTests.read(String(repeating: "a", count: 512), expecting: .tooLong)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func refusesALongerPassword() async {
        await #expect(processExitsWith: .success) {
            await PromptTerminalTests.read(
                String(repeating: "a", count: 1_000), expecting: .tooLong)
        }
    }

    @Test func statesTheLimitWithinEightyColumns() throws {
        let failure = try #require(Maw.failure(for: InstallRequest.passwordTooLong))
        #expect(
            failure.output
                == "maw: The password cannot be used: it is longer than sudo's limit of 511 "
                + "bytes.\nType the same non-empty password twice. With --user, give it as the "
                + "first\nline of standard input.\n")
        for line in failure.output.split(separator: "\n") {
            #expect(line.count <= 80, "\(line)")
        }
    }

    enum Expected {
        case whole
        case tooLong
    }

    /// In the child: makes a new pseudo-terminal the controlling terminal, types `password`
    /// once the prompt has appeared, and checks what `readSecret` returned. Exits with 0 if it
    /// matched `expected`, otherwise with a status that names what differed.
    static func read(_ password: String, expecting expected: Expected) async {
        var primary: Int32 = -1
        var secondary: Int32 = -1
        guard openpty(&primary, &secondary, nil, nil, nil) == 0 else { exit(10) }
        guard setsid() >= 0 else { exit(11) }
        guard ioctl(secondary, TIOCSCTTY, 0) == 0 else { exit(12) }

        // readpassphrase discards what was typed before it turned echo off, so the password
        // is typed once the prompt has appeared.
        let terminal = primary
        let typist = Thread {
            var shown: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !String(decoding: shown, as: UTF8.self).contains("Password: ") {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(terminal, $0.baseAddress, $0.count)
                }
                guard count > 0 else { return }
                shown += buffer[..<count]
            }
            let line = Array((password + "\n").utf8)
            _ = line.withUnsafeBytes { Darwin.write(terminal, $0.baseAddress, $0.count) }
            // Keeps reading, so that the terminal never blocks a write.
            while buffer.withUnsafeMutableBytes({
                Darwin.read(terminal, $0.baseAddress, $0.count)
            }) > 0 {}
        }
        typist.start()

        guard let prompt = try? PromptTerminal.open() else { exit(13) }
        let result = Result { () throws(MawError) in try prompt.readSecret(prompt: "Password: ") }
        switch (result, expected) {
        case (.success(let secret), .whole):
            exit(secret.value == password ? 0 : 14)
        case (.failure(let error), .tooLong):
            exit(error == InstallRequest.passwordTooLong ? 0 : 15)
        case (.success, .tooLong):
            exit(16)
        case (.failure, .whole):
            exit(17)
        }
    }
}
