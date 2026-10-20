import Foundation
import MacWSLCore
import Testing

@testable import MacWSLVirtualization

@Suite struct ConsoleTests {
    private func contents(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func collect(_ lines: AsyncStream<String>) async -> [String] {
        var collected: [String] = []
        for await line in lines {
            collected.append(line)
        }
        return collected
    }

    // MARK: Back-pressure policy

    @Test func boundsTheLineStreamButLogsEveryLine() async throws {
        let directory = try TemporaryDirectory()
        let log = directory.file("test-console.log")
        let console = try Console(logURL: log, lineBufferLimit: 3)
        console.start()

        // No consumer reads `lines` while the guest writes 10 lines.
        for number in 1...10 {
            console.ingest(Data("line \(number)\n".utf8))
        }
        console.closeGuestSide()
        await console.waitUntilDrained()

        // The stream kept only the 3 newest lines; the log has all 10.
        #expect(await collect(console.lines) == ["line 8", "line 9", "line 10"])
        #expect(contents(log) == (1...10).map { "line \($0)\n" }.joined())
    }

    @Test func deliversEveryLineToAConsumerThatKeepsUp() async throws {
        let directory = try TemporaryDirectory()
        let console = try Console(logURL: directory.file("test-console.log"), lineBufferLimit: 3)
        let consumer = Task { await collect(console.lines) }
        console.start()

        for number in 1...10 {
            console.ingest(Data("line \(number)\n".utf8))
            // Give the consumer time to take each line before the next one arrives.
            try await Task.sleep(for: .milliseconds(20))
        }
        console.closeGuestSide()
        #expect(await consumer.value == (1...10).map { "line \($0)" })
    }

    @Test func copiesOutputToTheOutputHandle() async throws {
        let directory = try TemporaryDirectory()
        let output = Pipe()
        let console = try Console(
            logURL: directory.file("test-console.log"), output: output.fileHandleForWriting)
        console.start()
        console.ingest(Data("hello\r\nworld".utf8))
        console.closeGuestSide()
        await console.waitUntilDrained()
        try output.fileHandleForWriting.close()

        #expect(output.fileHandleForReading.readDataToEndOfFile() == Data("hello\r\nworld".utf8))
        #expect(await collect(console.lines) == ["hello", "world"])
    }

    @Test func forwardsInputToTheGuest() async throws {
        let directory = try TemporaryDirectory()
        let input = Pipe()
        let console = try Console(
            logURL: directory.file("test-console.log"), input: input.fileHandleForReading)
        console.start()
        try input.fileHandleForWriting.write(contentsOf: Data("uname -a\n".utf8))
        try input.fileHandleForWriting.close()

        let received = console.toGuest.fileHandleForReading.readData(ofLength: 9)
        #expect(received == Data("uname -a\n".utf8))
        console.closeGuestSide()
    }

    // MARK: Log file

    @Test func appendsToAnExistingLogAndMarksHostNotes() throws {
        let directory = try TemporaryDirectory()
        let log = directory.file("test-console.log")
        try Data("earlier boot\n".utf8).write(to: log)

        let console = try Console(logURL: log)
        console.note("starting")
        console.closeGuestSide()

        let lines = contents(log).split(separator: "\n")
        #expect(lines.first == "earlier boot")
        #expect(lines.last?.hasPrefix("[macwsld] ") == true)
        #expect(lines.last?.hasSuffix(" starting") == true)
    }

    @Test func startsANoteOnANewLine() async throws {
        let directory = try TemporaryDirectory()
        let log = directory.file("test-console.log")
        let console = try Console(logURL: log)
        console.start()
        console.ingest(Data("~ # ".utf8))
        console.closeGuestSide()
        await console.waitUntilDrained()
        console.note("shutdown: forced")

        #expect(contents(log).hasPrefix("~ # \n[macwsld] "))
    }

    @Test func rotatesALogThatIsAlreadyTooLarge() throws {
        let directory = try TemporaryDirectory()
        let log = directory.file("test-console.log")
        try Data(repeating: UInt8(ascii: "a"), count: 150).write(to: log)

        let console = try Console(logURL: log, rotationSize: 100)
        console.note("new boot")
        console.closeGuestSide()

        #expect(
            contents(directory.file("test-console.log.1")) == String(repeating: "a", count: 150))
        #expect(contents(log).contains("new boot"))
        #expect(!contents(log).contains("aaa"))
    }

    @Test func rotatesOnceWhileWriting() throws {
        let directory = try TemporaryDirectory()
        let log = directory.file("test-console.log")
        let console = try Console(logURL: log, rotationSize: 100)
        console.note(String(repeating: "x", count: 120))
        console.note("second")
        console.note(String(repeating: "y", count: 120))
        console.note("fourth")
        console.closeGuestSide()

        // Only one previous log is kept.
        #expect(contents(directory.file("test-console.log.1")).contains("yyyy"))
        #expect(contents(log).contains("fourth"))
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.file("test-console.log.2").path(percentEncoded: false)))
    }

    @Test func reportsALogThatCannotBeCreated() throws {
        let directory = try TemporaryDirectory()
        let blocker = directory.file("not-a-directory")
        try Data().write(to: blocker)
        let log = blocker.appending(path: "test-console.log")
        #expect {
            _ = try Console(logURL: log)
        } throws: { error in
            guard case MacWSLError.consoleLogFailed(let path, _) = error else { return false }
            return path == log.path(percentEncoded: false)
        }
    }

    // MARK: Line splitting

    @Test func splitsLinesAcrossChunks() {
        var splitter = LineSplitter(maximumLineLength: 100)
        #expect(splitter.append(Array("hel".utf8)).isEmpty)
        #expect(splitter.append(Array("lo\r\nwor".utf8)) == ["hello"])
        #expect(splitter.append(Array("ld\n\n".utf8)) == ["world", ""])
        #expect(splitter.finish() == nil)
    }

    @Test func boundsALineWithoutANewline() {
        var splitter = LineSplitter(maximumLineLength: 8)
        #expect(splitter.append(Array("abcdefghij\n".utf8)) == ["abcdefgh", "ij"])
        #expect(splitter.append(Array("tail".utf8)).isEmpty)
        #expect(splitter.finish() == "tail")
    }

    @Test func decodesInvalidUTF8Lossily() {
        var splitter = LineSplitter(maximumLineLength: 100)
        #expect(splitter.append([0x61, 0xFF, 0x62, 0x0A]) == ["a\u{FFFD}b"])
    }
}
