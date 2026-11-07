import Foundation
import MawCore
import MawTestSupport
import Testing

/// The initramfs's root file system check, `Guest/initramfs/maw-check-root`, with a stand-in
/// for e2fsck that exits with a chosen status. It checks the script's decision whether the
/// distribution boots, and that the daemon reads the status it reports.
///
/// The script runs under the Mac's `/bin/sh` here and under busybox `sh` in the guest; it uses
/// only POSIX shell. The integration tests in `RootFileSystemIntegrationTests` run it in the
/// guest, against real damage that e2fsck repairs or refuses.
@Suite struct RootCheckScriptTests {
    static let script = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Guest/initramfs/maw-check-root")

    struct Run {
        var status: Int32
        var output: String
        var e2fsckArguments: String
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 32, 127, 128, 137])
    func bootsOnlyWithNoErrorsOrCorrectedOnes(_ e2fsckStatus: Int) async throws {
        let run = try await check(withE2fsckExitingWith: e2fsckStatus)
        let boots = e2fsckStatus < 4
        #expect(run.status == (boots ? 0 : 1), "\(run.output)")
        #expect(run.e2fsckArguments == "-p /dev/vda\n")

        // The daemon reads the status from the console, and reaches the same decision.
        var scanner = RootFileSystemCheckScanner()
        for line in run.output.split(separator: "\n") {
            scanner.read(String(line))
        }
        #expect(scanner.check == RootFileSystemCheck(e2fsckStatus: e2fsckStatus))
        #expect(scanner.check?.allowsBoot == boots)
    }

    @Test(
        arguments: [
            (0, nil),
            (1, "maw-initramfs: e2fsck -p corrected errors on /dev/vda (exit status 1)"),
            (2, "maw-initramfs: e2fsck -p corrected errors on /dev/vda (exit status 2)"),
            (4, "maw-initramfs: e2fsck -p left errors uncorrected on /dev/vda (exit status 4)"),
            (8, "maw-initramfs: e2fsck -p could not check /dev/vda (exit status 8)"),
        ] as [(Int, String?)])
    func explainsTheStatusAfterTheMarker(_ e2fsckStatus: Int, _ explanation: String?) async throws {
        let run = try await check(withE2fsckExitingWith: e2fsckStatus)
        let expected =
            ["e2fsck ran", "maw-initramfs: root-check e2fsck-status=\(e2fsckStatus)"]
            + (explanation.map { [$0] } ?? [])
        #expect(run.output.split(separator: "\n").map(String.init) == expected)
    }

    /// Runs the script for `/dev/vda` with a stand-in e2fsck that prints a line, records its
    /// arguments, and exits with `e2fsckStatus`.
    private func check(withE2fsckExitingWith e2fsckStatus: Int) async throws -> Run {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "maw-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let arguments = directory.appending(path: "arguments")
        let e2fsck = directory.appending(path: "e2fsck")
        try """
        #!/bin/sh
        echo "$@" > '\(arguments.path(percentEncoded: false))'
        echo "e2fsck ran"
        exit \(e2fsckStatus)

        """.write(to: e2fsck, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: e2fsck.path)

        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [Self.script.path(percentEncoded: false), "/dev/vda"]
        process.environment = ["PATH": "\(directory.path(percentEncoded: false)):/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        try #require(await process.waitForExit(within: .seconds(30)))
        try? output.fileHandleForWriting.close()
        let text = String(
            decoding: try output.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
        return Run(
            status: process.terminationStatus, output: text,
            e2fsckArguments: (try? String(contentsOf: arguments, encoding: .utf8)) ?? "")
    }
}
