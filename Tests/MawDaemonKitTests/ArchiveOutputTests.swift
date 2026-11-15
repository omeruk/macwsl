import Darwin
import Foundation
import MawClient
import MawCore
import MawProtocol
import MawXPC
import Testing
import os

@testable import MawDaemonKit

/// A pipe whose read end a thread drains into memory until its end.
final class DrainedPipe: Sendable {
    let writer: OwnedDescriptor
    private let reader: OwnedDescriptor
    private let collected = OSAllocatedUnfairLock(initialState: (bytes: [UInt8](), done: false))

    init() throws {
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        reader = OwnedDescriptor(fds[0])
        writer = OwnedDescriptor(fds[1])
        let reader = self.reader
        let collected = self.collected
        startDetachedThread {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(reader.rawValue, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                let chunk = Array(buffer[..<count])
                collected.withLock { $0.bytes += chunk }
            }
            collected.withLock { $0.done = true }
        }
    }

    deinit {
        reader.close()
        writer.close()
    }

    /// Everything read, once the write end has closed everywhere.
    func bytes() async throws -> [UInt8] {
        try await eventually("the pipe ends") { collected.withLock { $0.done } }
        return collected.withLock { $0.bytes }
    }
}

/// Ignores SIGPIPE in the test process, as the daemon does (`Serve`), so that a write to a pipe
/// whose reader has gone fails with `EPIPE`; `ArchiveOutput` leaves the client's descriptor as it
/// is.
func ignoreSIGPIPE() {
    signal(SIGPIPE, SIG_IGN)
}

/// A small pax archive with one file, made by the Mac's tar, as the guest's bsdtar would make
/// it.
func paxArchive(holding text: String) throws -> [UInt8] {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "maw-pax-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(text.utf8).write(to: directory.appending(path: "hello.txt"))
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/tar")
    process.arguments = ["-c", "-f", "-", "--format", "pax", "-C", directory.path, "hello.txt"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    return Array(data)
}

/// The names that `/usr/bin/tar -t` lists in `archive`.
func listed(_ archive: [UInt8]) throws -> [String] {
    let file = FileManager.default.temporaryDirectory.appending(
        path: "maw-list-\(UUID().uuidString)")
    try Data(archive).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/tar")
    process.arguments = ["-t", "-f", file.path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return [] }
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
}

/// Hands `bytes` to `output` in chunks of `size`, as the guest's output arrives, on a thread of
/// its own: a write may wait for the reader or for `/usr/bin/tar`, and must not hold a thread of
/// the cooperative pool, which other tests in the process share. Returns how many chunks were
/// accepted before one was refused.
func feed(_ output: ArchiveOutput, _ bytes: [UInt8], size: Int = 65536) async -> Int {
    await runOnDedicatedThread { () -> Int in
        var accepted = 0
        for start in stride(from: 0, to: bytes.count, by: size) {
            guard
                Array(bytes[start..<min(start + size, bytes.count)])
                    .withUnsafeBytes({ output.write($0) })
            else { break }
            accepted += 1
        }
        return accepted
    }
}

@Suite struct ArchiveOutputTests {
    @Test func writesATarArchiveAsTheGuestMadeIt() async throws {
        let pipe = try DrainedPipe()
        let output = try ArchiveOutput(
            format: .tar, destination: OwnedDescriptor(dup(pipe.writer.rawValue)))
        pipe.writer.close()
        #expect(await feed(output, Array("one two three".utf8), size: 4) == 4)
        let outcome = await output.finish()
        #expect(outcome == ArchiveOutput.Outcome(bytes: 13, failure: nil))
        #expect(try await pipe.bytes() == Array("one two three".utf8))
    }

    /// The Mac's tar compresses the guest's pax archive; the archive lists the same file.
    @Test(arguments: [
        (ArchiveFormat.tarGzip, [UInt8]([0x1F, 0x8B])),
        (.tarXz, [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]),
    ])
    func compressesWithTheMacsTar(_ format: ArchiveFormat, _ magic: [UInt8]) async throws {
        let archive = try paxArchive(holding: "hello from the guest\n")
        let pipe = try DrainedPipe()
        let output = try ArchiveOutput(
            format: format, destination: OwnedDescriptor(dup(pipe.writer.rawValue)))
        pipe.writer.close()
        // In two chunks, as the guest's output arrives.
        let half = (archive.count + 1) / 2
        #expect(await feed(output, archive, size: half) == 2)
        let outcome = await output.finish()
        #expect(outcome.failure == nil)
        let written = try await pipe.bytes()
        #expect(outcome.bytes == UInt64(written.count))
        #expect(Array(written.prefix(magic.count)) == magic)
        #expect(try listed(written) == ["hello.txt"])
    }

    @Test func reportsInputThatIsNoArchive() async throws {
        let pipe = try DrainedPipe()
        let output = try ArchiveOutput(
            format: .tarGzip, destination: OwnedDescriptor(dup(pipe.writer.rawValue)))
        pipe.writer.close()
        _ = Array(repeating: UInt8(ascii: "x"), count: 4096).withUnsafeBytes { output.write($0) }
        let outcome = await output.finish()
        guard case .compressorFailed(let reason) = outcome.failure else {
            Issue.record("\(String(describing: outcome.failure))")
            return
        }
        #expect(reason.hasPrefix("/usr/bin/tar exited with status"))
    }

    /// A reader that closes its end ends the archive with EPIPE, not with SIGPIPE, which would
    /// end this test process.
    @Test(arguments: [ArchiveFormat.tar, .tarGzip])
    func reportsAReaderThatClosedItsEnd(_ format: ArchiveFormat) async throws {
        ignoreSIGPIPE()
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        close(fds[0])
        let output = try ArchiveOutput(format: format, destination: OwnedDescriptor(fds[1]))
        let archive = try paxArchive(holding: String(repeating: "data ", count: 100_000))
        _ = await feed(output, archive)
        let outcome = await output.finish()
        #expect(outcome.failure == .readerClosed)
    }

    /// A reader that stops reading without closing its end holds a write up; `abort()` still
    /// ends the archive at once, the producer's next write returns false without waiting, and
    /// `finish()` reports the archive as aborted.
    @Test(arguments: [ArchiveFormat.tar, .tarGzip])
    func endsAtOnceWhenAbortedWhileTheReaderDoesNotRead(_ format: ArchiveFormat) async throws {
        ignoreSIGPIPE()
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        let reader = OwnedDescriptor(fds[0])
        defer { reader.close() }
        let output = try ArchiveOutput(format: format, destination: OwnedDescriptor(fds[1]))
        // Random bytes in base64, which gzip cannot shrink below a pipe's 64 KiB.
        let archive = try await runOnDedicatedThread { () throws -> [UInt8] in
            var random = [UInt8](repeating: 0, count: 1_500_000)
            arc4random_buf(&random, random.count)
            return try paxArchive(holding: Data(random).base64EncodedString())
        }
        let producer = Task { await feed(output, archive) }
        // The pipe fills, and the producer waits.
        try await Task.sleep(for: .milliseconds(500))
        let aborted = ContinuousClock.now
        output.abort()
        let chunks = await producer.value
        let outcome = await output.finish()
        #expect(ContinuousClock.now - aborted < .seconds(2))
        #expect(chunks < (archive.count + 65535) / 65536, "The producer was never held up.")
        #expect(outcome.failure == .aborted)
    }

    /// An archive aborted after its last chunk is still reported as aborted, since the export
    /// that aborted it was cancelled or failed.
    @Test(arguments: [ArchiveFormat.tar, .tarGzip])
    func reportsAnAbortAfterTheLastChunk(_ format: ArchiveFormat) async throws {
        let archive = try paxArchive(holding: "hello from the guest\n")
        let pipe = try DrainedPipe()
        let output = try ArchiveOutput(
            format: format, destination: OwnedDescriptor(dup(pipe.writer.rawValue)))
        pipe.writer.close()
        #expect(await feed(output, archive) == 1)
        output.abort()
        #expect(await output.finish().failure == .aborted)
        _ = try await pipe.bytes()
    }

    /// The thread that writes reports the failure; the next chunk is refused, and `finish()`
    /// returns it.
    @Test func reportsAWriteThatFails() async throws {
        let file = FileManager.default.temporaryDirectory.appending(
            path: "maw-ro-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let output = try ArchiveOutput(
            format: .tar, destination: OwnedDescriptor(open(file.path, O_RDONLY)))
        _ = Array("x".utf8).withUnsafeBytes { output.write($0) }
        #expect(!Array("y".utf8).withUnsafeBytes { output.write($0) })
        #expect(
            await output.finish()
                == ArchiveOutput.Outcome(bytes: 0, failure: .writeFailed("Bad file descriptor")))
    }

    @Test func compressesWithTheOptionOfEachFormat() {
        #expect(ArchiveOutput.compressorArguments(for: .tar) == nil)
        #expect(
            ArchiveOutput.compressorArguments(for: .tarGzip)
                == ["-c", "-f", "-", "--format", "pax", "--gzip", "@-"])
        #expect(
            ArchiveOutput.compressorArguments(for: .tarXz)
                == ["-c", "-f", "-", "--format", "pax", "--xz", "@-"])
    }
}
