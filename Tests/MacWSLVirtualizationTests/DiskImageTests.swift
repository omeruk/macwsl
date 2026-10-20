import Darwin
import Foundation
import MacWSLCore
import Testing

@testable import MacWSLVirtualization

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
    }

    @Test func refusesToOverwriteAnExistingFile() throws {
        let directory = try TemporaryDirectory()
        let image = directory.file("disk.img")
        let contents = Data("existing data".utf8)
        FileManager.default.createFile(
            atPath: image.path(percentEncoded: false), contents: contents)

        #expect(throws: MacWSLError.diskImageExists(path: image.path(percentEncoded: false))) {
            try DiskImage.createSparse(at: image, size: .mebibytes(1))
        }
        #expect(FileManager.default.contents(atPath: image.path(percentEncoded: false)) == contents)
    }

    @Test func refusesAVolumeWithoutSparseFiles() throws {
        let directory = try TemporaryDirectory()
        let image = directory.file("disk.img")
        #expect(throws: MacWSLError.sparseFilesUnsupported(path: image.path(percentEncoded: false)))
        {
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
            guard case MacWSLError.diskImageCreationFailed(let path, _) = error else {
                return false
            }
            return path == image.path(percentEncoded: false)
        }
    }
}
