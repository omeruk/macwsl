import Darwin
import Foundation
import MawCore
import Testing

@testable import MawVirtualization

@Suite struct DiskImageTests {
    private func allocatedBytes(_ url: URL) throws -> Int64 {
        var info = stat()
        try #require(stat(url.path(percentEncoded: false), &info) == 0)
        return Int64(info.st_blocks) * 512
    }

    @Test func createsASparseImage() throws {
        let directory = try TemporaryDirectory()
        let image = directory.file("disk.img")
        try DiskImage.createSparse(at: image, size: .gibibytes(4))

        let attributes = try FileManager.default.attributesOfItem(
            atPath: image.path(percentEncoded: false))
        #expect((attributes[.size] as? UInt64) == ByteSize.gibibytes(4).bytes)
        // A 4 GiB image must occupy almost nothing until the guest writes to it.
        #expect(try allocatedBytes(image) < 1 << 20)
        // Only its owner may read it.
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func seesALockThatAnotherProcessHolds() async throws {
        let directory = try TemporaryDirectory()
        let image = directory.file("disk.img")
        try DiskImage.createSparse(at: image, size: .mebibytes(1))
        #expect(!DiskImage.isLocked(image))

        // Another process holds an exclusive lock, as Virtualization.framework's machine does,
        // until its standard input closes.
        let holder = Process()
        holder.executableURL = URL(filePath: "/usr/bin/python3")
        holder.arguments = [
            "-I", "-c",
            "import fcntl,sys; f=open(sys.argv[1]); fcntl.flock(f, fcntl.LOCK_EX); "
                + "print('locked', flush=True); sys.stdin.read()",
            image.path(percentEncoded: false),
        ]
        let input = Pipe()
        let output = Pipe()
        holder.standardInput = input
        holder.standardOutput = output
        try holder.run()
        _ = try output.fileHandleForReading.read(upToCount: 7)
        #expect(DiskImage.isLocked(image))
        await #expect(throws: MawError.diskImageInUse(path: image.path(percentEncoded: false))) {
            try await DiskImage.waitUntilUnlocked(image, timeout: .milliseconds(200))
        }
        // It waits until the holder exits.
        let waiting = Task { try await DiskImage.waitUntilUnlocked(image, timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(300))
        try input.fileHandleForWriting.close()
        try await waiting.value
        #expect(!DiskImage.isLocked(image))
        holder.waitUntilExit()
    }

    @Test func refusesToOverwriteAnExistingFile() throws {
        let directory = try TemporaryDirectory()
        let image = directory.file("disk.img")
        let contents = Data("existing data".utf8)
        FileManager.default.createFile(
            atPath: image.path(percentEncoded: false), contents: contents)

        #expect(throws: MawError.diskImageExists(path: image.path(percentEncoded: false))) {
            try DiskImage.createSparse(at: image, size: .mebibytes(1))
        }
        #expect(FileManager.default.contents(atPath: image.path(percentEncoded: false)) == contents)
    }

    @Test func refusesAVolumeWithoutSparseFiles() throws {
        let directory = try TemporaryDirectory()
        let image = directory.file("disk.img")
        #expect(throws: MawError.sparseFilesUnsupported(path: image.path(percentEncoded: false))) {
            try DiskImage.createSparse(at: image, size: .mebibytes(1)) { _ in false }
        }
        #expect(!FileManager.default.fileExists(atPath: image.path(percentEncoded: false)))
    }

    @Test func reportsAMissingDirectory() throws {
        let directory = try TemporaryDirectory()
        let image = directory.file("missing/disk.img")
        #expect {
            try DiskImage.createSparse(at: image, size: .mebibytes(1))
        } throws: { error in
            guard case MawError.diskImageCreationFailed(let path, _) = error else {
                return false
            }
            return path == image.path(percentEncoded: false)
        }
    }
}
