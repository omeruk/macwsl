import Darwin
import Foundation
import MawCore
import MawDaemonKit
import MawXPC
import Testing

/// The daemon's measurements of `prompts/11c-distribution-figures.md` ("Speed targets" and
/// "Limits on cost"), which scripts/measure-figures.sh runs through scripts/integration-test.sh
/// with `MAW_MEASURE=1`. They never run with the other integration tests: they hold a session
/// that keeps the machine running, which the idle-stop tests must not see. Each measurement runs
/// 5 times and prints its median and its 95th percentile (nearest rank).
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled && MawIntegration.environment["MAW_MEASURE"] == "1",
        "The measurements run only through scripts/measure-figures.sh."),
    .serialized,
    .timeLimit(.minutes(60))
)
struct FigureMeasurements {
    static let runs = 5
    /// The interval of the batch that measures the agent's CPU time per sample.
    static let batchInterval = 100
    static let batchSamples: UInt64 = 1_000

    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    /// From the start of a watch, with the daemon running and the machine running, to the first
    /// snapshot with DISK, UPTIME, KERNEL, and MEMORY, and to the first with CPU.
    @Test func measuresTheFirstFigures() async throws {
        let session = try await heldSession()
        defer { session.stop() }
        var first: [Double] = []
        var cpu: [Double] = []
        for _ in 0..<Self.runs {
            let watcher = try Watcher(maw)
            let start = try await watcher.started()
            let figures = try await watcher.first("the first figures") {
                $0.diskAllocatedBytes != nil && $0.uptimeMilliseconds != nil
                    && $0.kernelRelease != nil && $0.memoryUsedBytes != nil
            }
            let withCPU = try await watcher.first("the first CPU figure") { $0.cpuPercent != nil }
            first.append(Double(figures.time - start) / 1e6)
            cpu.append(Double(withCPU.time - start) / 1e6)
            try await stop(watcher)
        }
        Self.report("first figures from the start of a watch", first, unit: "ms", target: "< 500")
        Self.report("first CPU figure from the start of a watch", cpu, unit: "ms", target: "< 3000")
    }

    /// From just before `maw --terminate` runs to the watcher's snapshot with the new state.
    @Test func measuresAStateChangeByAnotherClient() async throws {
        var times: [Double] = []
        for _ in 0..<Self.runs {
            let session = try await heldSession()
            defer { session.stop() }
            let watcher = try Watcher(maw)
            _ = try await watcher.first("the machine running") { $0.state == .running }
            let before = Watcher.now
            let terminate = try maw.start(["--terminate", maw.distribution])
            let changed = try await watcher.first("the stop", after: before) {
                $0.state != .running
            }
            times.append(Double(changed.time - before) / 1e6)
            _ = await terminate.waitForExit(timeout: .seconds(30))
            try await stop(watcher)
        }
        Self.report(
            "a state change by maw --terminate, to a watcher", times, unit: "ms", target: "< 500")
    }

    /// The agent's CPU time per sample: its utime and stime from `/proc/<pid>/stat`, read through
    /// exec, before and after a batch of about 1,000 samples at 100 ms, minus the cost of one read
    /// (two reads with no sample between them). The fields count 10 ms ticks, so over 1,000
    /// samples the resolution is 0.01 ms per sample. The batch's snapshots give the time of one
    /// sample in the daemon, from the request to the reply.
    @Test func measuresTheAgentsCPUPerSample() async throws {
        try await registerDaemon(sampleInterval: Self.batchInterval)
        defer { try? reinstallDaemon() }
        let session = try await heldSession()
        defer { session.stop() }
        var perSample: [Double] = []
        var sampleTimes: [Double] = []
        for _ in 0..<Self.runs {
            let first = try await agentTicks()
            let read = try await agentTicks() - first
            let before = try await agentTicks()
            let watcher = try Watcher(maw)
            let start = try await watcher.first("the first sample") { $0.memoryUsedBytes != nil }
            let startSequence = watcher.entries.first { $0.time == start.time }?.sequence ?? 0
            let deadline = ContinuousClock.now + .seconds(300)
            while (watcher.entries.last?.sequence ?? 0) < startSequence + Self.batchSamples {
                try #require(ContinuousClock.now < deadline, "the batch did not finish")
                try await Task.sleep(for: .milliseconds(100))
            }
            try await stop(watcher)
            let after = try await agentTicks()
            let entries = watcher.entries
            let samples = Double((entries.last?.sequence ?? 0) - startSequence + 1)
            perSample.append((Double(after) - Double(before) - Double(read)) * 10 / samples)
            sampleTimes += entries.compactMap(\.figures.lastSampleMicroseconds).map {
                Double($0) / 1000
            }
        }
        Self.report(
            "the guest agent's CPU time per sample (resolution 0.01 ms)", perSample, unit: "ms",
            target: "< 0.5")
        Self.report(
            "one sample in the daemon, from the request to the reply", sampleTimes, unit: "ms",
            target: "median < 5")
    }

    /// "Limits on cost" for one running distribution: 60 s without a watcher, then 60 s with one.
    @Test func measuresTheCostOfWatching() async throws {
        let session = try await heldSession()
        defer { session.stop() }
        let daemon = try await maw.daemonProcessID()
        let disk = maw.paths.diskImage(for: try DistroName(maw.distribution))
        let identity = try #require(FileIdentity(path: disk.path(percentEncoded: false)))
        let machine = try #require(
            MachineProcessFinder.find(diskImage: identity, user: getuid(), in: DarwinProcessTable())
        )
        var rows: [String: [Double]] = [:]
        for _ in 0..<Self.runs {
            let first = try await agentTicks()
            let read = Double(try await agentTicks() - first) * 10
            let hidden = try await window(
                daemon: daemon, machine: machine, readCost: read, watcher: nil)
            let watcher = try Watcher(maw)
            _ = try await watcher.first("the first sample") { $0.memoryUsedBytes != nil }
            let shown = try await window(
                daemon: daemon, machine: machine, readCost: read, watcher: watcher)
            try await stop(watcher)
            rows["mawd's CPU while watched, % of one core (< 0.5)", default: []].append(
                shown.daemon)
            rows["mawd's CPU while not watched, % of one core", default: []].append(hidden.daemon)
            rows["the guest agent's CPU while watched, % of one core (< 0.1)", default: []].append(
                shown.agent)
            rows[
                "the machine's process above its cost unwatched, % of one core (< 0.2)", default: []
            ]
            .append(shown.machine - hidden.machine)
            rows["mawd's resident memory growth while watched, MiB (< 1)", default: []].append(
                shown.growth)
        }
        for (what, values) in rows.sorted(by: { $0.key < $1.key }) {
            Self.report(what, values, unit: "", target: "")
        }
    }

    // MARK: Helpers

    struct Window {
        var daemon: Double
        var agent: Double
        var machine: Double
        var growth: Double
    }

    /// 60 seconds of the costs, in percent of one core and MiB.
    private func window(
        daemon: pid_t, machine: ProcessIdentity, readCost: Double, watcher: Watcher?
    ) async throws -> Window {
        let table = DarwinProcessTable()
        let agentBefore = try await agentTicks()
        let daemonBefore = try #require(table.usage(of: daemon)).cpuNanoseconds
        let machineBefore = try #require(MachineProcessFinder.usage(of: machine, in: table))
        let residentBefore = try resident(daemon)
        let start = ContinuousClock.now
        try await Task.sleep(for: .seconds(60))
        let seconds = Double((ContinuousClock.now - start).components.seconds)
        let daemonAfter = try #require(table.usage(of: daemon)).cpuNanoseconds
        let machineAfter = try #require(MachineProcessFinder.usage(of: machine, in: table))
        let residentAfter = try resident(daemon)
        let agentAfter = try await agentTicks()
        return Window(
            daemon: Double(daemonAfter - daemonBefore) / 1e7 / seconds,
            agent: (Double(agentAfter - agentBefore) * 10 - readCost) / 10 / seconds,
            machine: Double(machineAfter.cpuNanoseconds - machineBefore.cpuNanoseconds) / 1e7
                / seconds,
            growth: (Double(residentAfter) - Double(residentBefore)) / 1024)
    }

    /// A session in the test distribution, which keeps its machine running.
    private func heldSession() async throws -> IntegrationProbe {
        let session = try IntegrationProbe(maw: maw)
        try #require(
            await session.result(1)?.hasPrefix("started ") == true, "\(session.transcript)")
        return session
    }

    /// Ends a watch, and waits until the daemon has logged its end.
    private func stop(_ watcher: Watcher) async throws {
        let pid = watcher.probe.process.processIdentifier
        watcher.stop()
        let ended = await maw.eventually(within: .seconds(10)) {
            (try? maw.daemonLogLines(since: "process \(pid) stopped watching").isEmpty) == false
        }
        try #require(ended, "the daemon did not log the end of watching")
    }

    /// The guest agent's utime and stime, in ticks of 10 ms, through exec.
    private func agentTicks() async throws -> UInt64 {
        let read = try await maw.session([
            "--", "cat /proc/$(systemctl show -p MainPID --value maw-agent.service)/stat",
        ])
        let fields = read.output.split(separator: " ")
        try #require(read.status == 0 && fields.count > 15, "\(read.output)\(read.standardError)")
        return try #require(UInt64(fields[13])) + (try #require(UInt64(fields[14])))
    }

    /// The resident size of `pid`, in KiB.
    private func resident(_ pid: pid_t) throws -> UInt64 {
        let ps = Process()
        let pipe = Pipe()
        ps.executableURL = URL(filePath: "/bin/ps")
        ps.arguments = ["-o", "rss=", "-p", String(pid)]
        ps.standardOutput = pipe
        try ps.run()
        ps.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return try #require(UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// Registers the test daemon again with `--sample-interval-ms`, which `mawd install` does not
    /// accept: the plist that `mawd install` would write, with the option added. The daemon
    /// restarts.
    private func registerDaemon(sampleInterval: Int) async throws {
        let mawd = try #require(MawIntegration.environment["MAWD_PATH"])
        let agent = LaunchAgent(
            label: maw.label, program: mawd, logDirectory: maw.logDirectory,
            machineIdleTimeout: maw.machineIdleTimeout, imageCacheDirectory: maw.imageCache)
        var list = agent.propertyList
        list["ProgramArguments"] =
            agent.arguments + ["--sample-interval-ms", String(sampleInterval)]
        let plist = maw.paths.launchAgentFile(label: maw.label)
        try PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0)
            .write(to: plist, options: .atomic)
        try Launchctl.bootout(maw.label)
        try await Launchctl.waitUntilRemoved(maw.label)
        try Launchctl.bootstrap(plist)
    }

    /// Registers the test daemon again as scripts/integration-test.sh does.
    private func reinstallDaemon() throws {
        let install = Process()
        install.executableURL = URL(filePath: try #require(MawIntegration.environment["MAWD_PATH"]))
        install.arguments = [
            "install", "--label", maw.label, "--log-directory",
            maw.logDirectory.path(percentEncoded: false), "--machine-idle-timeout",
            String(maw.machineIdleTimeout), "--image-cache-directory",
            maw.imageCache.path(percentEncoded: false),
        ]
        try install.run()
        install.waitUntilExit()
        try #require(install.terminationStatus == 0, "mawd install failed")
    }

    /// Prints the median and the 95th percentile (nearest rank) of `values`.
    static func report(_ what: String, _ values: [Double], unit: String, target: String) {
        let sorted = values.sorted()
        guard !sorted.isEmpty else {
            print("measurement: \(what): no values")
            return
        }
        let median =
            sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        let p95 = sorted[Int((0.95 * Double(sorted.count)).rounded(.up)) - 1]
        let suffix = unit.isEmpty ? "" : " \(unit)"
        print(
            "measurement: \(what): median \(String(format: "%.3f", median))\(suffix), "
                + "95th percentile \(String(format: "%.3f", p95))\(suffix), \(sorted.count) values"
                + (target.isEmpty ? "" : ", target \(target)\(suffix)"))
    }
}
