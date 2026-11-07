import Darwin
import Foundation
import Testing

/// The freeze tests rely on `SequenceReader` to find a lost line.
@Suite struct SequenceReaderTests {
    func read(_ text: String, until done: (SequenceReader.Progress) -> Bool) async throws
        -> SequenceReader.Progress
    {
        let pipe = Pipe()
        let reader = SequenceReader(descriptor: pipe.fileHandleForReading.fileDescriptor)
        defer { withExtendedLifetime(pipe) { reader.stop() } }
        try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try pipe.fileHandleForWriting.close()
        // Nothing is read before `resume()`.
        try await Task.sleep(for: .milliseconds(50))
        #expect(reader.progress == SequenceReader.Progress())
        reader.resume()
        let deadline = ContinuousClock.now + .seconds(10)
        while !done(reader.progress) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return reader.progress
    }

    @Test func countsLinesInOrder() async throws {
        let progress = try await read("1\n2\r\n3\n4") { $0.atEnd }
        #expect(progress.lines == 3)
        #expect(progress.bytes == 8)
        #expect(progress.error == nil)
    }

    @Test(arguments: [
        ("1\n3\n", "line 2 was 3"),
        ("1\n2\n2\n", "line 3 was 2"),
        ("1\n\n", "line 2 was empty"),
        ("1\ny\n", "byte 121 after line 1, which is not a digit"),
    ])
    func findsALineOutOfOrder(text: String, error: String) async throws {
        let progress = try await read(text) { $0.atEnd }
        #expect(progress.error == error)
    }

    @Test(arguments: [
        ("1\n2\nmaw: lost\r\n", "maw: lost\r\n"),
        ("1\n23\n", "23\n"),
        ("1\n2x\u{1B}[0m\n", "2x\u{1B}[0m\n"),
    ])
    func keepsWhatArrivedInsteadOfTheSequence(text: String, captured: String) async throws {
        let progress = try await read(text) { $0.atEnd }
        #expect(progress.captured == Array(captured.utf8))
    }

    @Test func keepsTheBytesOfLaterReads() async throws {
        let pipe = Pipe()
        let reader = SequenceReader(
            descriptor: pipe.fileHandleForReading.fileDescriptor, reading: true)
        defer { withExtendedLifetime(pipe) { reader.stop() } }
        try pipe.fileHandleForWriting.write(contentsOf: Data("1\nmaw: ".utf8))
        #expect(await reader.waitForLines(2, timeout: .seconds(10)) == false)
        try pipe.fileHandleForWriting.write(contentsOf: Data("the session ended\n".utf8))
        try pipe.fileHandleForWriting.close()
        await reader.waitForCapture()
        let progress = reader.progress
        #expect(progress.captured == Array("maw: the session ended\n".utf8))
        #expect(progress.atEnd)
        #expect(
            progress.description
                == "lines: 1, bytes: 25, at end: true, error: byte 109 after line 1, which is not "
                + "a digit, then 23 bytes: \"maw: the session ended\\n\"")
    }

    @Test func keepsAtMostTheLimit() async throws {
        let text = "1\n" + String(repeating: "x", count: SequenceReader.capturedLimit + 100)
        let progress = try await read(text) { $0.atEnd }
        #expect(progress.captured.count == SequenceReader.capturedLimit)
        #expect(progress.bytes == text.utf8.count)
    }
}
