import Darwin
import Foundation
import MawCore
import Testing

/// The measurements of `prompts/07-file-sharing-and-paths.md`, "Speed targets", for pull request
/// A, which scripts/measure-mac-share.sh runs through scripts/integration-test.sh with
/// `MAW_MEASURE=1`. They never run with the other integration tests.
///
/// Every file goes into a directory of `MawIntegration.withMacDirectory` under
/// `~/Library/Caches/maw`, which each measurement removes even on failure. Each measurement runs
/// 5 times and prints its median and its slowest run on a line that starts with "measurement:";
/// for a throughput, the slowest run is the lowest figure. The guest's caches are dropped before
/// each run that reads; the Mac's are not, which needs root.
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled && MawIntegration.environment["MAW_MEASURE"] == "1",
        "The measurements run only through scripts/measure-mac-share.sh."),
    .serialized,
    .timeLimit(.minutes(60))
)
struct MacShareMeasurements {
    static let runs = 5
    static let gibibyte = 1_073_741_824.0

    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    func guest(
        _ script: String, as user: String? = nil, timeout: Duration = .seconds(600)
    ) async throws -> DebugBootProcess.Result {
        let result = try await maw.run(
            ["-d", maw.distribution] + (user.map { ["-u", $0] } ?? []) + [
                "-e", "sh", "-c", script,
            ],
            timeout: timeout)
        try #require(result.status == 0, "\(script): \(result.output)\(result.standardError)")
        return result
    }

    /// Drops the guest's page, dentry, and inode caches.
    func dropGuestCaches() async throws {
        _ = try await guest("sync; echo 3 > /proc/sys/vm/drop_caches", as: "root")
    }

    /// The milliseconds that `script` prints as `elapsed <ns>`, from the guest's clock.
    func timedInGuest(_ script: String, as user: String? = nil) async throws -> Double {
        let result = try await guest(
            "t0=$(date +%s%N); \(script); t1=$(date +%s%N); echo \"elapsed $((t1 - t0))\"",
            as: user)
        let line = try #require(result.lines.last { $0.hasPrefix("elapsed ") }, "\(result.output)")
        return try #require(Double(line.dropFirst("elapsed ".count))) / 1e6
    }

    /// Cold start to a prompt, with the share and with `mawd serve --without-mac-share`,
    /// alternating; the test daemon is registered again for each, and is started before the
    /// timed run, so that the daemon's own start does not count.
    @Test func measuresColdStartToAPrompt() async throws {
        defer { try? maw.reinstallDaemon() }
        var times: [Bool: [Double]] = [true: [], false: []]
        for _ in 1...Self.runs {
            for share in [true, false] {
                if share {
                    try maw.reinstallDaemon()
                } else {
                    try await maw.registerDaemon(["--without-mac-share"])
                }
                _ = try await maw.run(["--status"])
                _ = try await maw.run(["--terminate", maw.distribution])
                try await Task.sleep(for: .seconds(2))
                let started = ContinuousClock.now
                let session = try maw.interactive(["-d", maw.distribution])
                #expect(
                    await session.waitForPrompt(
                        user: maw.user, host: maw.hostname(of: maw.distribution)))
                times[share]?.append((ContinuousClock.now - started).fractionalMilliseconds)
                session.type("exit\r")
                _ = await session.waitForExit(timeout: .seconds(30))
            }
        }
        let with = MawIntegration.report(
            "cold start to a prompt, with the share", times[true] ?? [])
        let without = MawIntegration.report(
            "cold start to a prompt, without the share (mawd serve --without-mac-share)",
            times[false] ?? [])
        print(
            "measurement: the share adds \(String(format: "%.0f", with - without)) ms to the"
                + " median cold start to a prompt (target: under 100 ms)")
        #expect(with - without < 100)
    }

    @Test func measuresALargeFile() async throws {
        try await maw.withMacDirectory { _, linux in
            var write: [Double] = []
            var read: [Double] = []
            for _ in 1...Self.runs {
                _ = try await guest("rm -f '\(linux)/big'; sync")
                write.append(
                    try await timedInGuest(
                        "dd if=/dev/zero of='\(linux)/big' bs=1M count=1024 conv=fsync status=none")
                )
                try await dropGuestCaches()
                read.append(
                    try await timedInGuest("dd if='\(linux)/big' of=/dev/null bs=1M status=none"))
            }
            MawIntegration.report(
                "writing a 1 GiB file to /mnt/mac (dd conv=fsync)",
                write.map { Self.gibibyte / 1e6 / ($0 / 1e3) }, unit: "MB/s", higherIsFaster: true)
            MawIntegration.report(
                "reading a 1 GiB file from /mnt/mac to /dev/null, guest caches dropped",
                read.map { Self.gibibyte / 1e6 / ($0 / 1e3) }, unit: "MB/s", higherIsFaster: true)
        }
    }

    @Test func measuresAListingOf10000Files() async throws {
        try await maw.withMacDirectory { mac, linux in
            let many = mac.appending(path: "many", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: many, withIntermediateDirectories: false)
            for index in 0..<10_000 {
                let path = many.appending(path: String(format: "f%05d", index))
                    .path(percentEncoded: false)
                try #require(FileManager.default.createFile(atPath: path, contents: nil))
            }
            var times: [Double] = []
            for _ in 1...Self.runs {
                try await dropGuestCaches()
                times.append(try await timedInGuest("ls -l '\(linux)/many' > /dev/null"))
            }
            MawIntegration.report(
                "ls -l of a directory of 10,000 files under /mnt/mac, guest caches dropped", times)
        }
    }

    @Test func measuresGitStatus() async throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try await maw.withMacDirectory { mac, linux in
            let clone = try DebugBootProcess(
                executable: URL(filePath: "/usr/bin/git"),
                arguments: [
                    "clone", "--quiet", "--no-hardlinks", repository.path(percentEncoded: false),
                    mac.appending(path: "repository").path(percentEncoded: false),
                ], separateStandardError: true)
            let cloned = await clone.waitForExit(timeout: .seconds(300))
            try #require(cloned.status == 0, "git clone: \(cloned.standardError)")
            var first: [Double] = []
            var second: [Double] = []
            for _ in 1...Self.runs {
                try await dropGuestCaches()
                first.append(
                    try await timedInGuest("git -C '\(linux)/repository' status > /dev/null"))
                second.append(
                    try await timedInGuest("git -C '\(linux)/repository' status > /dev/null"))
            }
            MawIntegration.report(
                "git status in a clone of this repository under /mnt/mac, first run", first)
            let median = MawIntegration.report(
                "git status in a clone of this repository under /mnt/mac, second run"
                    + " (target: under 1 s)", second)
            #expect(median < 1_000)
        }
    }
}
