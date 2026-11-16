import Darwin
import Foundation
import MawCore
import MawProtocol
import Testing

/// `maw --import` against the test daemon.
///
/// The test daemon shares the owner's distributions directory and `state.json`. Every name
/// imported here is under `MAW_TEST_PREFIX` and recorded as one this process created
/// (`MawIntegration.willCreate`), and every removal goes through `MawIntegration.remove`, which
/// refuses any other name. Archives go only into `MAW_TEST_EXPORT_DIRECTORY`, in the run's
/// temporary directory, and each test deletes its own when it ends, also when it fails.
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled,
        "Integration tests boot a real virtual machine; run scripts/integration-test.sh."),
    .serialized,
    .timeLimit(.minutes(30))
)
struct ImportIntegrationTests {
    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    // MARK: An export and an import

    /// An export imported under a new name boots, and its disk keeps the owners, modes,
    /// modification times, extended attributes, file capabilities, hard links, FIFO, and
    /// non-ASCII name of the source's; it keeps the default user, and has a host name, a MAC
    /// address, and a machine ID of its own, and an address of its own while both run.
    @Test func importsAnExportUnderANewNameWithItsMetadata() async throws {
        try await maw.withDistribution("import-source") { source in
            try await requireSuccess(
                maw.session(
                    ["-u", "root", "--", RemovalAndExportIntegrationTests.fixtureScript],
                    in: source))
            let expected = try await probe(source)
            let sourceMachineID = try await machineID(of: source)
            try await maw.withExportDirectory { directory in
                let file = try await export(source, to: directory.appending(path: "source.tar"))
                try await maw.withImported("import-copy", from: file) { copy, result in
                    #expect(
                        result.output
                            == "\n\(copy) is imported.\nRun maw -d \(copy) to open a shell as "
                            + "\(maw.user).\n", "\(result.output)")
                    #expect(try await probe(copy) == expected)

                    let user = try await maw.session(["-e", "id", "-un"], in: copy)
                    #expect(textLines(user) == [maw.user], "\(user.standardError)")
                    let host = try await maw.session(["-e", "hostname"], in: copy)
                    #expect(textLines(host) == [maw.hostname(of: copy)])
                    let copyMachineID = try await machineID(of: copy)
                    #expect(copyMachineID != sourceMachineID)
                    #expect(copyMachineID.wholeMatch(of: /[0-9a-f]{32}/) != nil, "\(copyMachineID)")

                    let sourceMetadata = try metadata(of: source)
                    let copyMetadata = try metadata(of: copy)
                    #expect(copyMetadata.macAddress != sourceMetadata.macAddress)
                    #expect(copyMetadata.schemaVersion == 2)
                    #expect(copyMetadata.catalogEntry == nil)
                    #expect(copyMetadata.defaultUser == maw.user)
                    #expect(copyMetadata.importedFrom?.archive == realPath(file))

                    let sourceAddress = try await address(of: source)
                    let copyAddress = try await address(of: copy)
                    #expect(sourceAddress != copyAddress, "both have \(sourceAddress)")
                    print("import: \(source) has \(sourceAddress), \(copy) has \(copyAddress)")

                    let imported = try maw.daemonLogLines(since: "\(copy): import started")
                    #expect(
                        imported.contains { $0.contains("\(copy): imported ") },
                        "\(imported.joined(separator: "\n"))")
                }
            }
        }
    }

    /// `-u` with a user that the archive has makes it the default user; with one that the
    /// archive lacks, the import fails before the registration and leaves nothing.
    @Test func importsWithTheUserOfTheOptionAndRefusesOneTheArchiveLacks() async throws {
        try await maw.withExportDirectory { directory in
            let file = try await export(
                maw.distribution, to: directory.appending(path: "shared.tar"))
            try await maw.withImported("import-root", from: file, user: "root") { copy, result in
                #expect(
                    result.output.hasSuffix("Run maw -d \(copy) to open a shell as root.\n"),
                    "\(result.output)")
                #expect(!result.output.contains("The archive names no other default user"))
                let user = try await maw.session(["-e", "id", "-un"], in: copy)
                #expect(textLines(user) == ["root"])
            }

            let missing = "\(maw.prefix)-import-missing-user"
            let refused = try await maw.importArchive(missing, from: file, user: "nosuchuser")
            #expect(refused.status == 1)
            #expect(
                refused.standardError.hasSuffix(
                    "maw: There is no user named 'nosuchuser' in the archive.\n"
                        + "Check the name. In a distribution, sudo adduser creates a user. For\n"
                        + "maw --import, -u must name a user in the archive's /etc/passwd.\n"),
                "\(refused.standardError)")
            try expectNothingLeft(of: missing)
        }
    }

    /// `maw --export <name> - | maw --import <copy> -` copies a distribution through a pipe.
    @Test func copiesADistributionThroughAPipe() async throws {
        let source = maw.distribution
        try await requireSuccess(maw.run(["--terminate", source]))
        let copy = "\(maw.prefix)-import-pipe"
        try maw.willCreate(copy)
        let shell = try DebugBootProcess(
            executable: URL(filePath: "/bin/sh"),
            arguments: [
                "-c", "\"$0\" --export \"$1\" - | \"$0\" --import \"$2\" -",
                maw.maw.path(percentEncoded: false), source, copy,
            ], separateStandardError: true, environment: maw.mawEnvironment)
        let piped = await shell.waitForExit(timeout: .seconds(900))
        do {
            try #require(piped.status == 0, "\(piped.output)\(piped.standardError)")
            #expect(piped.output.contains("\(copy) is imported."), "\(piped.output)")
            let user = try await maw.session(["-e", "id", "-un"], in: copy)
            #expect(textLines(user) == [maw.user])
            #expect(try metadata(of: copy).importedFrom?.archive == "standard input")
        } catch {
            try? await maw.remove(copy)
            throw error
        }
        try await maw.remove(copy)
    }

    // MARK: Refusals

    /// An archive whose `/sbin/init` is not systemd, an mtree archive that names a file of the
    /// Mac, one whose root is under one directory, and a truncated one: each is refused before
    /// the registration, and nothing is left.
    @Test func refusesArchivesThatAreNotARootFileSystemWithSystemd() async throws {
        try await maw.withExportDirectory { directory in
            let cases: [(suffix: String, archive: Data, error: (String) -> String)] = [
                (
                    "import-busybox", TarWriter.minimalRoot().finished(),
                    { name in
                        "maw: \(name) cannot be imported, because its /sbin/init is not "
                            + "systemd:\n/sbin/init leads to /usr/bin/busybox.\n"
                            + "Nothing was installed. maw starts every distribution with systemd.\n"
                    }
                ),
                (
                    // An mtree archive names files of the Mac, which /usr/bin/tar would read.
                    "import-mtree",
                    Data("#mtree\n./etc/passwd type=file contents=/etc/hosts\n".utf8),
                    { name in
                        "maw: The archive for \(name) is not a tar archive.\n"
                            + "Nothing was installed. maw --import reads tar archives, "
                            + "uncompressed or\ncompressed with gzip, bzip2, xz, or lzip, as "
                            + "maw --export and wsl --export\nwrite them.\n"
                    }
                ),
                (
                    "import-one-directory", TarWriter.underOneDirectory().finished(),
                    { name in
                        "maw: The archive for \(name) holds no root file system at its top "
                            + "level:\nits top level holds only the directory rootfs/.\n"
                            + "Nothing was installed. maw --import needs etc/passwd and usr/ at "
                            + "the archive's\ntop level, as maw --export and wsl --export write "
                            + "them.\n"
                    }
                ),
            ]
            for (suffix, archive, error) in cases {
                let name = "\(maw.prefix)-\(suffix)"
                let file = directory.appending(path: "\(suffix).tar")
                try archive.write(to: file)
                let result = try await maw.importArchive(
                    name, from: file.path(percentEncoded: false))
                #expect(result.status == 1, "\(suffix)")
                #expect(result.standardError.hasSuffix(error(name)), "\(result.standardError)")
                try expectNothingLeft(of: name)
            }

            let name = "\(maw.prefix)-import-truncated"
            let file = directory.appending(path: "truncated.tar")
            let whole = TarWriter.minimalRoot(withFileOf: 4 << 20).finished()
            try whole.prefix(whole.count / 2).write(to: file)
            let result = try await maw.importArchive(name, from: file.path(percentEncoded: false))
            #expect(result.status == 1)
            #expect(
                result.standardError.contains(
                    "maw: The import of \(name) failed while extracting the root file system:"),
                "\(result.standardError)")
            print("import: a truncated archive: \(result.standardError)")
            try expectNothingLeft(of: name)
        }
    }

    /// An archive with an absolute path, a `..` entry, and a file under a link to `/tmp`: the
    /// guest's bsdtar runs without `-P`, so the entries are stripped or refused. The import fails
    /// cleanly and leaves nothing; what each program said is printed for the record.
    @Test func refusesEntriesThatWouldLeaveTheRoot() async throws {
        try await maw.withExportDirectory { directory in
            let name = "\(maw.prefix)-import-hostile"
            let file = directory.appending(path: "hostile.tar")
            var archive = TarWriter.minimalRoot()
            archive.add("/maw-escape-absolute", contents: Data("absolute\n".utf8))
            archive.add("../maw-escape-dotdot", contents: Data("dotdot\n".utf8))
            archive.add("maw-link", type: .symbolicLink, link: "/tmp")
            archive.add("maw-link/maw-escape-through-link", contents: Data("link\n".utf8))
            try archive.finished().write(to: file)
            let result = try await maw.importArchive(name, from: file.path(percentEncoded: false))
            print("import: a hostile archive: status \(result.status): \(result.standardError)")
            #expect(result.status == 1)
            try expectNothingLeft(of: name)
        }
    }

    /// An absolute path added to a bootable archive: the import strips its leading `/` and
    /// succeeds, with the file inside the new root file system, or fails cleanly. A `..` entry
    /// makes the guest's bsdtar fail the extraction, which `refusesEntriesThatWouldLeaveTheRoot`
    /// shows.
    @Test func keepsAnAbsolutePathInsideTheRoot() async throws {
        try await maw.withExportDirectory { directory in
            let exported = try await export(
                maw.distribution, to: directory.appending(path: "shared.tar"))
            let extra = directory.appending(path: "extra.tar")
            var archive = TarWriter()
            archive.add("/maw-escape-absolute", contents: Data("absolute\n".utf8))
            try archive.finished().write(to: extra)
            // -P keeps the name as it is, so that the import sees it.
            let combined = directory.appending(path: "combined.tar")
            let tar = try DebugBootProcess(
                executable: URL(filePath: "/usr/bin/tar"),
                arguments: [
                    "-c", "-P", "--format", "pax", "-f", combined.path(percentEncoded: false),
                    "@" + exported, "@" + extra.path(percentEncoded: false),
                ], separateStandardError: true)
            let made = await tar.waitForExit(timeout: .seconds(600))
            try #require(made.status == 0, "\(made.standardError)")
            try FileManager.default.removeItem(atPath: exported)

            let name = "\(maw.prefix)-import-absolute"
            let result = try await maw.importArchive(
                name, from: combined.path(percentEncoded: false))
            print("import: an absolute path: status \(result.status): \(result.standardError)")
            if result.status == 0 {
                let found = try await maw.session(
                    ["-u", "root", "--", "ls -d /maw-escape-absolute; cat /maw-escape-absolute"],
                    in: name)
                #expect(
                    found.output == "/maw-escape-absolute\nabsolute\n",
                    "\(found.output)\(found.standardError)")
                try await maw.remove(name)
            } else {
                try expectNothingLeft(of: name)
            }
        }
    }

    // MARK: The default user and an archive from WSL

    /// An archive shaped as WSL leaves a distribution: `/etc/resolv.conf` a link to
    /// `/mnt/wsl/resolv.conf`, a drvfs line in `/etc/fstab`, a machine ID, no `/etc/maw.conf`,
    /// and `/etc/wsl.conf` with `[boot] systemd=true` and the default user. The import boots,
    /// its sessions run as that user, and the import replaced what WSL wrote. Without
    /// `/etc/wsl.conf` too, sessions run as root, and maw says how to choose another user.
    @Test func importsAnArchiveShapedAsWSLLeavesIt() async throws {
        try await maw.withDistribution("import-wsl") { source in
            let shape = """
                set -eu
                rm -f /etc/resolv.conf
                ln -s /mnt/wsl/resolv.conf /etc/resolv.conf
                printf 'C: /mnt/c drvfs defaults 0 0\\n' >> /etc/fstab
                rm -f /etc/maw.conf
                printf '[boot]\\nsystemd=true\\n[user]\\ndefault=\(maw.user)\\n' > /etc/wsl.conf
                test -s /etc/machine-id
                echo shaped
                """
            try await requireSuccess(
                maw.session(["-u", "root", "--", shape], in: source))
            let sourceMachineID = try await machineID(of: source)
            try await maw.withExportDirectory { directory in
                let file = try await export(source, to: directory.appending(path: "wsl.tar"))
                try await maw.withImported("import-wsl-copy", from: file) { copy, result in
                    #expect(
                        result.output.hasSuffix("open a shell as \(maw.user).\n"),
                        "\(result.output)")
                    let user = try await maw.session(["-e", "id", "-un"], in: copy)
                    #expect(textLines(user) == [maw.user], "\(user.standardError)")
                    let files = try await maw.session(
                        [
                            "-u", "root", "--",
                            "readlink /etc/resolv.conf; hostname; cat /etc/fstab; "
                                + "sed -n '/^\\[user\\]/,$p' /etc/maw.conf",
                        ], in: copy)
                    #expect(
                        textLines(files) == [
                            "../run/systemd/resolve/stub-resolv.conf", maw.hostname(of: copy),
                            "LABEL=maw-root\t/\text4\tdefaults\t0\t0", "[user]",
                            "default = \(maw.user)",
                        ], "\(files.output)\(files.standardError)")
                    let copyMachineID = try await machineID(of: copy)
                    #expect(copyMachineID != sourceMachineID)
                    #expect(!copyMachineID.isEmpty)
                }

                try await requireSuccess(
                    maw.session(["-u", "root", "--", "rm -f /etc/wsl.conf"], in: source))
                let bare = try await export(source, to: directory.appending(path: "bare.tar"))
                try await maw.withImported("import-root-only", from: bare) { copy, result in
                    #expect(
                        result.output.hasSuffix(
                            "Run maw -d \(copy) to open a shell as root.\n"
                                + "The archive names no other default user. To choose one, run\n"
                                + "maw --unregister \(copy), then maw --import \(copy) <file> "
                                + "-u <user>.\n"), "\(result.output)")
                    let user = try await maw.session(["-e", "id", "-un"], in: copy)
                    #expect(textLines(user) == ["root"])
                }
            }
        }
    }

    /// Without netplan, systemd-networkd gets maw's configuration: the virtual device gets an
    /// address by DHCP, the default gateway answers (a ping, or else its neighbour entry), and
    /// systemd-resolved has a DNS server. Nothing here needs the internet.
    @Test func configuresTheNetworkWithoutNetplan() async throws {
        try await maw.withDistribution("import-networkd") { source in
            try await requireSuccess(
                maw.session(
                    [
                        "-u", "root", "--",
                        "rm -f /usr/lib/systemd/system-generators/netplan /usr/sbin/netplan "
                            + "&& rm -rf /etc/netplan && echo removed",
                    ], in: source))
            try await maw.withExportDirectory { directory in
                let file = try await export(source, to: directory.appending(path: "networkd.tar"))
                try await maw.withImported("import-networkd-copy", from: file) { copy, _ in
                    let network = try await maw.session(
                        ["-u", "root", "--", Self.networkScript], in: copy)
                    print("import: network without netplan:\n\(network.output)")
                    let lines = network.lines
                    #expect(lines.contains("fallback configuration present"), "\(network.output)")
                    #expect(
                        lines.contains { $0.hasPrefix("address ") && $0.contains("inet ") },
                        "\(network.output)")
                    let gateway = lines.first { $0.hasPrefix("gateway ") }
                    #expect(gateway != nil && gateway != "gateway ", "\(network.output)")
                    #expect(
                        lines.contains("gateway answered ping")
                            || lines.contains {
                                $0.hasPrefix("neighbour ")
                                    && ($0.contains("REACHABLE") || $0.contains("STALE"))
                            }, "\(network.output)")
                    #expect(
                        lines.contains {
                            $0.hasPrefix("dns ") && $0.contains(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)
                        }, "\(network.output)")
                }
            }
        }
    }

    /// Ctrl-C while the archive is extracted: maw asks the daemon to cancel and exits as the
    /// signal does, and nothing of the import is left.
    @Test func cancelsAnImportOnCtrlCAndLeavesNothing() async throws {
        try await maw.withExportDirectory { directory in
            let file = try await export(
                maw.distribution, to: directory.appending(path: "shared.tar"))
            let name = "\(maw.prefix)-import-cancelled"
            let running = try maw.startImport(name, from: file)
            let extracting = await running.waitForLine(
                in: \.standardError, where: { $0.hasPrefix("Extracting the archive") },
                timeout: .seconds(120))
            try #require(extracting, "\(running.standardError)")
            try await Task.sleep(for: .milliseconds(500))
            running.signal(SIGINT)
            let result = await running.waitForExit(timeout: .seconds(30))
            #expect(result.status == 130, "\(result.standardError)")
            #expect(result.standardError.contains("Cancelling the import..."))
            #expect(
                result.standardError.contains("maw: The import of \(name) was cancelled."),
                "\(result.standardError)")
            try expectNothingLeft(of: name)
            let cancelled = try maw.daemonLogLines(since: "\(name): import started")
            #expect(
                cancelled.contains {
                    $0.contains("\(name): import for process ") && $0.contains(" cancelled")
                }, "\(cancelled.joined(separator: "\n"))")
        }
    }

    // MARK: Helpers

    /// Exports the stopped `name` to `file` and returns the file's path.
    func export(_ name: String, to file: URL) async throws -> String {
        try await requireSuccess(maw.run(["--terminate", name]))
        let path = file.path(percentEncoded: false)
        let result = try await maw.run(["--export", name, path], timeout: .seconds(600))
        try #require(result.status == 0, "\(result.standardError)")
        return path
    }

    /// The output's lines without the empty one after the last line break.
    func textLines(_ result: DebugBootProcess.Result) -> [String] {
        result.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.isEmpty }
    }

    func requireSuccess(
        _ result: DebugBootProcess.Result, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        try #require(
            result.status == 0, "\(result.output)\(result.standardError)",
            sourceLocation: sourceLocation)
    }

    /// Nothing of a refused import is left: no distribution, no staging directory, and no
    /// entry in the listing.
    func expectNothingLeft(
        of name: String, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        #expect(
            maw.traces(of: name).isEmpty, "\(maw.traces(of: name))", sourceLocation: sourceLocation)
        let directory = maw.paths.distroDirectory(for: try DistroName(name))
        #expect(
            !FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)),
            sourceLocation: sourceLocation)
    }

    func metadata(of name: String) throws -> DistroMetadata {
        try DistroMetadata.decode(
            Data(contentsOf: maw.paths.metadataFile(for: try DistroName(name))))
    }

    func machineID(of name: String) async throws -> String {
        let result = try await maw.session(["-e", "cat", "/etc/machine-id"], in: name)
        try #require(result.status == 0, "\(result.standardError)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The IPv4 address of the distribution's network device, once it has one.
    func address(of name: String) async throws -> String {
        let result = try await maw.session(
            [
                "--",
                "for i in $(seq 100); do a=$(ip -4 -o addr show scope global | awk '{print $4}');"
                    + " [ -n \"$a\" ] && { echo \"$a\"; exit 0; }; sleep 0.1; done; exit 1",
            ], in: name)
        try #require(result.status == 0, "\(result.output)\(result.standardError)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func realPath(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(validatingCString: real)
    }

    /// The metadata of the fixtures and of the image's files that the copy must keep, printed
    /// in an order and form that do not depend on the disk: names as bytes, owners, modes,
    /// types, link counts, modification times, sizes, link targets, extended attributes, which
    /// names share an inode, and every file capability and every file not owned by root
    /// under `/usr`.
    func probe(_ name: String) async throws -> [String] {
        let result = try await maw.session(["-u", "root", "--", Self.probeScript], in: name)
        try #require(result.status == 0, "\(result.output)\(result.standardError)")
        try #require(result.lines.contains("probe done"), "\(result.output)")
        try #require(result.lines.count > 20, "\(result.output)")
        return result.lines
    }

    static let probeScript = #"""
        python3 - <<'PYTHON'
        import os, stat
        def describe(path):
            st = os.lstat(path)
            kind = stat.S_IFMT(st.st_mode)
            line = "%s %d:%d %o %o %d %d %d" % (
                os.fsencode(path).hex(), st.st_uid, st.st_gid, stat.S_IMODE(st.st_mode), kind,
                st.st_nlink, int(st.st_mtime), st.st_size if stat.S_ISREG(st.st_mode) else 0)
            if stat.S_ISLNK(st.st_mode):
                line += " -> " + os.fsencode(os.readlink(path)).hex()
            for key in sorted(os.listxattr(path, follow_symlinks=False)):
                value = os.getxattr(path, key, follow_symlinks=False)
                line += " %s=%s" % (key, value.hex())
            return st, line
        inodes = {}
        for entry in sorted(os.listdir(b"/srv/maw-export")):
            path = os.path.join(b"/srv/maw-export", entry)
            st, line = describe(path)
            print("fixture " + line)
            inodes.setdefault(st.st_ino, []).append(entry.hex())
        for names in sorted(inodes.values()):
            if len(names) > 1:
                print("same inode " + " ".join(sorted(names)))
        for top, dirs, files in os.walk("/usr"):
            dirs.sort()
            for name in sorted(dirs + files):
                path = os.path.join(top, name)
                st = os.lstat(path)
                if st.st_uid != 0 or st.st_gid != 0:
                    print("owned %s %d:%d" % (path, st.st_uid, st.st_gid))
                if stat.S_ISREG(st.st_mode):
                    try:
                        capability = os.getxattr(path, "security.capability", follow_symlinks=False)
                        print("capability %s %s" % (path, capability.hex()))
                    except OSError:
                        pass
        print("probe done")
        PYTHON
        """#

    /// What systemd-networkd and systemd-resolved made of the network, with the check that the
    /// gateway answers: a ping, or else its neighbour entry after the attempt.
    static let networkScript = #"""
        test -f /etc/systemd/network/50-maw.network && echo "fallback configuration present"
        for i in $(seq 150); do
            ip -4 -o addr show scope global | grep -q inet && break
            sleep 0.1
        done
        ip -4 -o addr show scope global | sed 's/^/address /'
        gateway=$(ip route show default | awk '{ print $3; exit }')
        echo "gateway $gateway"
        if [ -n "$gateway" ] && ping -c 1 -W 2 "$gateway" > /dev/null 2>&1; then
            echo "gateway answered ping"
        else
            echo "gateway did not answer ping"
            ip neigh show "$gateway" | sed 's/^/neighbour /'
        fi
        for i in $(seq 50); do
            resolvectl dns 2> /dev/null | grep -q '[0-9]' && break
            sleep 0.1
        done
        resolvectl dns 2> /dev/null | grep '[0-9]' | sed 's/^/dns /'
        """#
}

/// A tar archive written byte by byte, so that its names are exactly as given, including an
/// absolute path or `..`, which `/usr/bin/tar` would strip when it creates an archive.
struct TarWriter {
    enum EntryType: UInt8 {
        case file = 0x30
        case symbolicLink = 0x32
        case directory = 0x35
    }

    private(set) var data = Data()

    mutating func add(
        _ name: String, type: EntryType = .file, mode: Int = 0o644, contents: Data = Data(),
        link: String = ""
    ) {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int, length: Int) {
            let bytes = Array(text.utf8.prefix(length))
            header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        func octal(_ value: Int, at offset: Int, length: Int) {
            put(String(format: "%0\(length - 1)o", value), at: offset, length: length - 1)
        }
        put(name, at: 0, length: 100)
        octal(type == .directory ? 0o755 : mode, at: 100, length: 8)
        octal(0, at: 108, length: 8)
        octal(0, at: 116, length: 8)
        octal(type == .file ? contents.count : 0, at: 124, length: 12)
        octal(1_700_000_000, at: 136, length: 12)
        header[156] = type.rawValue
        put(link, at: 157, length: 100)
        put("ustar", at: 257, length: 6)
        put("00", at: 263, length: 2)
        put("root", at: 265, length: 32)
        put("root", at: 297, length: 32)
        // The checksum is computed with its own field as spaces.
        header.replaceSubrange(148..<156, with: [UInt8](repeating: 0x20, count: 8))
        let sum = header.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", sum), at: 148, length: 6)
        header[154] = 0
        header[155] = 0x20
        data.append(contentsOf: header)
        if type == .file {
            data.append(contents)
            let padding = (512 - contents.count % 512) % 512
            data.append(contentsOf: [UInt8](repeating: 0, count: padding))
        }
    }

    /// The archive with its end: two blocks of zeros.
    func finished() -> Data {
        data + Data(count: 1_024)
    }

    /// A root file system that passes the check of its top level, with `/sbin/init` leading to
    /// busybox, and, if `size` is given, a file of that many random bytes.
    static func minimalRoot(withFileOf size: Int? = nil) -> TarWriter {
        var archive = TarWriter()
        archive.add("etc/", type: .directory)
        archive.add("etc/passwd", contents: Data("root:x:0:0:root:/root:/bin/sh\n".utf8))
        archive.add("usr/", type: .directory)
        archive.add("usr/bin/", type: .directory)
        archive.add("usr/bin/busybox", mode: 0o755, contents: Data("#!/bin/sh\n".utf8))
        archive.add("usr/bin/init", type: .symbolicLink, link: "busybox")
        archive.add("sbin", type: .symbolicLink, link: "usr/bin")
        if let size {
            var bytes = [UInt8](repeating: 0, count: size)
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: 0...255)
            }
            archive.add("usr/bin/large", contents: Data(bytes))
        }
        return archive
    }

    /// A root file system whose files are all under `rootfs/`.
    static func underOneDirectory() -> TarWriter {
        var archive = TarWriter()
        archive.add("rootfs/", type: .directory)
        archive.add("rootfs/etc/", type: .directory)
        archive.add("rootfs/etc/passwd", contents: Data("root:x:0:0:root:/root:/bin/sh\n".utf8))
        archive.add("rootfs/usr/", type: .directory)
        return archive
    }
}
