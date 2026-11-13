import Darwin
import Foundation
import MawCore
import MawTestSupport
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

    /// The usage follows the allocated blocks: up when data is written, down when a range is
    /// discarded, as the guest's `fstrim` does through Virtualization.framework.
    @Test func reportsTheAllocatedSizeOfASparseImage() throws {
        let directory = try TemporaryDirectory()
        let image = directory.file("disk.img")
        try DiskImage.createSparse(at: image, size: .mebibytes(64))
        let empty = try #require(DiskImage.usage(image))
        #expect(empty.sizeBytes == ByteSize.mebibytes(64).bytes)
        #expect(empty.allocatedBytes < 1 << 20)

        let descriptor = open(image.path(percentEncoded: false), O_RDWR | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        let data = [UInt8](repeating: 0xA5, count: 8 << 20)
        try #require(pwrite(descriptor, data, data.count, 16 << 20) == data.count)
        try #require(fsync(descriptor) == 0)
        let written = try #require(DiskImage.usage(image))
        #expect(written.sizeBytes == ByteSize.mebibytes(64).bytes)
        #expect(written.allocatedBytes >= 8 << 20 && written.allocatedBytes < 10 << 20)
        #expect(Int64(written.allocatedBytes) == (try allocatedBytes(image)))

        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: 16 << 20, fp_length: 8 << 20)
        try #require(fcntl(descriptor, F_PUNCHHOLE, &hole) == 0)
        try #require(fsync(descriptor) == 0)
        let punched = try #require(DiskImage.usage(image))
        #expect(punched.sizeBytes == ByteSize.mebibytes(64).bytes)
        #expect(punched.allocatedBytes < 1 << 20)
    }

    @Test func reportsNoUsageForAMissingImage() throws {
        let directory = try TemporaryDirectory()
        #expect(DiskImage.usage(directory.file("missing.img")) == nil)
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
        // python3 can take seconds to start on a loaded machine. Should it never write, the
        // read ends when the process is stopped.
        let stopper = holder.terminate(after: .seconds(60))
        defer { stopper.cancel() }
        let locked = try await output.fileHandleForReading.readOnAThreadOfItsOwn(upToCount: 7)
        try #require(locked == Data("locked\n".utf8))
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
        #expect(await holder.waitForExit(within: .seconds(10)))
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
