import Darwin
import Foundation
import MawCore
import Testing

@testable import maw

/// An error printed after a session starts on a line of its own when the session's output
/// left a terminal's line open, and only then.
@Suite struct TerminalLineTests {
    func line(terminals: Set<Int32>) -> TerminalLine {
        TerminalLine { terminals.contains($0) }
    }

    func write(_ text: String, to descriptor: Int32, on line: TerminalLine) {
        Array(text.utf8).withUnsafeBytes { line.wrote($0, to: descriptor) }
    }

    @Test func separatesAMessageFromALineLeftOpen() {
        let line = line(terminals: [STDOUT_FILENO, STDERR_FILENO])
        #expect(line.separatorBeforeMessage() == "")
        write("1\n2\npartial", to: STDOUT_FILENO, on: line)
        #expect(line.separatorBeforeMessage() == "\n")
        write(" done\n", to: STDOUT_FILENO, on: line)
        #expect(line.separatorBeforeMessage() == "")
    }

    /// The cursor is at the start of a line after a carriage return, but the line still holds
    /// text, which the message would overwrite.
    @Test func countsALineEndingInACarriageReturnAsOpen() {
        let line = line(terminals: [STDOUT_FILENO, STDERR_FILENO])
        write("progress 50%\r", to: STDOUT_FILENO, on: line)
        #expect(line.separatorBeforeMessage() == "\n")
    }

    @Test func ignoresAnEmptyWrite() {
        let line = line(terminals: [STDOUT_FILENO, STDERR_FILENO])
        write("partial", to: STDOUT_FILENO, on: line)
        write("", to: STDOUT_FILENO, on: line)
        #expect(line.separatorBeforeMessage() == "\n")
    }

    @Test func addsNothingWhenStandardErrorIsNotATerminal() {
        let line = line(terminals: [STDOUT_FILENO])
        write("partial", to: STDOUT_FILENO, on: line)
        #expect(line.separatorBeforeMessage() == "")
    }

    /// Output to a pipe or a file does not move the terminal's cursor.
    @Test func ignoresWritesToAStreamThatIsNotATerminal() {
        let line = line(terminals: [STDERR_FILENO])
        write("warning\n", to: STDERR_FILENO, on: line)
        write("partial", to: STDOUT_FILENO, on: line)
        #expect(line.separatorBeforeMessage() == "")
        write("partial", to: STDERR_FILENO, on: line)
        #expect(line.separatorBeforeMessage() == "\n")
    }

    /// Standard output and standard error are often the same terminal: the last write decides.
    @Test func followsTheLastWriteToEitherTerminal() {
        let line = line(terminals: [STDOUT_FILENO, STDERR_FILENO])
        write("partial", to: STDOUT_FILENO, on: line)
        write("warning\n", to: STDERR_FILENO, on: line)
        #expect(line.separatorBeforeMessage() == "")
        write("partial", to: STDOUT_FILENO, on: line)
        #expect(line.separatorBeforeMessage() == "\n")
    }

    // MARK: Through the session's writer, on a pseudo-terminal

    /// Every error that ends a session, here `machineStopped`, starts on a new line.
    @Test(.timeLimit(.minutes(1)))
    func startsTheMessageOnANewLineOfTheTerminal() async {
        await #expect(processExitsWith: .success) {
            await TerminalLineTests.endSession(standardErrorIsTheTerminal: true)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func addsNothingToAStandardErrorThatIsAPipe() async {
        await #expect(processExitsWith: .success) {
            await TerminalLineTests.endSession(standardErrorIsTheTerminal: false)
        }
    }

    static let stopped = MawError.machineStopped(
        machine: "Ubuntu-24.04", reason: "maw --shutdown was run")

    /// In the child: a pseudo-terminal is standard output, and standard error too or a pipe.
    /// The session writes a line that it leaves open, then ends with an error, which is printed
    /// as `maw` prints it. Exits with 0 if the terminal and the pipe show what they should.
    static func endSession(standardErrorIsTheTerminal: Bool) async {
        var primary: Int32 = -1
        var secondary: Int32 = -1
        guard openpty(&primary, &secondary, nil, nil, nil) == 0 else { exit(10) }
        guard dup2(secondary, STDOUT_FILENO) >= 0 else { exit(11) }
        var pipeEnds: [Int32] = [-1, -1]
        if standardErrorIsTheTerminal {
            guard dup2(secondary, STDERR_FILENO) >= 0 else { exit(12) }
        } else {
            guard pipe(&pipeEnds) == 0, dup2(pipeEnds[1], STDERR_FILENO) >= 0 else { exit(13) }
            close(pipeEnds[1])
        }

        Array("1\npartial".utf8).withUnsafeBytes { SessionRunner.writeOutput(.stdout, $0) }
        do {
            _ = try await SessionRunner.endingOpenLines { () async throws -> Int32 in
                throw stopped
            }
            exit(14)
        } catch {
            FileHandle.standardError.write(Data((Maw.failure(for: error)?.output ?? "").utf8))
        }

        let message = "maw: The session ended because the virtual machine Ubuntu-24.04 stopped"
        // The terminal turns each line feed into a carriage return and a line feed.
        let shown = String(decoding: readAvailable(primary), as: UTF8.self)
            .replacing("\r\n", with: "\n")
        if standardErrorIsTheTerminal {
            guard shown.hasPrefix("1\npartial\n" + message) else { exit(15) }
        } else {
            guard shown == "1\npartial" else { exit(16) }
            let piped = String(decoding: readAvailable(pipeEnds[0]), as: UTF8.self)
            guard piped.hasPrefix(message) else { exit(17) }
        }
        exit(0)
    }

    /// What `descriptor` holds now, waiting at most a second for the first bytes.
    static func readAvailable(_ descriptor: Int32) -> [UInt8] {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        var wait: Int32 = 1_000
        while true {
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, wait) > 0 else { return bytes }
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { return bytes }
            bytes += buffer[..<count]
            wait = 100
        }
    }
}
