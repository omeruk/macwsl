import CryptoKit
import Darwin
import Foundation
import MawCore
import MawVirtualization
import Testing

/// A distribution whose root file system is damaged before it boots: damage that `e2fsck -p`
/// repairs, after which the distribution boots, and damage that it refuses, after which the
/// daemon reports `rootFileSystemCheckFailed` and the disk image is unchanged.
///
/// Each test installs a distribution of its own under `MAW_TEST_PREFIX`, damages only that
/// distribution's disk image, and removes it at the end. The shared test distribution is never
/// changed. The damage is written from the Mac into the ext4 superblock, so that no Linux file
/// system tool is needed on the Mac.
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled,
        "Integration tests boot a real virtual machine; run scripts/integration-test.sh."),
    .serialized,
    // Bounds each test as a whole; every wait in it also has a time limit of its own.
    .timeLimit(.minutes(20))
)
struct RootFileSystemIntegrationTests {
    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    /// Clears the "cleanly unmounted" flag in the superblock, as an unclean shutdown of a
    /// file system without a journal leaves it. `e2fsck -p` then checks the whole file system
    /// and exits with 1, errors corrected, and the distribution boots.
    @Test func bootsAFileSystemThatE2fsckRepairs() async throws {
        let name = "\(maw.prefix)-repaired"
        let disk = try await installAndStop(name)
        try Superblock.modify(disk) { superblock in
            superblock.state &= ~Superblock.validState
        }
        let consoleLog = try consoleLog(of: name)
        let logStart = try size(of: consoleLog)

        let result = try await maw.session(["-e", "true"], in: name)
        #expect(result.status == 0, "\(result.standardError)")

        let boot = try consoleText(of: consoleLog, from: logStart)
        let check = boot.split(separator: "\n").compactMap {
            RootFileSystemCheck(consoleLine: String($0))
        }.last
        #expect(check?.outcome == .repaired, "\(boot)")
        if let status = check?.e2fsckStatus {
            #expect(
                boot.contains(
                    "maw-initramfs: e2fsck -p corrected errors on /dev/vda "
                        + "(exit status \(status))"),
                "\(boot)")
        }
        _ = try await maw.run(["--shutdown"])
        try await DiskImage.waitUntilUnlocked(disk, timeout: .seconds(10))
        #expect(try Superblock.read(disk).state & Superblock.validState != 0)
        try await maw.remove(name)
    }

    /// Overwrites the primary superblock with zeros. `e2fsck -p` does not look for a backup
    /// superblock, cannot open the file system, and exits with 8 before it writes anything;
    /// the initramfs powers the machine off.
    @Test func reportsAFileSystemThatE2fsckCannotCheckAndLeavesItsImageUnchanged() async throws {
        let name = "\(maw.prefix)-unreadable"
        let disk = try await installAndStop(name)
        try Superblock.overwriteWithZeros(disk)
        let before = try digest(of: disk)
        let consoleLog = try consoleLog(of: name)
        let logStart = try size(of: consoleLog)

        let result = try await maw.session(["-e", "true"], in: name)
        let expected = MawError.rootFileSystemCheckFailed(
            distribution: try DistroName(name), e2fsckStatus: 8,
            diskImage: disk.path(percentEncoded: false),
            consoleLog: consoleLog.path(percentEncoded: false))
        #expect(result.status == 1)
        #expect(
            result.standardError
                == "maw: \(expected.errorDescription ?? "")\n\(expected.recoverySuggestion ?? "")\n",
            "\(result.standardError)")

        let boot = try consoleText(of: consoleLog, from: logStart)
        #expect(boot.contains("maw-initramfs: root-check e2fsck-status=8\n"), "\(boot)")
        #expect(
            boot.contains("maw-initramfs: e2fsck -p could not check /dev/vda (exit status 8)"),
            "\(boot)")
        #expect(!boot.contains("maw-initramfs: starting systemd"), "\(boot)")

        try await DiskImage.waitUntilUnlocked(disk, timeout: .seconds(10))
        #expect(try digest(of: disk) == before, "The attempt to start \(name) changed its disk.")
        try await maw.remove(name)
    }

    // MARK: Helpers

    /// Installs `name`, stops the test daemon's machines, and returns the disk image once no
    /// virtual machine holds it.
    private func installAndStop(_ name: String) async throws -> URL {
        let install = await (try maw.install(name)).waitForExit(timeout: .seconds(300))
        try #require(install.status == 0, "\(install.output)\(install.standardError)")
        let stop = try await maw.run(["--shutdown"])
        try #require(stop.status == 0, "\(stop.standardError)")
        let disk = maw.paths.diskImage(for: try DistroName(name))
        try await DiskImage.waitUntilUnlocked(disk, timeout: .seconds(10))
        return disk
    }

    private func consoleLog(of name: String) throws -> URL {
        MawPaths.consoleLogFile(forMachineNamed: name, in: maw.logDirectory)
    }

    private func size(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false))
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// The console log from `offset` on, with the guest's CRLF line endings as LF, as the
    /// daemon's line splitter reads them.
    private func consoleText(of url: URL, from offset: UInt64) throws -> String {
        String(decoding: try contents(of: url, from: offset), as: UTF8.self)
            .replacing("\r\n", with: "\n")
    }

    private func contents(of url: URL, from offset: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.readToEnd() ?? Data()
    }

    /// The SHA-256 of a sparse file's size, the offset and length of each of its data
    /// regions, and their contents. Holes read as zeros and are not read; a write anywhere,
    /// even of zeros into a hole, changes the regions or their contents.
    private func digest(of url: URL) throws -> SHA256Digest {
        let descriptor = open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        try #require(descriptor >= 0, "Cannot open \(url.path(percentEncoded: false)).")
        defer { close(descriptor) }
        var hasher = SHA256()
        let end = lseek(descriptor, 0, SEEK_END)
        withUnsafeBytes(of: UInt64(end).littleEndian) { hasher.update(bufferPointer: $0) }
        var buffer = [UInt8](repeating: 0, count: 4 << 20)
        var offset: off_t = 0
        while offset < end {
            let data = lseek(descriptor, offset, SEEK_DATA)
            if data < 0 {
                try #require(
                    errno == ENXIO, "SEEK_DATA failed: \(String(cString: strerror(errno)))")
                break
            }
            var hole = lseek(descriptor, data, SEEK_HOLE)
            if hole < 0 { hole = end }
            for value in [UInt64(data), UInt64(hole - data)] {
                withUnsafeBytes(of: value.littleEndian) { hasher.update(bufferPointer: $0) }
            }
            var position = data
            while position < hole {
                let count = buffer.withUnsafeMutableBytes {
                    pread(descriptor, $0.baseAddress, min($0.count, Int(hole - position)), position)
                }
                try #require(count > 0, "Reading the disk image failed at \(position).")
                buffer.withUnsafeBytes {
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count]))
                }
                position += off_t(count)
            }
            offset = hole
        }
        return hasher.finalize()
    }
}

/// The primary ext4 superblock: 1024 bytes at offset 1024 of the disk image, in the layout of
/// e2fsprogs' `lib/ext2fs/ext2_fs.h`.
private struct Superblock {
    static let offset: UInt64 = 1024
    static let size = 1024
    static let magic: UInt16 = 0xEF53
    /// `EXT2_VALID_FS` in `s_state`: the file system was cleanly unmounted.
    static let validState: UInt16 = 0x0001
    /// `EXT4_FEATURE_RO_COMPAT_METADATA_CSUM` in `s_feature_ro_compat`.
    static let metadataChecksumFeature: UInt32 = 0x0400

    var bytes: [UInt8]

    var state: UInt16 {
        get { UInt16(bytes[0x3A]) | UInt16(bytes[0x3B]) << 8 }
        set {
            bytes[0x3A] = UInt8(newValue & 0xFF)
            bytes[0x3B] = UInt8(newValue >> 8)
        }
    }

    var magicNumber: UInt16 { UInt16(bytes[0x38]) | UInt16(bytes[0x39]) << 8 }
    var readOnlyCompatibleFeatures: UInt32 { word(at: 0x64) }
    var checksum: UInt32 { word(at: 0x3FC) }

    /// `ext2fs_superblock_csum`: CRC-32C of the bytes before `s_checksum`, seeded with all
    /// ones and without the final inversion.
    var computedChecksum: UInt32 { CRC32C.update(0xFFFF_FFFF, bytes[..<0x3FC]) }

    private func word(at index: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[index + $1]) << (8 * $1) }
    }

    static func read(_ url: URL) throws -> Superblock {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try #require(try handle.read(upToCount: size))
        try #require(data.count == size)
        let superblock = Superblock(bytes: [UInt8](data))
        try #require(superblock.magicNumber == magic, "\(url.path) has no ext4 superblock.")
        return superblock
    }

    /// Applies `change` and writes the superblock back with its checksum updated, after
    /// checking that this checksum computation reproduces the one already stored.
    static func modify(_ url: URL, _ change: (inout Superblock) -> Void) throws {
        var superblock = try read(url)
        let checksummed = superblock.readOnlyCompatibleFeatures & metadataChecksumFeature != 0
        if checksummed {
            try #require(
                superblock.computedChecksum == superblock.checksum,
                "The computed superblock checksum differs from the stored one.")
        }
        change(&superblock)
        if checksummed {
            let value = superblock.computedChecksum
            for index in 0..<4 {
                superblock.bytes[0x3FC + index] = UInt8((value >> (8 * UInt32(index))) & 0xFF)
            }
        }
        try write(superblock.bytes, to: url)
    }

    static func overwriteWithZeros(_ url: URL) throws {
        _ = try read(url)
        try write([UInt8](repeating: 0, count: size), to: url)
    }

    private static func write(_ bytes: [UInt8], to url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data(bytes))
        try handle.synchronize()
    }
}

/// CRC-32C (Castagnoli), reflected, as `ext2fs_crc32c_le` computes it.
private enum CRC32C {
    static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in
            crc & 1 != 0 ? (crc >> 1) ^ 0x82F6_3B78 : crc >> 1
        }
    }

    static func update(_ crc: UInt32, _ bytes: some Sequence<UInt8>) -> UInt32 {
        bytes.reduce(crc) { crc, byte in
            table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
    }
}
