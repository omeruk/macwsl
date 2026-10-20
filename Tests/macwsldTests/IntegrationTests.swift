import Darwin
import Foundation
import Testing
import os

extension Tag {
    /// Tests that boot a real virtual machine. They need an Apple silicon Mac that is not itself
    /// a virtual machine, the guest files from scripts/fetch-guest.sh, and a signed macwsld.
    @Tag static var integration: Self
}

private let integrationEnabled = ProcessInfo.processInfo.environment["MACWSL_INTEGRATION"] == "1"

/// Boots the guest by running the signed `macwsld debug-boot` as a subprocess. The `swift test`
/// runner is not signed with the virtualization entitlement, so these tests cannot create a
/// virtual machine in-process. scripts/integration-test.sh builds and signs macwsld, then runs
/// them with MACWSL_INTEGRATION=1 and MACWSLD_PATH set.
@Suite(
    .tags(.integration),
    .enabled(
        if: integrationEnabled,
        "Integration tests boot a real virtual machine; run scripts/integration-test.sh."),
    .serialized
)
struct IntegrationTests {
    let macwsld: URL

    init() throws {
        let path = try #require(
            ProcessInfo.processInfo.environment["MACWSLD_PATH"],
            "MACWSLD_PATH must point to the signed macwsld; scripts/integration-test.sh sets it.")
        macwsld = URL(filePath: path)
        try #require(
            FileManager.default.isExecutableFile(atPath: path), "\(path) is not an executable.")
        try #require(
            Self.hasVirtualizationEntitlement(path),
            "\(path) is not signed with the virtualization entitlement. Run scripts/sign-dev.sh.")
    }

    @Test func bootsAndPowersOff() async throws {
        let run = try DebugBootProcess(
            macwsld, ["--cmdline", "macwsl.test=poweroff", "--timeout", "30"])
        let result = await run.waitForExit(timeout: .seconds(60))

        #expect(result.status == 0, "\(result.output)")
        #expect(result.lines.contains(where: Self.isBanner), "\(result.output)")
        #expect(
            result.lines.contains { $0.hasPrefix("boot: banner after ") && $0.hasSuffix(" ms") })
        #expect(result.lines.contains("macwsl-initramfs: poweroff"))
        let stoppedAfter = try #require(
            result.milliseconds(after: "debug-boot: vm: stopped after "))
        #expect(stoppedAfter < 10_000, "The VM took \(stoppedAfter) ms to stop.")
    }

    @Test func stopsARunningGuestAndLogsHow() async throws {
        let run = try DebugBootProcess(macwsld, ["--timeout", "120"])
        let bannerSeen = await run.waitForLine(where: Self.isBanner, timeout: .seconds(60))
        try #require(bannerSeen, "The banner did not appear: \(run.output)")

        run.signal(SIGTERM)
        let result = await run.waitForExit(timeout: .seconds(60))

        #expect(result.status == 128 + SIGTERM, "\(result.output)")
        let outcome = try #require(result.lines.first { $0.hasPrefix("debug-boot: shutdown: ") })
        #expect(outcome.contains("shutdown: clean") || outcome.contains("shutdown: forced"))

        // The console log records how the virtual machine was shut down.
        let logPath = try #require(
            result.lines.first { $0.hasPrefix("debug-boot: console log: ") }?
                .dropFirst("debug-boot: console log: ".count))
        let log = try String(contentsOfFile: String(logPath), encoding: .utf8)
        let lastShutdown = try #require(
            DebugBootProcess.lines(of: log).last {
                $0.hasPrefix("[macwsld] ") && $0.contains(" shutdown: ")
            })
        #expect(
            lastShutdown.contains("shutdown: clean") || lastShutdown.contains("shutdown: forced"))
    }

    @Test func attachesASparseDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "macwsl-integration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = directory.appending(path: "disk.img")

        let run = try DebugBootProcess(
            macwsld,
            [
                "--disk", disk.path(percentEncoded: false), "--create-disk", "64M",
                "--cmdline", "macwsl.test=lsblk macwsl.test=poweroff", "--timeout", "30",
            ])
        let result = await run.waitForExit(timeout: .seconds(60))

        #expect(result.status == 0, "\(result.output)")
        #expect(result.lines.contains("/dev/vda"), "\(result.output)")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: disk.path(percentEncoded: false))
        #expect((attributes[.size] as? UInt64) == 64 << 20)
    }

    @Test func refusesInteractiveModeWithoutATerminal() async throws {
        let run = try DebugBootProcess(macwsld, ["--interactive"])
        let result = await run.waitForExit(timeout: .seconds(30))

        #expect(result.status == 1)
        #expect(
            result.lines.first
                == "macwsl: --interactive needs a terminal, but standard input is not a terminal.")
        #expect(!result.output.contains("console log:"), "It must fail before preparing the VM.")
    }

    static func isBanner(_ line: String) -> Bool {
        line.hasPrefix("macwsl-initramfs ") && line.contains(" kernel=")
    }

    static func hasVirtualizationEntitlement(_ path: String) -> Bool {
        let codesign = Process()
        codesign.executableURL = URL(filePath: "/usr/bin/codesign")
        codesign.arguments = ["--display", "--entitlements", "-", path]
        let output = Pipe()
        codesign.standardOutput = output
        codesign.standardError = output
        guard (try? codesign.run()) != nil else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        codesign.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains("com.apple.security.virtualization")
    }
}

/// `macwsld debug-boot` running as a subprocess, with standard output and standard error
/// collected together and standard input at end-of-file.
final class DebugBootProcess: @unchecked Sendable {
    struct Result {
        let status: Int32
        let output: String
        /// The output's lines. The guest console ends lines with "\r\n", which Swift treats
        /// as a single Character, so lines are split on any newline character.
        var lines: [String] {
            DebugBootProcess.lines(of: output)
        }

        /// The number in a line of the form `<prefix><n> ms`.
        func milliseconds(after prefix: String) -> Int? {
            lines.first { $0.hasPrefix(prefix) }
                .flatMap { Int($0.dropFirst(prefix.count).split(separator: " ").first ?? "") }
        }
    }

    private let process = Process()
    private let collected = OSAllocatedUnfairLock(initialState: Data())

    init(_ macwsld: URL, _ arguments: [String]) throws {
        let pipe = Pipe()
        process.executableURL = macwsld
        process.arguments = ["debug-boot"] + arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [collected] handle in
            let data = handle.availableData
            collected.withLock { $0.append(data) }
        }
        try process.run()
    }

    var output: String {
        collected.withLock { String(decoding: $0, as: UTF8.self) }
    }

    func signal(_ number: Int32) {
        kill(process.processIdentifier, number)
    }

    /// Waits until a line of output satisfies `predicate`. Returns whether one did.
    func waitForLine(where predicate: (String) -> Bool, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if Self.lines(of: output).contains(where: predicate) {
                return true
            }
            if !process.isRunning {
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return Self.lines(of: output).contains(where: predicate)
    }

    /// Splits `text` into lines and removes ANSI escape sequences: the guest's busybox colors
    /// the output of `ls` on its console.
    static func lines(of text: String) -> [String] {
        text.replacing(/\u{1B}\[[0-9;]*[A-Za-z]/, with: "")
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
    }

    /// Waits for the process to exit. After `timeout`, kills it and reports status -1.
    func waitForExit(timeout: Duration) async -> Result {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return Result(status: -1, output: output + "\n[test] killed after the timeout\n")
        }
        // Collect output written just before the exit.
        try? await Task.sleep(for: .milliseconds(100))
        return Result(status: process.terminationStatus, output: output)
    }
}
