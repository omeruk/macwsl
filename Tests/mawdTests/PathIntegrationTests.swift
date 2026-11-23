import Darwin
import Foundation
import MawCore
import Testing

/// The working directory, the logind session of a login shell in a directory, and `mawpath`
/// (docs/decisions/0022-working-directory-and-logind.md), with the guest files that the Guest
/// workflow builds.
///
/// The test daemon shares the owner's real home directory. maw starts only in directories of
/// `MawIntegration.withMacDirectory`, under `~/Library/Caches/maw`, which each test removes
/// even on failure, and in `/tmp`; nothing writes, renames, or deletes anything else under
/// /mnt/mac.
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled,
        "Integration tests boot a real virtual machine; run scripts/integration-test.sh."),
    .serialized,
    .timeLimit(.minutes(20))
)
struct PathIntegrationTests {
    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    var linuxHome: String { "/home/\(maw.user)" }

    func run(_ arguments: [String]) async throws -> DebugBootProcess.Result {
        try await maw.run(["-d", maw.distribution] + arguments)
    }

    // MARK: Without --cd

    @Test func startsInTheLinuxPathOfTheCurrentDirectory() async throws {
        try await maw.withMacDirectory { mac, linux in
            // Joined as text: URL would write the name decomposed (NFD).
            let name = "My Projects ç"
            let named = mac.path(percentEncoded: false) + name
            try #require(mkdir(named, 0o755) == 0)
            for (directory, expected) in [
                (mac.path(percentEncoded: false), linux), (named, "\(linux)/\(name)"),
            ] {
                try await maw.inDirectory(directory) {
                    for arguments in [["--", "pwd"], ["pwd"], ["-e", "pwd"]] {
                        let result = try await run(arguments)
                        #expect(result.status == 0, "\(result.standardError)")
                        #expect(Array(result.output.utf8) == Array("\(expected)\n".utf8))
                        #expect(result.standardError.isEmpty, "\(result.standardError)")
                    }
                }
            }
        }
    }

    @Test func startsInTheLinuxHomeDirectoryOutsideTheMacHomeDirectory() async throws {
        try await maw.inDirectory("/tmp") {
            let result = try await run(["--", "pwd"])
            #expect(result.status == 0, "\(result.standardError)")
            #expect(result.output == "\(linuxHome)\n")
            // getcwd reports /tmp as /private/tmp.
            #expect(
                result.standardError
                    == "maw: /private/tmp is not shared with Linux; starting in the home directory.\n"
            )
        }
    }

    @Test func startsInTheLinuxHomeDirectoryWhenTheCurrentDirectoryIsGone() async throws {
        try await maw.withMacDirectory { mac, _ in
            let gone = mac.appending(path: "gone").path(percentEncoded: false)
            try #require(mkdir(gone, 0o755) == 0)
            try await maw.inDirectory(gone) {
                try #require(rmdir(gone) == 0)
                let result = try await run(["--", "pwd"])
                #expect(result.status == 0, "\(result.standardError)")
                #expect(result.output == "\(linuxHome)\n")
                #expect(
                    result.standardError
                        == "maw: the current directory no longer exists; starting in the home"
                        + " directory.\n")
            }
        }
    }

    /// A translated directory that the user cannot enter in the guest falls back, for a
    /// command and for a login shell; the same directory named with --cd fails. The directory
    /// has mode 700: the owner enters it on the Mac, and the guest holds a user other than the
    /// default user, the files' owner there, to its mode.
    @Test func fallsBackOnlyForTheDirectoryThatMawChose() async throws {
        let other = "mawit\(UUID().uuidString.prefix(6).lowercased())"
        let added = try await maw.run([
            "-d", maw.distribution, "-u", "root", "--cd", "/", "-e", "useradd", "-m", "-s",
            "/bin/bash", other,
        ])
        try #require(added.status == 0, "\(added.standardError)")
        try await maw.withMacDirectory { mac, linux in
            let locked = mac.path(percentEncoded: false) + "locked"
            try #require(mkdir(locked, 0o700) == 0)
            try await maw.inDirectory(locked) {
                let line =
                    "maw: \(linux)/locked cannot be entered (permission denied); starting"
                    + " in the home directory."
                let command = try await run(["-u", other, "--", "pwd"])
                #expect(command.status == 0, "\(command.standardError)")
                #expect(command.output == "/home/\(other)\n")
                #expect(command.standardError == line + "\n")

                let shell = try maw.interactive(["-d", maw.distribution, "-u", other])
                try #require(
                    await shell.waitForPrompt(
                        user: other, host: maw.hostname(of: maw.distribution)),
                    "\(shell.plainOutput)")
                #expect(shell.plainOutput.contains(line), "\(shell.plainOutput)")
                shell.type("echo cwd=$(pwd)\r")
                #expect(await shell.waitForOutput(containing: "cwd=/home/\(other)"))
                shell.type("exit\r")
                _ = await shell.waitForExit(timeout: .seconds(30))

                for arguments in [
                    ["-u", other, "--cd", "\(linux)/locked", "--", "pwd"],
                    ["-u", other, "--cd", locked, "--", "pwd"],
                ] {
                    let named = try await run(arguments)
                    #expect(named.status != 0)
                    #expect(named.output.isEmpty)
                    #expect(
                        named.standardError.contains(
                            "cannot change to the working directory \(linux)/locked"),
                        "\(named.standardError)")
                }
                let namedShell = try maw.interactive([
                    "-d", maw.distribution, "-u", other, "--cd", locked,
                ])
                #expect(await namedShell.waitForExit(timeout: .seconds(30)) != 0)
                #expect(
                    namedShell.plainOutput.contains("cannot change to the working directory"),
                    "\(namedShell.plainOutput)")
            }
        }
        _ = try await maw.run([
            "-d", maw.distribution, "-u", "root", "--cd", "/", "-e", "userdel", "-r", other,
        ])
    }

    /// The Mac refuses getcwd in a directory that the owner cannot read.
    @Test func startsInTheLinuxHomeDirectoryWhenTheCurrentDirectoryCannotBeRead() async throws {
        try await maw.withMacDirectory { mac, _ in
            let locked = mac.path(percentEncoded: false) + "unreadable"
            try #require(mkdir(locked, 0o755) == 0)
            try await maw.inDirectory(locked) {
                try #require(chmod(locked, 0) == 0)
                defer { _ = chmod(locked, 0o755) }
                let result = try await run(["--", "pwd"])
                #expect(result.output == "\(linuxHome)\n")
                #expect(
                    result.standardError
                        == "maw: the current directory cannot be read (Permission denied);"
                        + " starting in the home directory.\n")
            }
        }
    }

    // MARK: --cd

    @Test func readsEachFormOfCd() async throws {
        let directory = "maw-it-cd-\(UUID().uuidString.prefix(8))"
        #expect(try await run(["--cd", "~", "--", "mkdir", directory]).status == 0)
        try await maw.withMacDirectory { mac, linux in
            try await maw.inDirectory(mac.path(percentEncoded: false)) {
                let macHome = FileManager.default.homeDirectoryForCurrentUser
                    .path(percentEncoded: false)
                for (cd, expected) in [
                    ("~", linuxHome), ("~/\(directory)", "\(linuxHome)/\(directory)"),
                    ("/tmp", "/tmp"), (macHome, MacShare.linuxPath),
                    (mac.path(percentEncoded: false), linux), (".", linux),
                ] {
                    let result = try await run(["--cd", cd, "--", "pwd"])
                    #expect(result.status == 0, "\(cd): \(result.standardError)")
                    #expect(result.output == "\(expected)\n", "\(cd)")
                    #expect(result.standardError.isEmpty, "\(cd): \(result.standardError)")
                }
                let outside = try await run(["--cd", "/Volumes/USB", "--", "pwd"])
                #expect(outside.status != 0)
                #expect(
                    outside.standardError.contains("/Volumes/USB is not shared with Linux"),
                    "\(outside.standardError)")
            }
        }
        _ = try await run(["--cd", "~", "--", "rmdir", directory])
    }

    // MARK: The login shell

    /// A login shell in a working directory is a logind session, has XDG_RUNTIME_DIR, starts
    /// in that directory, and holds no descriptor of the agent's.
    @Test func registersALoginShellInADirectoryWithLogind() async throws {
        try await maw.withMacDirectory { mac, linux in
            try await maw.inDirectory(mac.path(percentEncoded: false)) {
                let shell = try maw.interactive(["-d", maw.distribution])
                try #require(
                    await shell.waitForPrompt(
                        user: maw.user, host: maw.hostname(of: maw.distribution)),
                    "\(shell.plainOutput)")
                // The listing runs without a command substitution, whose pipe the shell would
                // hold open while it runs.
                shell.type(
                    "echo \"cwd=$(pwd) runtime=$XDG_RUNTIME_DIR shell=$SHELL\";"
                        + " loginctl list-sessions --no-legend | awk '{ print $1 }'"
                        + " | grep -qx \"$XDG_SESSION_ID\" && echo listed=yes;"
                        + " echo fds\"=\"; ls -1 /proc/$$/fd; echo \"end\"of-fds\r")
                #expect(
                    await shell.waitForOutput(containing: "cwd=\(linux) runtime=/run/user/"),
                    "\(shell.plainOutput)")
                #expect(await shell.waitForOutput(containing: "shell=/bin/bash"))
                #expect(
                    await shell.waitForOutput(containing: "listed=yes"),
                    "loginctl does not list the session: \(shell.plainOutput)")
                #expect(
                    await shell.waitForOutput(containing: "endof-fds"), "\(shell.plainOutput)")
                let fds =
                    shell.plainOutput.components(separatedBy: "fds=").last?
                    .components(separatedBy: "endof-fds").first?
                    .split(whereSeparator: \.isWhitespace).map(String.init) ?? []
                #expect(Set(fds).isSubset(of: ["0", "1", "2", "255"]), "\(fds)")
                shell.type("exit\r")
                _ = await shell.waitForExit(timeout: .seconds(30))
            }
        }
    }

    @Test func passesNoDescriptorOfTheAgentsToACommand() async throws {
        try await maw.withMacDirectory { mac, _ in
            try await maw.inDirectory(mac.path(percentEncoded: false)) {
                let result = try await run(["-e", "sh", "-c", "ls /proc/$$/fd"])
                #expect(result.status == 0, "\(result.standardError)")
                #expect(
                    result.lines.filter { !$0.isEmpty }.sorted() == ["0", "1", "2"],
                    "\(result.output)")
            }
        }
    }

    // MARK: mawpath

    @Test func translatesWithMawpathInsideASession() async throws {
        try await maw.withMacDirectory { mac, linux in
            let macPath = mac.path(percentEncoded: false).replacing(/\/$/, with: "")
            try await maw.inDirectory(mac.path(percentEncoded: false)) {
                let link = try await run(["-e", "readlink", "/usr/local/bin/mawpath"])
                #expect(link.output == "/run/maw/maw-agent\n", "\(link.standardError)")
                for prefix in [["--"], [], ["-e"]] {
                    let toMac = try await run(prefix + ["mawpath", "-a", "-m", "."])
                    #expect(toMac.status == 0, "\(prefix): \(toMac.standardError)")
                    #expect(toMac.output == "\(macPath)\n", "\(prefix)")
                    let toLinux = try await run(prefix + ["mawpath", macPath])
                    #expect(toLinux.output == "\(linux)\n", "\(prefix): \(toLinux.standardError)")
                }
                let outside = try await run(["-e", "mawpath", "-m", "/etc"])
                #expect(outside.status == 1)
                #expect(outside.standardError.hasPrefix("mawpath: /etc is not under /mnt/mac"))

                let shell = try maw.interactive(["-d", maw.distribution])
                try #require(
                    await shell.waitForPrompt(
                        user: maw.user, host: maw.hostname(of: maw.distribution)))
                shell.type(
                    "echo \"found=$(command -v mawpath)\"; echo \"mac=$(mawpath -a -m .)\"\r")
                #expect(
                    await shell.waitForOutput(containing: "found=/usr/local/bin/mawpath"),
                    "\(shell.plainOutput)")
                #expect(
                    await shell.waitForOutput(containing: "mac=\(macPath)"), "\(shell.plainOutput)")
                shell.type("exit\r")
                _ = await shell.waitForExit(timeout: .seconds(30))
            }
        }
    }

    // MARK: maw --

    @Test func keepsArgumentsIntactAsTheReadmeSays() async throws {
        let joined = try await run(["-e", "sh", "-c", "echo a; echo b"])
        #expect(joined.output == "a\nb\n")
        let quoted = try await run(["--", "echo a; echo b"])
        #expect(quoted.output == "a\nb\n")
    }
}
