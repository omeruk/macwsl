import Darwin
import Foundation
import MawCore
import MawVirtualization
import MawXPC
import Testing

/// The figures of `watchDistributions` on the test distribution, through the probe's `--watch`
/// mode, and how watching leaves the machines' lifetimes alone.
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled,
        "Integration tests boot a real virtual machine; run scripts/integration-test.sh."),
    .serialized,
    .timeLimit(.minutes(10))
)
struct FigureIntegrationTests {
    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    /// While a session keeps the machine running, the figures arrive; MEMORY follows 300 MB in
    /// `/dev/shm`, CPU follows `yes`, and DISK is the image's allocated size.
    @Test func reportsTheFiguresOfARunningMachine() async throws {
        let session = try IntegrationProbe(maw: maw)
        defer { session.stop() }
        let started = try #require(await session.result(1), "\(session.transcript)")
        try #require(started.hasPrefix("started "), "\(session.transcript)")
        let watcher = try Watcher(maw)
        defer { watcher.stop() }

        let running = try await watcher.first("every figure of the running machine") {
            $0.state == .running && $0.memoryUsedBytes != nil && $0.cpuPercent != nil
                && $0.hostMemoryBytes != nil && $0.ipv4Address != nil
        }
        let manifest = try GuestFiles(directory: maw.paths.kernelDirectory).manifest
        #expect(running.figures.kernelRelease == manifest?.kernel.release)
        #expect(running.figures.bootMilliseconds != nil && running.figures.run != nil)
        #expect(running.figures.uptimeMilliseconds != nil)
        #expect(running.figures.memoryLimitBytes != nil)
        let disk = maw.paths.diskImage(for: try DistroName(maw.distribution))
        let usage = try #require(DiskImage.usage(disk))
        let allocated = try #require(running.figures.diskAllocatedBytes)
        #expect(
            abs(Double(allocated) - Double(usage.allocatedBytes)) <= 0.01
                * Double(usage.allocatedBytes))
        #expect(running.figures.diskSizeBytes == usage.sizeBytes)

        let before = try #require(running.figures.memoryUsedBytes)
        // One command line holds the file: logind removes a user's files in /dev/shm when the
        // command's session ends (RemoveIPC). maw joins the words after -- into one command line.
        let fill = try maw.start([
            "-d", maw.distribution, "--",
            "head -c 300000000 /dev/zero > /dev/shm/maw-figures; sleep 10; rm /dev/shm/maw-figures",
        ])
        let filled = try await watcher.first("MEMORY up by 250 MB", after: Watcher.now) {
            ($0.memoryUsedBytes ?? 0) >= before + 250_000_000
        }
        let filling = await fill.waitForExit(timeout: .seconds(60))
        try #require(filling.status == 0, "\(filling.standardError)")
        _ = try await watcher.first("MEMORY down again", after: Watcher.now) {
            ($0.memoryUsedBytes ?? .max) + 200_000_000 <= (filled.figures.memoryUsedBytes ?? 0)
        }

        let busy = try maw.start([
            "-d", maw.distribution, "--", "timeout 8 yes > /dev/null",
        ])
        _ = try await watcher.first("CPU above 80 %") { ($0.cpuPercent ?? 0) > 80 }
        _ = await busy.waitForExit(timeout: .seconds(30))
        _ = try await watcher.first("CPU below 10 %", after: Watcher.now) {
            ($0.cpuPercent ?? 100) < 10
        }

        let pid = watcher.probe.process.processIdentifier
        watcher.stop()
        #expect(try await session.send("close") == "closed hung-up", "\(session.transcript)")
        try await eventuallyLogged("process \(pid) stopped watching the distributions")
        let log = try maw.daemonLogLines(since: "process \(pid) started watching the distributions")
        #expect(log.filter { $0.contains("process \(pid) started watching") }.count == 1)
        #expect(log.filter { $0.contains("process \(pid) stopped watching") }.count == 1)
        #expect(!log.contains { $0.contains("sample") })
    }

    /// A machine with no session stops after the test daemon's idle timeout while it is watched,
    /// and watching starts no machine.
    @Test func doesNotKeepOrStartAMachine() async throws {
        let watcher = try Watcher(maw)
        defer { watcher.stop() }
        let idle = try await watcher.first("the machine stopped", within: .seconds(60)) {
            $0.state == .stopped
        }
        let run = try await maw.session(["-e", "true"])
        try #require(run.status == 0, "\(run.standardError)")
        let ran = try await watcher.first("the machine running", after: idle.time) {
            $0.state == .running
        }
        let stopped = try await watcher.first(
            "the idle stop", after: ran.time, within: .seconds(Double(maw.machineIdleTimeout) + 15)
        ) { $0.state == .stopped }
        try await Task.sleep(for: .seconds(5))
        #expect(
            !watcher.entries.contains { $0.time > stopped.time && $0.figures.state != .stopped })
    }

    @Suite struct Latency {
        let maw: MawIntegration

        init() throws {
            maw = try MawIntegration()
        }

        /// From just before `maw` runs to the watcher's snapshot with the new state: the target
        /// is 500 ms for the daemon's change, which happens after `maw` has connected.
        @Test func measuresAStateChangeByAnotherClient() async throws {
            let session = try IntegrationProbe(maw: maw)
            defer { session.stop() }
            try #require(
                await session.result(1)?.hasPrefix("started ") == true, "\(session.transcript)")
            let watcher = try Watcher(maw)
            defer { watcher.stop() }
            _ = try await watcher.first("the machine running") { $0.state == .running }
            let before = Watcher.now
            let terminate = try maw.start(["--terminate", maw.distribution])
            let stopping = try await watcher.first("the stop", after: before) {
                $0.state != .running
            }
            _ = await terminate.waitForExit(timeout: .seconds(30))
            let median = MawIntegration.report(
                "a state change by maw --terminate, to the watcher",
                [Double(stopping.time - before) / 1e6])
            #expect(median < 500)
        }
    }

    private func eventuallyLogged(_ text: String) async throws {
        let found = await maw.eventually(within: .seconds(10)) {
            (try? maw.daemonLogLines(since: text).isEmpty == false) ?? false
        }
        try #require(found, "mawd.log has no line with \(text)")
    }
}

/// The probe's `--watch` mode: every snapshot of the test distribution with the time it arrived,
/// on `CLOCK_UPTIME_RAW`.
final class Watcher: Sendable {
    let probe: IntegrationProbe
    let distribution: String

    init(_ maw: MawIntegration) throws {
        probe = try IntegrationProbe(maw: maw, arguments: ["--watch"])
        distribution = maw.distribution
    }

    /// When the probe started to connect.
    func started() async throws -> UInt64 {
        let line = try #require(await probe.result(1), "\(probe.transcript)")
        return try #require(UInt64(line.dropFirst("watching ".count)), "\(probe.transcript)")
    }

    var entries: [(time: UInt64, sequence: UInt64, figures: DistributionFigures)] {
        probe.results.compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count == 3, parts[0] == "snapshot", let time = UInt64(parts[1]),
                let snapshot = try? JSONDecoder().decode(
                    DistributionSnapshot.self, from: Data(parts[2].utf8)),
                let figures = snapshot.distributions.first(where: {
                    $0.name.rawValue == distribution
                })
            else { return nil }
            return (time, snapshot.sequence, figures)
        }
    }

    /// The first snapshot after `after` that satisfies `condition`.
    func first(
        _ what: String, after: UInt64? = nil, within timeout: Duration = .seconds(30),
        _ condition: (DistributionFigures) -> Bool
    ) async throws -> (time: UInt64, figures: DistributionFigures) {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let found = entries.first(where: { $0.time > (after ?? 0) && condition($0.figures) })
            {
                return (found.time, found.figures)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WatchFailure(
            description: "no snapshot with \(what) within \(timeout)\n\(probe.transcript)")
    }

    /// The time now, as the probe's snapshots carry it.
    static var now: UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    func stop() {
        probe.stop()
    }
}

struct WatchFailure: Error, CustomStringConvertible {
    let description: String
}
