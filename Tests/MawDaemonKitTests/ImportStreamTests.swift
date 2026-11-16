import Darwin
import Foundation
import MawProtocol
import Testing
import os

@testable import MawDaemonKit

/// The Mac's part of an import's extraction (`ImportStream`): `/usr/bin/gzip -dcf`, and the
/// check that only a tar archive is forwarded. An mtree stream must never make the Mac read a
/// file that it names, as `/usr/bin/tar` did.
@Suite struct ImportStreamTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "maw-import-stream-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A tar archive of one file, as a ustar header and its block of data.
    static func tarArchive(contents: String = "hello\n") -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int) {
            header.replaceSubrange(offset..<(offset + text.utf8.count), with: Array(text.utf8))
        }
        put("file", at: 0)
        put("0000644", at: 100)
        put("0000000", at: 108)
        put("0000000", at: 116)
        put(String(format: "%011o", contents.utf8.count), at: 124)
        put("00000000000", at: 136)
        header[156] = 0x30
        put("ustar", at: 257)
        put("00", at: 263)
        header.replaceSubrange(148..<156, with: [UInt8](repeating: 0x20, count: 8))
        put(String(format: "%06o", header.reduce(0) { $0 + Int($1) }), at: 148)
        header[154] = 0
        var data = Data(header) + Data(contents.utf8)
        data.append(Data(count: (512 - contents.utf8.count % 512) % 512 + 1_024))
        return data
    }

    /// Writes `data` to a file and returns a descriptor that reads it.
    func source(_ data: Data, name: String = UUID().uuidString) throws -> OwnedDescriptor {
        let file = directory.appending(path: name)
        try data.write(to: file)
        let descriptor = open(file.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        try #require(descriptor >= 0)
        return OwnedDescriptor(descriptor)
    }

    /// `data` compressed by `/usr/bin/gzip`.
    func gzipped(_ data: Data) throws -> Data {
        let file = directory.appending(path: "plain-\(UUID().uuidString)")
        try data.write(to: file)
        let gzip = Process()
        gzip.executableURL = URL(filePath: "/usr/bin/gzip")
        gzip.arguments = ["-k", file.path(percentEncoded: false)]
        try gzip.run()
        gzip.waitUntilExit()
        try #require(gzip.terminationStatus == 0)
        return try Data(contentsOf: file.appendingPathExtension("gz"))
    }

    func run(_ source: OwnedDescriptor) async throws -> (ImportStream.Outcome, Data) {
        try await runOnDedicatedThread { () throws -> (ImportStream.Outcome, Data) in
            var forwarded = Data()
            let outcome = try ImportStream.run(source: source) { chunk in
                forwarded.append(chunk)
                return true
            }
            return (outcome, forwarded)
        }
    }

    /// An mtree stream names a file of the Mac, whose contents libarchive would read. It is not
    /// a tar archive, and nothing of it, or of the file, is forwarded, compressed or not.
    @Test func refusesAnMtreeStreamWithoutReadingTheFilesItNames() async throws {
        let mtree = Data("#mtree\n./copied type=file contents=/etc/hosts\n".utf8)
        for data in [mtree, try gzipped(mtree)] {
            let (outcome, forwarded) = try await run(try source(data))
            #expect(outcome == .notATarArchive)
            #expect(forwarded.isEmpty)
        }
    }

    @Test func forwardsATarArchiveAsItIs() async throws {
        let archive = Self.tarArchive()
        let (outcome, forwarded) = try await run(try source(archive))
        #expect(
            outcome
                == .streamed(
                    bytes: UInt64(archive.count),
                    decompressor: StreamingProcess.Outcome(status: 0, errors: "")))
        #expect(forwarded == archive)
    }

    @Test func decompressesACompressedTarArchive() async throws {
        let archive = Self.tarArchive(contents: String(repeating: "maw ", count: 10_000))
        let (outcome, forwarded) = try await run(try source(try gzipped(archive)))
        guard case .streamed(let bytes, let decompressor) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(bytes == UInt64(archive.count))
        #expect(decompressor.status == 0)
        #expect(forwarded == archive)
    }

    /// A truncated compressed archive forwards what was decompressed, and the decompressor's
    /// status reports the failure.
    @Test func reportsATruncatedCompressedArchive() async throws {
        // Random letters, so that half of the compressed stream decompresses to more than the
        // 64 KiB that gzip writes at a time.
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let archive = Self.tarArchive(
            contents: String((0..<1_000_000).map { _ in letters.randomElement()! }))
        let compressed = try gzipped(archive)
        let (outcome, _) = try await run(try source(compressed.prefix(compressed.count / 2)))
        guard case .streamed(_, let decompressor) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(decompressor.status != 0)
    }

    @Test func refusesAnEmptyOrShortStream() async throws {
        for data in [Data(), Data("ustar".utf8), Data(count: 200)] {
            let (outcome, forwarded) = try await run(try source(data))
            #expect(outcome == .notATarArchive, "\(data.count) bytes")
            #expect(forwarded.isEmpty)
        }
    }

    // MARK: The gate on its own

    /// The magic can arrive in pieces; nothing is forwarded until it has.
    @Test func waitsForTheMagicAcrossChunks() {
        let archive = Self.tarArchive()
        var gate = TarGate()
        #expect(gate.accept(archive.prefix(100)) == [])
        #expect(gate.accept(archive[100..<260]) == [])
        #expect(gate.accept(archive[260..<600]) == [archive.prefix(600)])
        #expect(gate.accept(archive[600...]) == [archive[600...]])
        #expect(gate.finish() == [])
    }

    @Test func refusesAStreamWithoutTheMagic() {
        var gate = TarGate()
        #expect(gate.accept(Data(count: 512)) == nil)
        var short = TarGate()
        #expect(short.accept(Data(count: 100)) == [])
        #expect(short.finish() == nil)
    }
}
