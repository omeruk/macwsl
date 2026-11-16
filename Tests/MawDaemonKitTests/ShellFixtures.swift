import Foundation
import MawTestSupport
import Testing

/// Runs the scripts that the provisioning machine runs with the Mac's `/bin/sh`, against a root
/// file system made of files in a temporary directory. They use only POSIX shell and commands
/// that both busybox and macOS have; the integration tests run them in the guest.
struct ShellRun {
    var status: Int32
    var output: String

    /// Runs `script` as `sh <script> <arguments...>` with `input` on standard input, and
    /// returns its exit status and its standard output and error together.
    static func run(_ script: String, _ arguments: [String], input: String = "") async throws
        -> ShellRun
    {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "maw-shell-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptFile = directory.appending(path: "script.sh")
        let inputFile = directory.appending(path: "input")
        let outputFile = directory.appending(path: "output")
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        try input.write(to: inputFile, atomically: true, encoding: .utf8)
        FileManager.default.createFile(
            atPath: outputFile.path(percentEncoded: false), contents: nil)

        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = [scriptFile.path(percentEncoded: false)] + arguments
        shell.standardInput = try FileHandle(forReadingFrom: inputFile)
        let output = try FileHandle(forWritingTo: outputFile)
        shell.standardOutput = output
        shell.standardError = output
        try shell.run()
        try #require(await shell.waitForExit(within: .seconds(30)))
        try output.close()
        return ShellRun(
            status: shell.terminationStatus,
            output: try String(contentsOf: outputFile, encoding: .utf8))
    }
}

/// A temporary directory that holds a root file system, `root`, and next to it a directory
/// `outside`, so that a test can show that nothing outside the root was written.
final class FakeRoot {
    let base: URL
    let root: URL
    let outside: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(
            path: "maw-root-\(UUID().uuidString)", directoryHint: .isDirectory)
        root = base.appending(path: "root", directoryHint: .isDirectory)
        outside = base.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "untouched\n".write(
            to: outside.appending(path: "sentinel"), atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    var path: String { root.path(percentEncoded: false) }

    func url(_ path: String) -> URL {
        root.appending(path: path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }

    func directory(_ path: String) throws {
        try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
    }

    func file(_ path: String, _ contents: String = "", mode: Int = 0o644) throws {
        try FileManager.default.createDirectory(
            at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url(path), atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: mode], ofItemAtPath: url(path).path(percentEncoded: false))
    }

    func link(_ path: String, to target: String) throws {
        try FileManager.default.createDirectory(
            at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: url(path).path(percentEncoded: false), withDestinationPath: target)
    }

    func contents(_ path: String) -> String? {
        try? String(contentsOf: url(path), encoding: .utf8)
    }

    func linkTarget(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(
            atPath: url(path).path(percentEncoded: false))
    }

    func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url(path).path(percentEncoded: false)))
            != nil
    }

    func mode(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url(path).path(percentEncoded: false)))?[
            .posixPermissions] as? Int
    }

    /// Every entry of the temporary directory outside `root`, by path relative to it.
    func entriesOutsideTheRoot() -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: base.path(percentEncoded: false))
        var entries: [String] = []
        while let entry = enumerator?.nextObject() as? String {
            if entry == "root" || entry.hasPrefix("root/") { continue }
            entries.append(entry)
        }
        return entries.sorted()
    }

    /// A small Ubuntu-like root: a merged `/usr` with `/sbin/init` as a link to systemd, and
    /// the files that the inspection and the configuration read.
    static func ubuntu() throws -> FakeRoot {
        let fake = try FakeRoot()
        try fake.file(
            "etc/passwd",
            "root:x:0:0:root:/root:/bin/bash\nayse:x:1000:1000::/home/ayse:/bin/bash\n")
        try fake.file("etc/group", "root:x:0:\nsudo:x:27:ayse\n")
        try fake.file("etc/hostname", "old-host\n")
        try fake.file("etc/machine-id", "0123456789abcdef0123456789abcdef\n", mode: 0o444)
        try fake.link("var/lib/dbus/machine-id", to: "/etc/machine-id")
        try fake.link("etc/resolv.conf", to: "/mnt/wsl/resolv.conf")
        try fake.file("etc/fstab", "C: /mnt/c drvfs defaults 0 0\n")
        try fake.file("usr/lib/systemd/systemd", "#!/bin/sh\n", mode: 0o755)
        try fake.file("usr/lib/systemd/system/systemd-networkd.service")
        try fake.file("usr/lib/systemd/system/systemd-resolved.service")
        try fake.link("usr/sbin/init", to: "../lib/systemd/systemd")
        try fake.link("sbin", to: "usr/sbin")
        try fake.link("lib", to: "usr/lib")
        try fake.directory("etc/systemd/system")
        try fake.directory("home/ayse")
        for directory in ["dev", "proc", "sys", "run", "tmp"] {
            try fake.directory(directory)
        }
        return fake
    }
}
