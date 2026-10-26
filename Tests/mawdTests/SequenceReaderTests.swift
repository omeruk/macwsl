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
}
