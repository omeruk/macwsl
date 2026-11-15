import Darwin
import Foundation
import MawCore
import MawDaemonKit
import Testing
import os

/// The measurements of `prompts/06b-distro-removal-and-transfer.md`, "Speed targets", for
/// `maw --unregister` and `maw --export`, which scripts/measure-transfer.sh runs through
/// scripts/integration-test.sh with `MAW_MEASURE=1`. They never run with the other integration
/// tests, because each installs distributions of its own and the compressed exports take
/// minutes.
///
/// Every distribution is installed here from the cached image under `MAW_TEST_PREFIX` and
/// removed through `MawIntegration.unregister`, and every archive goes into
/// `MAW_TEST_EXPORT_DIRECTORY` and is deleted after its run. Each measurement runs 5 times and
/// prints its median and its slowest run on a line that starts with "measurement:".
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled && MawIntegration.environment["MAW_MEASURE"] == "1",
        "The measurements run only through scripts/measure-transfer.sh."),
    .serialized,
    .timeLimit(.minutes(120))
)
struct TransferMeasurements {
    static let runs = 5
    static let mebibyte = 1_048_576.0

    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    /// From maw's start to its exit, for a distribution whose machine is stopped. Each run
    /// removes a distribution installed for it.
    @Test func measuresUnregisterOfAStoppedDistribution() async throws {
        var times: [Double] = []
        for run in 1...Self.runs {
            try await maw.withDistribution("measure-unregister-stopped-\(run)") { name in
                let (status, elapsed) = try await maw.timedUnregister(name)
                try #require(status == 0)
                #expect(maw.traces(of: name).isEmpty)
                times.append(elapsed)
            }
        }
        let median = MawIntegration.report(
            "maw --unregister of a stopped distribution, to maw's exit", times)
        #expect(median < 1_000)
    }

    /// The same for a distribution whose machine has booted, finished starting systemd, and
    /// runs no session. The session waits for the system bus's socket before it asks systemd,
    /// as `DistroManagementIntegrationTests.measuresTerminateOfARunningIdleDistribution` does.
    @Test func measuresUnregisterOfARunningIdleDistribution() async throws {
        var times: [Double] = []
        for run in 1...Self.runs {
            try await maw.withDistribution("measure-unregister-running-\(run)") { name in
                let booted = try await maw.session(
                    [
                        "--",
                        "for i in $(seq 300); do [ -S /run/dbus/system_bus_socket ] && break;"
                            + " sleep 0.1; done; systemctl is-system-running --wait",
                    ], in: name)
                #expect(
                    ["running", "degraded"].contains(booted.lines.first ?? ""),
                    "\(booted.status) \(booted.output)\(booted.standardError)")
                try #require(try await maw.machineRow(of: name).contains("Running"))
                let (status, elapsed) = try await maw.timedUnregister(name)
                try #require(status == 0)
                #expect(maw.traces(of: name).isEmpty)
                times.append(elapsed)
            }
        }
        let median = MawIntegration.report(
            "maw --unregister of a running, idle distribution, to maw's exit", times)
        #expect(median < 2_000)
    }

    /// `--export` of a freshly installed distribution to an uncompressed tar file: the time to
    /// maw's exit, the throughput, and how much the daemon's footprint grows meanwhile.
    @Test func measuresExportToAFile() async throws {
        try await maw.withDistribution("measure-export-file") { name in
            let daemon = try await maw.daemonProcessID()
            var times: [Double] = []
            var throughput: [Double] = []
            var growth: [Double] = []
            for run in 1...Self.runs {
                try await maw.withExportDirectory { directory in
                    let file = directory.appending(path: "run-\(run).tar")
                    let (timed, grew) = try await Self.footprintGrowth(of: daemon) {
                        try await maw.timed(
                            ["--export", name, file.path(percentEncoded: false)],
                            timeout: .seconds(600))
                    }
                    try #require(timed.status == 0)
                    let bytes = try Self.size(of: file)
                    times.append(timed.milliseconds)
                    throughput.append(Double(bytes) / 1e6 / (timed.milliseconds / 1e3))
                    growth.append(grew)
                    print("export run \(run): \(bytes) bytes")
                }
            }
            let median = MawIntegration.report(
                "maw --export of a freshly installed test distribution to an uncompressed tar "
                    + "file, to maw's exit", times)
            MawIntegration.report("the same export's throughput", throughput, unit: "MB/s")
            MawIntegration.report(
                "the daemon's footprint growth during an export to a file", growth, unit: "MiB")
            #expect(median < 30_000)
            #expect((growth.max() ?? .infinity) < 64)
        }
    }

    /// `maw --export <name> - | wc -c`: the throughput through a pipe and how much the daemon's
    /// footprint grows meanwhile, since a slow reader must hold the machine back rather than
    /// make the daemon buffer.
    @Test func measuresExportThroughAPipe() async throws {
        try await maw.withDistribution("measure-export-pipe") { name in
            let daemon = try await maw.daemonProcessID()
            var times: [Double] = []
            var throughput: [Double] = []
            var growth: [Double] = []
            for _ in 1...Self.runs {
                let started = ContinuousClock.now
                let (result, grew) = try await Self.footprintGrowth(of: daemon) {
                    let shell = try DebugBootProcess(
                        executable: URL(filePath: "/bin/sh"),
                        arguments: [
                            "-c", "\"$0\" --export \"$1\" - | wc -c",
                            maw.maw.path(percentEncoded: false), name,
                        ], separateStandardError: true, environment: maw.mawEnvironment)
                    return await shell.waitForExit(timeout: .seconds(600))
                }
                let elapsed = (ContinuousClock.now - started).fractionalMilliseconds
                try #require(result.status == 0, "\(result.standardError)")
                let bytes = try #require(
                    Double(result.output.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "\(result.output)")
                try #require(bytes > 0)
                times.append(elapsed)
                throughput.append(bytes / 1e6 / (elapsed / 1e3))
                growth.append(grew)
            }
            MawIntegration.report("maw --export - | wc -c, to the pipeline's exit", times)
            MawIntegration.report("the same export's throughput", throughput, unit: "MB/s")
            MawIntegration.report(
                "the daemon's footprint growth during an export through a pipe", growth,
                unit: "MiB")
            #expect((growth.max() ?? .infinity) < 64)
        }
    }

    /// `--format tar.gz` and `--format tar.xz` of the same distribution: reported only.
    @Test func measuresCompressedExports() async throws {
        try await maw.withDistribution("measure-export-compressed") { name in
            for format in ["tar.gz", "tar.xz"] {
                var times: [Double] = []
                var sizes: [Double] = []
                for run in 1...Self.runs {
                    try await maw.withExportDirectory { directory in
                        let file = directory.appending(path: "run-\(run).\(format)")
                        let timed = try await maw.timed(
                            ["--export", name, file.path(percentEncoded: false)],
                            timeout: .seconds(1_800))
                        try #require(timed.status == 0, "\(format)")
                        times.append(timed.milliseconds)
                        sizes.append(Double(try Self.size(of: file)) / Self.mebibyte)
                    }
                }
                MawIntegration.report("maw --export --format \(format), to maw's exit", times)
                MawIntegration.report("the \(format) archive's size", sizes, unit: "MiB")
            }
        }
    }

    // MARK: Helpers

    /// Runs `body` while it samples the daemon's footprint (`ri_phys_footprint`) every 20 ms,
    /// and returns the result with the largest growth over the footprint before `body`, in MiB.
    static func footprintGrowth<T: Sendable>(
        of daemon: pid_t, _ body: () async throws -> T
    ) async throws -> (T, Double) {
        let table = DarwinProcessTable()
        let before = try #require(
            table.usage(of: daemon), "The daemon's footprint cannot be read."
        ).footprintBytes
        let peak = OSAllocatedUnfairLock(initialState: before)
        let sampler = Task.detached {
            while !Task.isCancelled {
                if let usage = table.usage(of: daemon) {
                    peak.withLock { $0 = max($0, usage.footprintBytes) }
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let result: T
        do {
            result = try await body()
        } catch {
            sampler.cancel()
            throw error
        }
        sampler.cancel()
        _ = await sampler.value
        if let usage = table.usage(of: daemon) {
            peak.withLock { $0 = max($0, usage.footprintBytes) }
        }
        let grown = peak.withLock { $0 } - before
        return (result, Double(grown) / mebibyte)
    }

    static func size(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false))
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
