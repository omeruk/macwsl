import Foundation
import MawCore
import Testing

@testable import MawAgentKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The mount of the Mac's home directory from the initramfs, against a root file system laid
/// out in a temporary directory.
@Suite struct MacShareMountTests {
    // MARK: Files read inside the root

    @Test func readsARegularFile() throws {
        let root = try RootFixture()
        try root.write("etc/passwd", "root:x:0:0::/root:/bin/sh\n")
        #expect(root.contents("/etc/passwd") == .success("root:x:0:0::/root:/bin/sh\n"))
    }

    @Test func followsAnAbsoluteLinkInsideTheRoot() throws {
        let root = try RootFixture()
        try root.write("data/passwd", "inside\n")
        try root.link("etc/passwd", to: "/data/passwd")
        #expect(root.contents("/etc/passwd") == .success("inside\n"))
    }

    /// An absolute link never reaches the files of the system that reads the root: here
    /// `/etc/hosts`, which the Mac running the test has, and the root does not.
    @Test func neverFollowsALinkOutOfTheRoot() throws {
        #expect(FileManager.default.fileExists(atPath: "/etc/hosts"))
        let root = try RootFixture()
        try root.link("etc/maw.conf", to: "/etc/hosts")
        #expect(root.contents("/etc/maw.conf") == .failure(.missing))
        try root.link("etc/passwd", to: "../../../../../../../../etc/hosts")
        #expect(root.contents("/etc/passwd") == .failure(.missing))
        try root.write("etc/hosts", "the root's own\n")
        #expect(root.contents("/etc/maw.conf") == .success("the root's own\n"))
        #expect(root.contents("/etc/passwd") == .success("the root's own\n"))
    }

    @Test func followsALinkedDirectoryInsideTheRoot() throws {
        let root = try RootFixture()
        try root.write("configuration/passwd", "linked directory\n")
        try root.link("etc", to: "/configuration")
        #expect(root.contents("/etc/passwd") == .success("linked directory\n"))
    }

    @Test func refusesLinksThatLoop() throws {
        let root = try RootFixture()
        try root.makeDirectory("etc")
        try root.link("etc/a", to: "b")
        try root.link("etc/b", to: "/etc/a")
        #expect(root.contents("/etc/a") == .failure(.tooManyLinks))
    }

    @Test func readsOnlyARegularFile() throws {
        let root = try RootFixture()
        try root.makeDirectory("etc/maw.conf")
        #expect(root.contents("/etc/maw.conf") == .failure(.notARegularFile))
        #expect(mkfifo(root.path("etc/passwd"), 0o644) == 0)
        #expect(root.contents("/etc/passwd") == .failure(.notARegularFile))
    }

    @Test func refusesAComponentThatIsNoDirectory() throws {
        let root = try RootFixture()
        try root.write("etc", "a file\n")
        #expect(root.contents("/etc/passwd") == .failure(.notADirectory("etc")))
    }

    @Test func refusesAFileAboveTheLimit() throws {
        let root = try RootFixture()
        try root.write("etc/passwd", String(repeating: "x", count: 100))
        #expect(root.contents("/etc/passwd", limit: 99) == .failure(.tooLarge(99)))
        #expect(root.contents("/etc/passwd", limit: 100).map(\.count) == .success(100))
    }

    // MARK: The owner

    static let passwd = """
        root:x:0:0:root:/root:/bin/bash
        ayse:x:1001:1002:Ayşe:/home/ayse:/bin/bash

        """

    @Test func choosesTheDefaultUser() throws {
        let root = try RootFixture()
        try root.write("etc/maw.conf", "[user]\ndefault = ayse\n")
        try root.write("etc/passwd", Self.passwd)
        #expect(
            root.owner()
                == .init(user: "ayse", uid: 1001, gid: 1002, fallbackReason: nil))
        #expect(root.owner().mountOptions == "uid=1001,gid=1002")
    }

    @Test func choosesRootWhenNoDefaultUserIsNamed() throws {
        let root = try RootFixture()
        try root.write("etc/passwd", Self.passwd)
        #expect(root.owner() == .root(because: nil))
        try root.write("etc/maw.conf", "[user]\n")
        #expect(root.owner() == .root(because: nil))
        try root.write("etc/maw.conf", "[user]\ndefault = root\n")
        #expect(root.owner() == .root(because: nil))
    }

    @Test func choosesRootWithTheReasonWhenTheUserCannotBeResolved() throws {
        let root = try RootFixture()
        try root.write("etc/maw.conf", "[user]\ndefault = ayse\n")
        #expect(root.owner() == .root(because: "/etc/passwd does not exist"))
        try root.write("etc/passwd", "root:x:0:0:root:/root:/bin/bash\n")
        #expect(
            root.owner()
                == .root(because: "the default user ayse of /etc/maw.conf is not in /etc/passwd"))
        try root.remove("etc/passwd")
        try root.link("etc/passwd", to: "passwd")
        #expect(
            root.owner()
                == .root(because: "/etc/passwd cannot be followed: more than 40 links"))
        try root.remove("etc/maw.conf")
        try root.write("etc/maw.conf", String(repeating: "#", count: (4 << 20) + 1))
        #expect(root.owner() == .root(because: "/etc/maw.conf is larger than 4194304 bytes"))
    }

    @Test func showsANameFromTheDistributionWithoutControlCharacters() throws {
        let root = try RootFixture()
        try root.write("etc/maw.conf", "[user]\ndefault = a\u{1B}[2Jb\n")
        try root.write("etc/passwd", Self.passwd)
        #expect(
            root.owner().fallbackReason
                == "the default user a?[2Jb of /etc/maw.conf is not in /etc/passwd")
    }

    // MARK: The mount point and the mount

    @Test func createsTheMountPointAndMountsOnIt() throws {
        let root = try RootFixture()
        try root.write("etc/maw.conf", "[user]\ndefault = ayse\n")
        try root.write("etc/passwd", Self.passwd)
        var calls: [(tag: String, inode: ino_t, options: String)] = []
        let result = MacShareMount.run(root: root.directory, tag: MacShare.tag) {
            tag, directory, options in
            var status = stat()
            fstat(directory, &status)
            calls.append((tag, status.st_ino, options))
            return 0
        }
        #expect(result.mounted)
        #expect(
            result.lines == [
                "maw-initramfs: /mnt/mac: mounted the share maw-mac; files show as ayse's"
                    + " (uid 1001, gid 1002)"
            ])
        #expect(try root.kind("mnt") == .directory(0o755))
        #expect(try root.kind("mnt/mac") == .directory(0o755))
        #expect(calls.count == 1)
        #expect(calls.first?.tag == "maw-mac")
        #expect(calls.first?.options == "uid=1001,gid=1002")
        #expect(calls.first?.inode == (try root.inode("mnt/mac")))
    }

    @Test func mountsOnAnEmptyMountPointThatExists() throws {
        let root = try RootFixture()
        try root.makeDirectory("mnt/mac")
        let result = root.mount()
        #expect(result.mounted)
        #expect(
            result.lines == [
                "maw-initramfs: /mnt/mac: mounted the share maw-mac; files show as root's"
                    + " (uid 0, gid 0)"
            ])
    }

    @Test func refusesALinkAtMnt() throws {
        let root = try RootFixture()
        let outside = try RootFixture()
        try root.link("mnt", to: outside.directory)
        let result = root.mount()
        #expect(!result.mounted)
        #expect(result.lines == ["maw-initramfs: /mnt/mac is not mounted: /mnt is a symbolic link"])
        #expect(!FileManager.default.fileExists(atPath: outside.path("mac")))
        try root.remove("mnt")
        try root.link("mnt", to: "/elsewhere")
        #expect(root.mount().lines.last?.hasSuffix("/mnt is a symbolic link") == true)
    }

    @Test func refusesALinkAtMntMac() throws {
        let root = try RootFixture()
        try root.makeDirectory("mnt")
        try root.makeDirectory("target")
        try root.link("mnt/mac", to: "/target")
        let result = root.mount()
        #expect(!result.mounted)
        #expect(
            result.lines == ["maw-initramfs: /mnt/mac is not mounted: /mnt/mac is a symbolic link"])
    }

    @Test func refusesAMountPointThatIsNoDirectory() throws {
        let root = try RootFixture()
        try root.write("mnt/mac", "a file\n")
        #expect(
            root.mount().lines == [
                "maw-initramfs: /mnt/mac is not mounted: /mnt/mac is not a directory"
            ])
        try root.remove("mnt")
        try root.write("mnt", "a file\n")
        #expect(
            root.mount().lines == [
                "maw-initramfs: /mnt/mac is not mounted: /mnt is not a directory"
            ])
    }

    @Test func refusesAMountPointThatIsNotEmpty() throws {
        let root = try RootFixture()
        try root.write("mnt/mac/notes.txt", "kept\n")
        let result = root.mount()
        #expect(!result.mounted)
        #expect(result.lines == ["maw-initramfs: /mnt/mac is not mounted: /mnt/mac is not empty"])
    }

    @Test func reportsAFailedMount() throws {
        let root = try RootFixture()
        let result = MacShareMount.run(root: root.directory, tag: MacShare.tag) { _, _, _ in
            EINVAL
        }
        #expect(!result.mounted)
        #expect(
            result.lines == [
                "maw-initramfs: /mnt/mac is not mounted: mounting the share maw-mac failed"
                    + " (\(String(cString: strerror(EINVAL))))"
            ])
    }

    @Test func reportsTheFallbackToRootBeforeTheMount() throws {
        let root = try RootFixture()
        try root.write("etc/maw.conf", "[user]\ndefault = ayse\n")
        #expect(
            root.mount().lines == [
                "maw-initramfs: /mnt/mac: files show as root's, because /etc/passwd does not"
                    + " exist",
                "maw-initramfs: /mnt/mac: mounted the share maw-mac; files show as root's"
                    + " (uid 0, gid 0)",
            ])
    }

    @Test func refusesAnUnknownTag() throws {
        let root = try RootFixture()
        let result = MacShareMount.run(root: root.directory, tag: "other") { _, _, _ in 0 }
        #expect(!result.mounted)
        #expect(
            result.lines == ["maw-initramfs: /mnt/mac is not mounted: the share other is unknown"])
        #expect(!FileManager.default.fileExists(atPath: root.path("mnt")))
    }

    // MARK: The mount table

    static let mountinfo = """
        24 1 254:0 / / rw,relatime shared:1 - ext4 /dev/vda rw
        40 24 0:39 / /mnt/mac rw,nosuid,nodev,relatime shared:20 - virtiofs maw-mac rw,uid=1000,gid=1000
        """

    @Test func findsTheShareInTheMountTable() {
        #expect(MountTable.showsMacShare(mountinfo: Self.mountinfo))
        #expect(!MountTable.showsMacShare(mountinfo: "24 1 254:0 / / rw - ext4 /dev/vda rw"))
        #expect(
            !MountTable.showsMacShare(
                mountinfo: "40 24 0:39 / /mnt/mac rw - virtiofs other rw"))
        #expect(
            !MountTable.showsMacShare(
                mountinfo: "40 24 0:39 / /mnt/mac2 rw - virtiofs maw-mac rw"))
        // Another file system mounted over the share hides it.
        #expect(
            !MountTable.showsMacShare(
                mountinfo: Self.mountinfo + "\n41 40 0:40 / /mnt/mac rw - tmpfs tmpfs rw"))
    }
}

/// A root file system in a temporary directory, removed when the fixture goes away.
final class RootFixture {
    enum Kind: Equatable {
        case directory(mode_t)
        case link
        case other
    }

    let directory: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "maw-root-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        directory = url.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: directory)
    }

    func path(_ relative: String) -> String {
        directory.hasSuffix("/") ? directory + relative : "\(directory)/\(relative)"
    }

    func write(_ relative: String, _ text: String) throws {
        let url = URL(filePath: path(relative))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(
            atPath: path(relative), withIntermediateDirectories: true)
    }

    func link(_ relative: String, to target: String) throws {
        let url = URL(filePath: path(relative))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: path(relative), withDestinationPath: target)
    }

    func remove(_ relative: String) throws {
        try FileManager.default.removeItem(atPath: path(relative))
    }

    func kind(_ relative: String) throws -> Kind {
        var status = stat()
        guard lstat(path(relative), &status) == 0 else {
            throw FixtureError(message: "lstat \(relative) failed with errno \(errno)")
        }
        switch status.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR): return .directory(status.st_mode & 0o7777)
        case mode_t(S_IFLNK): return .link
        default: return .other
        }
    }

    func inode(_ relative: String) throws -> ino_t {
        var status = stat()
        guard lstat(path(relative), &status) == 0 else {
            throw FixtureError(message: "lstat \(relative) failed with errno \(errno)")
        }
        return status.st_ino
    }

    /// The root opened as the initramfs opens `/sysroot`.
    private func withRoot<T>(_ body: (Int32) -> T) -> T {
        let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(descriptor) }
        return body(descriptor)
    }

    func contents(
        _ path: String, limit: Int = MacShareMount.fileLimit
    ) -> Result<String, InRootFile.Failure> {
        withRoot { InRootFile.contents(of: path, inRoot: $0, limit: limit) }
    }

    func owner() -> MacShareMount.Owner {
        withRoot { MacShareMount.owner(inRoot: $0) }
    }

    /// The mount with a fake that succeeds.
    func mount() -> (mounted: Bool, lines: [String]) {
        MacShareMount.run(root: directory, tag: MacShare.tag) { _, _, _ in 0 }
    }
}
