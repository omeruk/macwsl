import Darwin
import Foundation
import MawCore
import MawProtocol
import Testing

/// `maw --unregister` and `maw --export` against the test daemon.
///
/// The test daemon shares the owner's distributions directory and `state.json`. Every
/// `--unregister` here therefore goes through `MawIntegration.unregister`, which runs it only for
/// a name that this process installed under `MAW_TEST_PREFIX`, and every test that changes the
/// default restores `state.json` afterwards. Archives go only into `MAW_TEST_EXPORT_DIRECTORY`,
/// in the run's temporary directory, and each test deletes its own when it ends, also when it
/// fails (`MawIntegration.withExportDirectory`).
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled,
        "Integration tests boot a real virtual machine; run scripts/integration-test.sh."),
    .serialized,
    // Bounds each test as a whole; every wait in it also has a time limit of its own. The
    // formats' test compresses the archive twice.
    .timeLimit(.minutes(30))
)
struct RemovalAndExportIntegrationTests {
    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    static let stoppedByUnregister = "maw --unregister was run.\n"

    // MARK: Unregister

    /// A stopped distribution: nothing is printed, its directory and both of its logs are gone,
    /// the daemon's log records the removal, and the name is no longer installed.
    @Test func unregistersAStoppedDistributionWithItsLogs() async throws {
        try await maw.withDistribution("unregister-stopped") { name in
            // One boot, so that its own console log exists beside the installation's.
            let booted = try await maw.session(["-e", "true"], in: name)
            try #require(booted.status == 0, "\(booted.standardError)")
            try expectQuietSuccess(try await maw.run(["--terminate", name]))
            let logs = try logFiles(of: name)
            for log in logs.prefix(2) {
                try #require(exists(log), "\(log.path(percentEncoded: false)) does not exist.")
            }

            try expectQuietSuccess(try await maw.unregister(name))

            #expect(maw.traces(of: name).isEmpty, "\(maw.traces(of: name))")
            for log in logs {
                #expect(!exists(log), "\(log.path(percentEncoded: false)) was not deleted.")
            }
            #expect(!(try await maw.listedNames(["--list", "--quiet"]).contains(name)))
            let removal = try maw.daemonLogLines(since: "\(name): removal requested by process")
            #expect(
                removal.contains {
                    $0.contains("\(name): removed for process ")
                        && $0.contains("its machine was not running")
                }, "\(removal.joined(separator: "\n"))")

            let after = try await maw.session(["-e", "true"], in: name)
            #expect(after.status == 1)
            #expect(
                after.standardError
                    == "maw: No distribution named '\(name)' is installed.\n"
                    + "maw --list shows the installed distributions.\n",
                "\(after.standardError)")
        }
    }

    /// A running distribution: a shell on a terminal and a command without one end with
    /// `machineStopped` naming `maw --unregister`, the terminal is restored, and the removal
    /// is complete when maw exits.
    @Test func unregistersARunningDistributionAndEndsItsSessions() async throws {
        try await maw.withDistribution("unregister-running") { name in
            let host = maw.hostname(of: name)
            let shell = try maw.interactive(["-d", name])
            try #require(
                await shell.waitForPrompt(user: maw.user, host: host), "\(shell.plainOutput)")
            let command = try maw.start(["-d", name, "-e", "sleep", "100"])
            try await maw.waitForSessions(2, in: name)

            try expectQuietSuccess(try await maw.unregister(name))
            #expect(maw.traces(of: name).isEmpty, "\(maw.traces(of: name))")

            let ended =
                "maw: The session ended because the virtual machine \(name) stopped:\n"
                + Self.stoppedByUnregister
                + "\(name) was deleted; maw --list shows the installed distributions.\n"
            #expect(await shell.waitForExit(timeout: .seconds(30)) == 1, "\(shell.plainOutput)")
            #expect(
                shell.plainOutput.replacing("\r\n", with: "\n").contains(ended),
                "\(shell.plainOutput)")
            #expect(shell.terminalIsRestored, "The terminal attributes differ after the session.")
            let result = await command.waitForExit(timeout: .seconds(30))
            #expect(result.status == 1)
            #expect(result.standardError.contains(ended), "\(result.standardError)")

            for log in try logFiles(of: name) {
                #expect(!exists(log), "\(log.path(percentEncoded: false)) was not deleted.")
            }
            #expect(try await maw.machineRow(of: name) == "")
            let removal = try maw.daemonLogLines(since: "\(name): removal requested by process")
            #expect(
                removal.contains {
                    $0.contains("\(name): removed for process ")
                        && $0.contains("its machine was stopped and 2 sessions ended")
                }, "\(removal.joined(separator: "\n"))")
        }
    }

    /// The default: its removal names the new default on standard error, and the listing marks
    /// that one.
    @Test func unregistersTheDefaultAndNamesTheNewOne() async throws {
        try await maw.withStateFileRestored {
            try await maw.withDistribution("unregister-default") { name in
                try expectQuietSuccess(try await maw.run(["--set-default", name]))

                let result = try await maw.unregister(name)
                try #require(result.status == 0, "\(result.standardError)")
                #expect(result.output == "")
                let line = try #require(
                    result.standardError.wholeMatch(
                        of: #/(\S+) is now the default distribution\.\n/#),
                    "\(result.standardError)")
                let newDefault = String(line.1)
                #expect(newDefault != name)

                let listing = try await maw.run(["--list"])
                #expect(listing.lines.contains("  * \(newDefault)"), "\(listing.output)")
                #expect(!listing.output.contains(name), "\(listing.output)")
                let removal = try maw.daemonLogLines(
                    since: "\(name): removal requested by process")
                #expect(
                    removal.contains { $0.contains("; \(newDefault) is now the default") },
                    "\(removal.joined(separator: "\n"))")
            }
        }
    }

    /// The helper never runs `--unregister` for the shared test distribution, which the script
    /// installed, or for a name outside the run's prefix.
    @Test func theHelperRefusesNamesThisProcessDidNotCreate() async throws {
        for name in [maw.distribution, "Ubuntu-24.04", "\(maw.prefix)-never-installed"] {
            let refusal = MawIntegration.unregisterRefusal(
                of: name, prefix: maw.prefix, created: MawIntegration.created.all)
            #expect(refusal != nil, "\(name)")
        }
    }

    // MARK: Export

    /// The archive of a distribution keeps what a copy of it needs: owners and groups,
    /// permissions with the set-user-ID and sticky bits, extended attributes of each namespace,
    /// file capabilities as the image has them, hard links, symbolic links, a FIFO, and a file
    /// with a non-ASCII name. It is a complete pax archive of mode 600, and maw's last line
    /// names the file and its size.
    @Test func exportsTheRootFileSystemWithItsMetadata() async throws {
        try await maw.withDistribution("export-readback") { name in
            let fixtures = try await maw.session(
                ["-u", "root", "--", Self.fixtureScript], in: name)
            try #require(
                fixtures.status == 0 && fixtures.lines.contains("fixtures ready"),
                "\(fixtures.output)\(fixtures.standardError)")
            try expectQuietSuccess(try await maw.run(["--terminate", name]))

            try await maw.withExportDirectory { directory in
                let file = directory.appending(path: "readback.tar")
                let path = file.path(percentEncoded: false)
                let result = try await maw.run(["--export", name, path], timeout: .seconds(600))
                try #require(result.status == 0, "\(result.standardError)")
                #expect(result.output == "")
                let size = try fileSize(file)
                #expect(
                    result.lines(ofStandardError: true).last?.hasPrefix(
                        "\(name) was exported to \(path): ") == true, "\(result.standardError)")
                #expect(try permissions(of: file) == 0o600)
                #expect(size % 512 == 0)

                let entries = try await runOnDedicatedThread { () throws in
                    try PaxArchiveEntry.read(file)
                }
                try #require(entries.count > 10_000, "the archive has \(entries.count) entries")
                let byPath = Dictionary(entries.map { ($0.path, $0) }) { first, _ in first }
                try checkFixtures(byPath, in: file)
                try checkSystemFiles(byPath)
                try await checkImageMetadata(byPath)
            }
            let export = try maw.daemonLogLines(since: "\(name): export as tar started")
            #expect(
                export.contains { $0.contains("\(name): exported ") && $0.contains(" as tar in ") },
                "\(export.joined(separator: "\n"))")
        }
    }

    /// What the export keeps of POSIX ACLs. The guest's bsdtar is built without ACL support,
    /// and libarchive skips the kernel's ACL attributes, so neither form reaches the archive
    /// (docs/known-limitations.md). The ACLs are set with python3's `os.setxattr`, because the
    /// image has no `setfacl`, and read back with `os.getxattr` before the export, so that the
    /// test knows the kernel accepted them.
    @Test func recordsWhatAnExportKeepsOfPOSIXACLs() async throws {
        try await maw.withDistribution("export-acl") { name in
            let set = try await maw.session(["-u", "root", "--", Self.aclScript], in: name)
            try #require(
                set.status == 0 && set.lines.contains("acls accepted"),
                "\(set.output)\(set.standardError)")
            try expectQuietSuccess(try await maw.run(["--terminate", name]))

            try await maw.withExportDirectory { directory in
                let file = directory.appending(path: "acl.tar")
                let result = try await maw.run(
                    ["--export", name, file.path(percentEncoded: false)], timeout: .seconds(600))
                try #require(result.status == 0, "\(result.standardError)")
                let entries = try await runOnDedicatedThread { () throws in
                    try PaxArchiveEntry.read(file)
                }
                for path in ["srv/maw-acl/file", "srv/maw-acl/dir"] {
                    let entry = try #require(entries.first { $0.path == path }, "\(path)")
                    let keys = entry.aclRecordKeys
                    print(
                        "acl: \(path): "
                            + (keys.isEmpty ? "no ACL record" : keys.joined(separator: ", ")))
                    #expect(
                        keys.isEmpty,
                        "The export now keeps ACLs of \(path) (\(keys)); update docs/known-limitations.md."
                    )
                    // What does survive: the user attribute beside the ACL, and the mode, whose
                    // group bits the access ACL's mask set.
                    #expect(entry.extendedAttribute("user.maw") == Data("kept".utf8), "\(path)")
                }
                let aclFile = try #require(entries.first { $0.path == "srv/maw-acl/file" })
                #expect(aclFile.mode == 0o644, "\(String(aclFile.mode, radix: 8))")
            }
        }
    }

    /// The format follows the extension as `tar -a` does, and `--format` wins over it; each
    /// archive is read back by `/usr/bin/tar` with the same entries as the uncompressed one.
    @Test func exportsEachFormat() async throws {
        let name = maw.distribution
        try expectQuietSuccess(try await maw.run(["--terminate", name]))
        try await maw.withExportDirectory { directory in
            let plain = directory.appending(path: "plain.tar")
            let plainResult = try await maw.run(
                ["--export", name, plain.path(percentEncoded: false)], timeout: .seconds(600))
            try #require(plainResult.status == 0, "\(plainResult.standardError)")
            let names = try await listedNames(of: plain)
            try #require(names.count > 10_000)

            let cases: [(file: String, arguments: [String], magic: [UInt8], format: String)] = [
                ("by-extension.TGZ", [], [0x1F, 0x8B], "tar.gz"),
                (
                    "by-format.tar", ["--format", "tar.xz"], [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00],
                    "tar.xz"
                ),
            ]
            for (fileName, arguments, magic, format) in cases {
                let file = directory.appending(path: fileName)
                let result = try await maw.run(
                    ["--export", name, file.path(percentEncoded: false)] + arguments,
                    timeout: .seconds(1_200))
                try #require(result.status == 0, "\(fileName): \(result.standardError)")
                let handle = try FileHandle(forReadingFrom: file)
                let head = try handle.read(upToCount: magic.count)
                try handle.close()
                #expect(head.map(Array.init) == magic, "\(fileName)")
                #expect(try permissions(of: file) == 0o600, "\(fileName)")
                #expect(try await listedNames(of: file) == names, "\(fileName)")
                let started = try maw.daemonLogLines(since: "\(name): export as \(format) started")
                #expect(!started.isEmpty, "\(fileName): no export as \(format) in the log")
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    /// `maw --export <name> - | head -c 1`: the export fails with its message, the daemon keeps
    /// serving the same process, no machine is left, and the distribution can be exported again.
    @Test func failsAnExportWhoseReaderClosesThePipe() async throws {
        let name = maw.distribution
        try expectQuietSuccess(try await maw.run(["--terminate", name]))
        let daemon = try await maw.daemonProcessID()
        try await maw.withExportDirectory { directory in
            let errors = directory.appending(path: "stderr.txt")
            let status = directory.appending(path: "status.txt")
            let shell = try DebugBootProcess(
                executable: URL(filePath: "/bin/sh"),
                arguments: [
                    "-c", "{ \"$0\" --export \"$1\" - 2> \"$2\"; echo $? > \"$3\"; } | head -c 1",
                    maw.maw.path(percentEncoded: false), name, errors.path(percentEncoded: false),
                    status.path(percentEncoded: false),
                ], separateStandardError: true, environment: maw.mawEnvironment)
            let piped = await shell.waitForExit(timeout: .seconds(300))
            #expect(piped.status == 0, "\(piped.standardError)")
            #expect(piped.output.utf8.count == 1)
            let exitStatus = try String(contentsOf: status, encoding: .utf8)
            let standardError = try String(contentsOf: errors, encoding: .utf8)
            #expect(exitStatus == "1\n", "\(standardError)")
            #expect(
                standardError.hasSuffix(
                    "maw: The export of \(name) stopped, because the program that reads the\n"
                        + "archive closed its end of the pipe before the archive was complete.\n"
                        + "Run maw --export again with a reader that reads the whole archive.\n"),
                "\(standardError)")
        }
        #expect(try await maw.daemonProcessID() == daemon)
        let status = try await maw.run(["--status"])
        #expect(!status.output.contains(name), "\(status.output)")
        let failure = try maw.daemonLogLines(since: "\(name): export as tar started")
        #expect(
            failure.contains {
                $0.contains("\(name): export for process ") && $0.contains(" failed: ")
            },
            "\(failure.joined(separator: "\n"))")
        #expect(try await maw.run(["--list"]).status == 0)
    }

    /// Ctrl-C while the archive is written: maw asks the daemon to cancel, removes its file, and
    /// exits as the signal does; nothing is left, and the distribution still starts.
    @Test func cancelsAnExportOnCtrlCAndLeavesNothing() async throws {
        let name = maw.distribution
        try expectQuietSuccess(try await maw.run(["--terminate", name]))
        try await maw.withExportDirectory { directory in
            let file = directory.appending(path: "cancelled.tar")
            let export = try maw.start(["--export", name, file.path(percentEncoded: false)])
            let writing = await export.waitForLine(
                in: \.standardError, where: { $0.hasPrefix("Writing the archive") },
                timeout: .seconds(120))
            try #require(writing, "\(export.standardError)")
            // Some of the archive is written before the signal.
            try await Task.sleep(for: .milliseconds(500))
            export.signal(SIGINT)
            let result = await export.waitForExit(timeout: .seconds(30))
            #expect(result.status == 130, "\(result.standardError)")
            #expect(result.standardError.contains("Cancelling the export..."))
            #expect(
                result.standardError.contains("maw: The export of \(name) was cancelled."),
                "\(result.standardError)")
            #expect(!exists(file))
            #expect(
                try FileManager.default.contentsOfDirectory(
                    atPath: directory.path(percentEncoded: false)
                ).isEmpty)
        }
        let cancelled = try maw.daemonLogLines(since: "\(name): export as tar started")
        #expect(
            cancelled.contains {
                $0.contains("\(name): export for process ") && $0.hasSuffix(" cancelled")
            },
            "\(cancelled.joined(separator: "\n"))")
        let idle = await maw.eventually(within: .seconds(10)) {
            (try? await maw.run(["--status"]))?.output.contains(name) == false
        }
        #expect(idle, "A machine of \(name) is still listed after the cancellation.")
        let next = try await maw.session(["-e", "true"])
        #expect(next.status == 0, "\(next.standardError)")
    }

    /// A running distribution is refused with the suggestion to terminate it, and no file is
    /// created. While an export runs, a session, a second export, and `--unregister` of the
    /// same distribution fail with the operation's name, and the export still completes.
    @Test func refusesWhatAnExportExcludes() async throws {
        try await maw.withDistribution("export-busy") { name in
            try await maw.withExportDirectory { directory in
                let file = directory.appending(path: "busy.tar")
                let path = file.path(percentEncoded: false)

                let running = try maw.start(["-d", name, "-e", "sleep", "100"])
                try await maw.waitForSessions(1, in: name)
                let refused = try await maw.run(["--export", name, path])
                #expect(refused.status == 1)
                #expect(
                    refused.standardError
                        == "maw: \(name) is not stopped; only a stopped distribution can be "
                        + "exported.\nStop it with maw --terminate \(name), which ends its "
                        + "sessions and\nwaits for its stop, then run maw --export again.\n",
                    "\(refused.standardError)")
                #expect(!exists(file))
                try expectQuietSuccess(try await maw.run(["--terminate", name]))
                _ = await running.waitForExit(timeout: .seconds(30))

                let export = try maw.start(["--export", name, path])
                let writing = await export.waitForLine(
                    in: \.standardError, where: { $0.hasPrefix("Writing the archive") },
                    timeout: .seconds(120))
                try #require(writing, "\(export.standardError)")
                let busy =
                    "maw: \(name) is being exported by maw --export.\n"
                    + "Wait until maw --export has finished, then run the command again.\n"
                let session = try await maw.session(["-e", "true"], in: name)
                #expect(session.status == 1)
                #expect(session.standardError == busy, "\(session.standardError)")
                let second = directory.appending(path: "second.tar")
                let again = try await maw.run(
                    ["--export", name, second.path(percentEncoded: false)])
                #expect(again.status == 1)
                #expect(again.standardError == busy, "\(again.standardError)")
                #expect(!exists(second))
                let unregister = try await maw.unregister(name)
                #expect(unregister.status == 1)
                #expect(unregister.standardError == busy, "\(unregister.standardError)")

                let result = await export.waitForExit(timeout: .seconds(600))
                #expect(result.status == 0, "\(result.standardError)")
                #expect(try fileSize(file) > 0)
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: Fixtures

    /// Files whose metadata the archive must keep, created as root under /srv/maw-export.
    static let fixtureScript = """
        set -eu
        d=/srv/maw-export
        mkdir -p "$d/sticky"
        chmod 1777 "$d/sticky"
        printf 'owned\\n' > "$d/owned"
        chown 1234:2345 "$d/owned"
        chmod 640 "$d/owned"
        printf 'setuid\\n' > "$d/setuid"
        chmod 4755 "$d/setuid"
        printf 'linked\\n' > "$d/first"
        ln "$d/first" "$d/second"
        printf 'non-ASCII\\n' > "$d/\(nonASCIIName)"
        ln -s owned "$d/symlink"
        mkfifo "$d/fifo"
        printf 'xattr\\n' > "$d/xattr"
        python3 - <<'PYTHON'
        import os
        os.setxattr("/srv/maw-export/xattr", "user.maw", "çğı".encode())
        os.setxattr("/srv/maw-export/xattr", "trusted.maw", bytes([0, 1, 2, 255]))
        PYTHON
        sync
        echo 'fixtures ready'
        """

    static let nonASCIIName = "çğıöşü ÇĞİÖŞÜ.txt"

    /// An access ACL on a file and a default ACL on a directory, each granting user 1234, in
    /// the kernel's `posix_acl_xattr` encoding, and a user attribute beside each.
    static let aclScript = """
        set -eu
        mkdir -p /srv/maw-acl/dir
        printf 'acl\\n' > /srv/maw-acl/file
        chmod 600 /srv/maw-acl/file
        python3 - <<'PYTHON'
        import os, struct
        UNDEFINED = 0xFFFFFFFF
        def acl(entries):
            return struct.pack("<I", 2) + b"".join(struct.pack("<HHI", *e) for e in entries)
        # USER_OBJ, USER 1234, GROUP_OBJ, MASK, OTHER
        access = acl([(0x01, 6, UNDEFINED), (0x02, 4, 1234), (0x04, 4, UNDEFINED),
                      (0x10, 4, UNDEFINED), (0x20, 4, UNDEFINED)])
        default = acl([(0x01, 7, UNDEFINED), (0x02, 5, 1234), (0x04, 5, UNDEFINED),
                       (0x10, 5, UNDEFINED), (0x20, 5, UNDEFINED)])
        os.setxattr("/srv/maw-acl/file", "system.posix_acl_access", access)
        os.setxattr("/srv/maw-acl/dir", "system.posix_acl_default", default)
        assert os.getxattr("/srv/maw-acl/file", "system.posix_acl_access") == access
        assert os.getxattr("/srv/maw-acl/dir", "system.posix_acl_default") == default
        for path in ("/srv/maw-acl/file", "/srv/maw-acl/dir"):
            os.setxattr(path, "user.maw", b"kept")
        PYTHON
        sync
        echo 'acls accepted'
        """

    private func checkFixtures(_ entries: [String: PaxArchiveEntry], in archive: URL) throws {
        let d = "srv/maw-export"
        let owned = try #require(entries["\(d)/owned"])
        #expect(owned.isRegularFile && owned.uid == 1234 && owned.gid == 2345, "\(owned)")
        #expect(owned.mode == 0o640, "\(String(owned.mode, radix: 8))")
        #expect(try PaxArchiveEntry.contents(of: owned, in: archive) == Data("owned\n".utf8))
        #expect(entries["\(d)/setuid"]?.mode == 0o4755)
        let sticky = try #require(entries["\(d)/sticky"])
        #expect(sticky.isDirectory && sticky.mode == 0o1777, "\(sticky)")

        // One of the pair is the file, the other a hard link to it.
        let pair = [entries["\(d)/first"], entries["\(d)/second"]].compactMap { $0 }
        try #require(pair.count == 2)
        let link = try #require(pair.first { $0.isHardLink }, "\(pair)")
        let target = try #require(pair.first { $0.isRegularFile }, "\(pair)")
        #expect(link.linkPath.replacing(/^\.\//, with: "") == target.path, "\(link)")
        #expect(try PaxArchiveEntry.contents(of: target, in: archive) == Data("linked\n".utf8))

        let nonASCII = try #require(entries["\(d)/\(Self.nonASCIIName)"], "the non-ASCII name")
        #expect(try PaxArchiveEntry.contents(of: nonASCII, in: archive) == Data("non-ASCII\n".utf8))
        let symlink = try #require(entries["\(d)/symlink"])
        #expect(symlink.isSymbolicLink && symlink.linkPath == "owned", "\(symlink)")
        #expect(entries["\(d)/fifo"]?.isFIFO == true)
        let xattr = try #require(entries["\(d)/xattr"])
        #expect(xattr.extendedAttribute("user.maw") == Data("çğı".utf8), "\(xattr.records.keys)")
        #expect(
            xattr.extendedAttribute("trusted.maw") == Data([0, 1, 2, 255]), "\(xattr.records.keys)")
    }

    /// The root, `/etc/shadow` with its owner and its mode, and the default user's home.
    private func checkSystemFiles(_ entries: [String: PaxArchiveEntry]) throws {
        #expect(entries["."]?.isDirectory == true)
        let shadow = try #require(entries["etc/shadow"])
        #expect(shadow.uid == 0 && shadow.mode & 0o007 == 0, "\(shadow)")
        let home = try #require(entries["home/\(maw.user)"])
        #expect(home.isDirectory && home.uid >= 1000, "\(home)")
    }

    /// The image's file capabilities, byte for byte, and the owners of its files that belong to
    /// system users under `usr/`, which the installation does not rewrite, against the image
    /// itself.
    private func checkImageMetadata(_ entries: [String: PaxArchiveEntry]) async throws {
        let image = maw.imageCache.appending(
            path: DistributionIntegrationTests.catalog.image.cacheFileName)
        let imageEntries = try await runOnDedicatedThread { () throws in
            try PaxEntry.read(image: image)
        }
        let capabilities = imageEntries.filter { $0.capability != nil }
        try #require(!capabilities.isEmpty)
        for entry in capabilities {
            let path = entry.path.replacing(/^\.\//, with: "")
            #expect(
                entries[path]?.extendedAttribute("security.capability") == entry.capability,
                "\(path)")
        }
        let owned = imageEntries.filter {
            $0.isRegularFile && ($0.uid != 0 || $0.gid != 0)
                && $0.path.replacing(/^\.\//, with: "").hasPrefix("usr/")
        }
        try #require(!owned.isEmpty)
        for entry in owned {
            let exported = entries[entry.path.replacing(/^\.\//, with: "")]
            let owner = exported.map { "\($0.uid) \($0.gid)" } ?? "missing"
            #expect(owner == "\(entry.uid) \(entry.gid)", "\(entry.path)")
        }
    }

    // MARK: Helpers

    private func expectQuietSuccess(
        _ result: DebugBootProcess.Result, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        try #require(result.status == 0, "\(result.standardError)", sourceLocation: sourceLocation)
        #expect(result.output == "", sourceLocation: sourceLocation)
        #expect(result.standardError == "", sourceLocation: sourceLocation)
    }

    /// The distribution's console log, its installation's, and its exports', in the test
    /// daemon's log directory.
    private func logFiles(of name: String) throws -> [URL] {
        MawPaths.distributionLogFiles(for: try DistroName(name), in: maw.logDirectory)
    }

    private func exists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path(percentEncoded: false), &status) == 0
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false))
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false))
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// The entries' names that `/usr/bin/tar -t` lists, which detects the compression itself.
    private func listedNames(of archive: URL) async throws -> [String] {
        let list = try DebugBootProcess(
            executable: URL(filePath: "/usr/bin/tar"),
            arguments: ["-t", "-f", archive.path(percentEncoded: false)],
            separateStandardError: true)
        let result = await list.waitForExit(timeout: .seconds(900))
        try #require(result.status == 0, "\(result.standardError)")
        return result.lines.filter { !$0.isEmpty }
    }
}

extension DebugBootProcess.Result {
    /// The lines of standard output, or of standard error.
    func lines(ofStandardError: Bool) -> [String] {
        DebugBootProcess.lines(of: ofStandardError ? standardError : output).filter {
            !$0.isEmpty
        }
    }
}
