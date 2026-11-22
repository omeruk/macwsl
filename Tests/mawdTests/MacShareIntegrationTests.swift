import Darwin
import Foundation
import MawCore
import MawXPC
import Testing

/// The owner's home directory at /mnt/mac in a distribution (docs/decisions/0021-mac-share.md),
/// with the guest files that the Guest workflow builds: the kernel's virtiofs owner options
/// (Guest/kernel/patches), and the initramfs's mount.
///
/// The test daemon shares the owner's real home directory. Every test that writes through
/// /mnt/mac does so only in a directory of `MawIntegration.withMacDirectory`, which the test
/// creates under `~/Library/Caches/maw` and removes even on failure; no test lists, reads, or
/// changes anything else under /mnt/mac.
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled,
        "Integration tests boot a real virtual machine; run scripts/integration-test.sh."),
    .serialized,
    .timeLimit(.minutes(20))
)
struct MacShareIntegrationTests {
    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    /// `sh -c <script>` in the distribution, as `user` or the default user.
    func guest(
        _ script: String, as user: String? = nil, in distribution: String? = nil,
        timeout: Duration = .seconds(120)
    ) async throws -> DebugBootProcess.Result {
        try await maw.run(
            ["-d", distribution ?? maw.distribution] + (user.map { ["-u", $0] } ?? [])
                + ["-e", "sh", "-c", script], timeout: timeout)
    }

    /// The default user's `uid:gid`.
    func defaultOwner(in distribution: String? = nil) async throws -> String {
        let ids = try await guest("echo \"$(id -u):$(id -g)\"", in: distribution)
        try #require(ids.status == 0, "\(ids.standardError)")
        return ids.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stops the distribution's machine, so that the next session boots it again.
    func restart(_ distribution: String? = nil) async throws {
        let stopped = try await maw.run(["--terminate", distribution ?? maw.distribution])
        try #require(stopped.status == 0, "\(stopped.standardError)")
    }

    // MARK: The mount

    /// After a boot, root looks at /mnt/mac first, and still both root and the default user see
    /// the default user as the owner, because the mount names it (uid=, gid=).
    @Test func showsTheDefaultUserAsOwnerWhoeverLooksFirst() async throws {
        try await restart()
        let root = try await guest("stat -c %u:%g /mnt/mac /mnt/mac/Library", as: "root")
        let owner = try await defaultOwner()
        let user = try await guest("stat -c %u:%g /mnt/mac /mnt/mac/Library")
        try #require(root.status == 0, "\(root.standardError)")
        #expect(root.lines.filter { !$0.isEmpty } == [owner, owner])
        #expect(user.lines.filter { !$0.isEmpty } == [owner, owner])

        let mounts = try await guest("grep ' /mnt/mac ' /proc/self/mountinfo")
        let line = try #require(mounts.lines.first, "\(mounts.output)\(mounts.standardError)")
        let ids = owner.split(separator: ":")
        #expect(line.contains(" - virtiofs maw-mac "), "\(line)")
        #expect(line.contains("nosuid") && line.contains("nodev"), "\(line)")
        #expect(line.contains("uid=\(ids[0])") && line.contains("gid=\(ids[1])"), "\(line)")

        let console = maw.consoleLogLines(of: maw.distribution)
        #expect(console.contains("maw-initramfs: virtiofs tags: maw-mac"))
        #expect(
            console.contains(
                "maw-initramfs: /mnt/mac: mounted the share maw-mac; files show as \(maw.user)'s"
                    + " (uid \(ids[0]), gid \(ids[1]))"))
        #expect(
            try maw.daemonLogLines(since: "\(maw.distribution): /mnt/mac is mounted").isEmpty
                == false)
    }

    @Test func mountsTheShareAgainAfterARestart() async throws {
        for _ in 1...2 {
            try await restart()
            let mounts = try await guest(
                "grep -c ' /mnt/mac .* - virtiofs maw-mac ' /proc/self/mountinfo")
            #expect(mounts.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        }
    }

    /// The provisioning machine of the test distribution's installation had no share, by its
    /// own console; the distribution's machine has it.
    @Test func neverSharesTheHomeDirectoryWithTheProvisioningMachine() async throws {
        #expect(try await guest("true").status == 0)
        let installation = MawPaths.installLogFile(
            for: try DistroName(maw.distribution), in: maw.logDirectory)
        let lines = try String(contentsOf: installation, encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init)
        #expect(lines.contains("maw-initramfs: virtiofs tags: none"))
        #expect(!lines.contains { $0.contains("maw-mac") })
        #expect(
            maw.consoleLogLines(of: maw.distribution).contains(
                "maw-initramfs: virtiofs tags: maw-mac"))
    }

    /// A mount point that is a link is refused; the machine boots, sessions work, the console
    /// says why, and the daemon notes that the share is not mounted.
    @Test func bootsWhenTheMountIsRefused() async throws {
        try await maw.withDistribution("share-refused") { name in
            // --cd /: a session in the test runner's directory, under /mnt/mac, would keep the
            // share busy.
            let replaced = try await maw.run([
                "-d", name, "-u", "root", "--cd", "/", "-e", "sh", "-c",
                "umount /mnt/mac && rmdir /mnt/mac && ln -s /tmp /mnt/mac",
            ])
            try #require(replaced.status == 0, "\(replaced.standardError)")
            try await restart(name)
            // The session would start under /mnt/mac, which is not mounted: it starts in the
            // home directory, and maw names the console log.
            let session = try await guest("echo works", in: name)
            #expect(session.status == 0 && session.output == "works\n")
            #expect(
                session.standardError.contains(
                    "maw: /mnt/mac is not mounted in \(name); starting in the home directory."),
                "\(session.standardError)")
            #expect(
                maw.consoleLogLines(of: name).contains(
                    "maw-initramfs: /mnt/mac is not mounted: /mnt/mac is a symbolic link"))
            let mounts = try await guest("grep -c ' /mnt/mac ' /proc/self/mountinfo", in: name)
            #expect(mounts.output.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
            #expect(
                try maw.daemonLogLines(
                    since: "\(name): /mnt/mac is not mounted; its console log says why"
                ).isEmpty
                    == false)
        }
    }

    /// Ubuntu's weekly fstrim lists /mnt/mac among the mounted file systems; it runs as root
    /// and leaves the share and its owners alone.
    @Test func leavesTheShareToFstrim() async throws {
        let owner = try await defaultOwner()
        let run = try await guest(
            "systemctl start fstrim.service; systemctl show -p Result --value fstrim.service;"
                + " journalctl -b -u fstrim.service --no-pager -o cat | tail -n 20", as: "root",
            timeout: .seconds(300))
        print("fstrim.service:\n\(run.output)\(run.standardError)")
        #expect(run.lines.first == "success", "\(run.output)")
        #expect(try await guest("stat -c %u:%g /mnt/mac").output == "\(owner)\n")
    }

    /// The snapshot names the share while the distribution runs.
    @Test func reportsTheShareInTheSnapshot() async throws {
        let session = try IntegrationProbe(maw: maw)
        defer { session.stop() }
        let started = try #require(await session.result(1), "\(session.transcript)")
        try #require(started.hasPrefix("started "), "\(session.transcript)")
        let watcher = try Watcher(maw)
        defer { watcher.stop() }
        let running = try await watcher.first("the share") {
            $0.state == .running && $0.macShare != nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            .path(percentEncoded: false)
        #expect(
            running.figures.macShare
                == SharedDirectory(
                    macPath: home.hasSuffix("/") ? String(home.dropLast()) : home,
                    linuxPath: "/mnt/mac"))
    }

    // MARK: Files, owners, and modes

    /// A file created on the Mac is read in the guest, and one that the default user creates is
    /// the owner's on the Mac and editable there; names with non-ASCII letters arrive intact.
    @Test func carriesFilesBothWays() async throws {
        try await maw.withMacDirectory { mac, linux in
            let fromMac = "çay ğüşiöı.txt"
            try Data("from the Mac\n".utf8).write(to: mac.appending(path: fromMac))
            let read = try await guest("cat '\(linux)/\(fromMac)'")
            #expect(read.output == "from the Mac\n", "\(read.standardError)")

            let fromLinux = "from Linux ğ.txt"
            let written = try await guest("printf 'from Linux\\n' > '\(linux)/\(fromLinux)'")
            #expect(written.status == 0, "\(written.standardError)")
            let file = mac.appending(path: fromLinux)
            #expect(try String(contentsOf: file, encoding: .utf8) == "from Linux\n")
            let attributes = try FileManager.default.attributesOfItem(
                atPath: file.path(percentEncoded: false))
            #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())

            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("edited on the Mac\n".utf8))
            try handle.close()
            #expect(
                try await guest("cat '\(linux)/\(fromLinux)'").output
                    == "from Linux\nedited on the Mac\n")

            let listed = try await guest("ls '\(linux)'")
            #expect(Set(listed.lines.filter { !$0.isEmpty }) == [fromMac, fromLinux])
        }
    }

    /// Root looks at a repository first; the default user's git still accepts it, because the
    /// repository shows as the default user's.
    @Test func letsTheDefaultUsersGitAcceptARepositoryAfterRoot() async throws {
        try await maw.withMacDirectory { mac, linux in
            try Data("x\n".utf8).write(to: mac.appending(path: "x"))
            for arguments in [
                ["init", "-q"], ["add", "x"],
                [
                    "-c", "user.name=maw", "-c", "user.email=maw@localhost", "-c",
                    "commit.gpgsign=false", "commit", "-q", "-m", "x",
                ],
            ] {
                let git = try DebugBootProcess(
                    executable: URL(filePath: "/usr/bin/git"),
                    arguments: ["-C", mac.path(percentEncoded: false)] + arguments,
                    separateStandardError: true)
                let result = await git.waitForExit(timeout: .seconds(60))
                try #require(result.status == 0, "git \(arguments): \(result.standardError)")
            }
            try await restart()
            let root = try await guest("stat -c %u '\(linux)' '\(linux)/.git'", as: "root")
            #expect(root.status == 0, "\(root.standardError)")
            let status = try await guest("git -C '\(linux)' status --short && echo clean")
            #expect(status.status == 0, "\(status.standardError)")
            #expect(status.lines.last { !$0.isEmpty } == "clean")
        }
    }

    /// The guest checks each access against the default user as owner and the file's mode:
    /// another user (nobody) can neither write a file of mode 644 nor read one of mode 600,
    /// which the default user and root can.
    @Test func holdsOtherGuestUsersToTheFilesModes() async throws {
        try await maw.withMacDirectory { mac, linux in
            for (name, mode) in [("f644", 0o644), ("f600", 0o600)] {
                let file = mac.appending(path: name)
                try Data("\(name)\n".utf8).write(to: file)
                try FileManager.default.setAttributes(
                    [.posixPermissions: mode], ofItemAtPath: file.path(percentEncoded: false))
            }
            // Whether each access failed, not its status: dash, Ubuntu's sh, exits a failed
            // redirection with 2, and cat with 1.
            let nobody = try await guest(
                "if printf 'nobody\\n' >> '\(linux)/f644'; then echo 'append: allowed';"
                    + " else echo 'append: denied'; fi;"
                    + " if cat '\(linux)/f600' > /dev/null; then echo 'read: allowed';"
                    + " else echo 'read: denied'; fi", as: "nobody")
            #expect(
                nobody.lines.filter { !$0.isEmpty } == ["append: denied", "read: denied"],
                "\(nobody.output)\(nobody.standardError)")
            #expect(nobody.standardError.contains("Permission denied"))
            let user = try await guest(
                "printf 'user\\n' >> '\(linux)/f644' && cat '\(linux)/f600'")
            #expect(user.status == 0 && user.output == "f600\n", "\(user.standardError)")
            let root = try await guest("cat '\(linux)/f600'", as: "root")
            #expect(root.status == 0 && root.output == "f600\n", "\(root.standardError)")
            #expect(
                try String(contentsOf: mac.appending(path: "f644"), encoding: .utf8)
                    == "f644\nuser\n")
        }
    }
}
