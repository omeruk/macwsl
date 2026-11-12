import Darwin
import Foundation
import MawCore
import MawProtocol
import MawVirtualization
import MawXPC
import Testing

@testable import MawDaemonKit

/// The sampler, with fake machines, a fake process table, and the test clock.
@Suite struct FigureSamplerTests {
    /// A registry whose state changes reach a sampler, as `mawd serve` connects them, with
    /// installed distributions whose disk images exist.
    final class Sampling: Sendable {
        let clock = TestClock()
        let factory: FakeFactory
        let registry: MachineRegistry<TestClock>
        let sampler: FigureSampler<TestClock>
        let distros: TemporaryStore
        let processes = FakeProcessTable([])
        let lines = LogLines()
        private let follower: Task<Void, Never>

        init(
            _ names: [String] = ["Ubuntu-24.04"], factory: FakeFactory = FakeFactory(),
            idleTimeout: Duration = .seconds(600)
        ) throws {
            self.factory = factory
            distros = try TemporaryStore()
            let (changes, continuation) = AsyncStream.makeStream(of: Void.self)
            registry = MachineRegistry(
                clock: clock, idleTimeout: idleTimeout, log: lines.log, factory: factory.factory,
                stateChanged: { continuation.yield() })
            sampler = FigureSampler(
                clock: clock, registry: registry, store: distros.store, processes: processes,
                log: lines.log)
            follower = Task { [sampler] in
                for await _ in changes {
                    await sampler.machinesChanged()
                }
            }
            for (index, name) in names.enumerated() {
                try distros.install(name)
                let disk = distros.store.paths.diskImage(for: try DistroName(name))
                try Data(repeating: 1, count: 4096).write(to: disk)
                let identity = try #require(FileIdentity(path: disk.path(percentEncoded: false)))
                processes.replace(
                    .init(
                        id: pid_t(500 + index), path: MachineProcessFinder.executablePath,
                        user: getuid(), files: [identity]))
            }
        }

        deinit {
            follower.cancel()
        }

        func machine(_ name: String) -> MachineID {
            .distribution(try! DistroName(name))
        }

        /// The newest fake machine of `name`.
        func fake(_ name: String) -> FakeMachine? {
            factory.machines.last { $0.machine == machine(name) }
        }

        func start(_ name: String) async throws {
            try await registry.start(machine(name))
        }

        /// Waits until no sample is in progress and `count` tasks sleep on the clock: one idle
        /// timer per running machine, and the sampler's timer.
        func settle(sleepers count: Int) async throws {
            try await eventually("\(count) sleepers and no sample") {
                await !sampler.isBusy && clock.sleeperCount == count
            }
        }

        /// The figures of `name` in the newest snapshot.
        func figures(_ name: String) async -> DistributionFigures? {
            await sampler.snapshot(after: 0)?.distributions.first {
                $0.name.rawValue == name
            }
        }
    }

    @Test func doesNothingWithoutAWatcher() async throws {
        let sampling = try Sampling()
        try await sampling.start("Ubuntu-24.04")
        await Task.megaYield()
        sampling.clock.advance(by: .seconds(15))
        await Task.megaYield()
        #expect(sampling.fake("Ubuntu-24.04")?.sampleCalls == 0)
        #expect(await !sampling.sampler.hasTimer)
        // A machine that runs while nothing watches is never looked up.
        #expect(sampling.processes.openFilesRead.isEmpty)
    }

    @Test func holdsNoTimerWhileNothingRuns() async throws {
        let sampling = try Sampling()
        await sampling.sampler.addWatcher()
        #expect(await !sampling.sampler.hasTimer)
        #expect(sampling.clock.sleeperCount == 0)
        // Watching starts no machine.
        #expect(sampling.factory.machines.isEmpty)
    }

    @Test func samplesAtOnceWhenWatchingStartsThenEveryInterval() async throws {
        let sampling = try Sampling(["Alpha", "Ubuntu-24.04"])
        try await sampling.start("Alpha")
        try await sampling.start("Ubuntu-24.04")
        await sampling.sampler.addWatcher()
        try await eventually("both machines sampled") {
            sampling.fake("Alpha")?.sampleCalls == 1
                && sampling.fake("Ubuntu-24.04")?.sampleCalls == 1
        }
        #expect(await sampling.sampler.hasTimer)
        try await sampling.settle(sleepers: 3)
        sampling.clock.advance(by: .milliseconds(1_499))
        await Task.megaYield()
        #expect(sampling.fake("Alpha")?.sampleCalls == 1)
        sampling.clock.advance(by: .milliseconds(1))
        try await eventually("the second sample") {
            sampling.fake("Alpha")?.sampleCalls == 2
                && sampling.fake("Ubuntu-24.04")?.sampleCalls == 2
        }
        let figures = try #require(await sampling.figures("Ubuntu-24.04"))
        #expect(figures.memoryUsedBytes == 412 << 20)
        #expect(figures.ipv4Address == "192.168.64.3")
        #expect(figures.hostMemoryBytes == 5_010_000)
    }

    @Test func samplesAMachineThatStartsWhileWatchedAtOnce() async throws {
        let sampling = try Sampling()
        await sampling.sampler.addWatcher()
        try await sampling.start("Ubuntu-24.04")
        try await eventually("the first sample") {
            sampling.fake("Ubuntu-24.04")?.sampleCalls == 1
        }
        #expect(await sampling.sampler.hasTimer)
    }

    @Test func endsTheTimerWhenTheLastMachineStopsAndResumesIt() async throws {
        let sampling = try Sampling()
        try await sampling.start("Ubuntu-24.04")
        await sampling.sampler.addWatcher()
        try await eventually { await sampling.sampler.hasTimer }
        _ = await sampling.registry.terminate(sampling.machine("Ubuntu-24.04"), reason: "test")
        try await eventually("the timer's end") { await !sampling.sampler.hasTimer }
        try await sampling.start("Ubuntu-24.04")
        try await eventually("an immediate sample of the new run") {
            sampling.fake("Ubuntu-24.04")?.sampleCalls == 1
        }
        #expect(sampling.factory.machines.count == 2)
        #expect(await sampling.sampler.hasTimer)
    }

    @Test func samplesOncePerIntervalForSeveralWatchers() async throws {
        let sampling = try Sampling()
        try await sampling.start("Ubuntu-24.04")
        for _ in 0..<3 {
            await sampling.sampler.addWatcher()
        }
        try await eventually { sampling.fake("Ubuntu-24.04")?.sampleCalls == 1 }
        try await sampling.settle(sleepers: 2)
        sampling.clock.advance(by: .milliseconds(1_500))
        try await eventually { sampling.fake("Ubuntu-24.04")?.sampleCalls == 2 }
        await Task.megaYield()
        #expect(sampling.fake("Ubuntu-24.04")?.sampleCalls == 2)
        // Watching stops with the last watcher only.
        await sampling.sampler.removeWatcher()
        await sampling.sampler.removeWatcher()
        #expect(await sampling.sampler.hasTimer)
        await sampling.sampler.removeWatcher()
        #expect(await !sampling.sampler.hasTimer)
    }

    @Test func doesNotSampleAMachineThatStartsOrStops() async throws {
        let sampling = try Sampling(
            factory: FakeFactory(holdsStop: true) { _ in (nil, true) })
        await sampling.sampler.addWatcher()
        let starting = Task { try await sampling.start("Ubuntu-24.04") }
        try await eventually { sampling.fake("Ubuntu-24.04")?.isWaitingToStart == true }
        sampling.clock.advance(by: .seconds(3))
        await Task.megaYield()
        let fake = try #require(sampling.fake("Ubuntu-24.04"))
        #expect(fake.sampleCalls == 0)
        #expect(await !sampling.sampler.hasTimer)
        fake.finishStart()
        try await starting.value
        try await eventually { fake.sampleCalls == 1 }
        let stopping = Task {
            await sampling.registry.terminate(sampling.machine("Ubuntu-24.04"), reason: "test")
        }
        try await eventually { fake.isWaitingToStop }
        try await eventually("the timer's end") { await !sampling.sampler.hasTimer }
        sampling.clock.advance(by: .seconds(3))
        await Task.megaYield()
        #expect(fake.sampleCalls == 1)
        fake.finishStop()
        _ = await stopping.value
    }

    /// Watching takes no lease: a machine with no session stops after the idle timeout.
    @Test func doesNotKeepAMachineRunning() async throws {
        let sampling = try Sampling(idleTimeout: .seconds(3))
        try await sampling.start("Ubuntu-24.04")
        await sampling.sampler.addWatcher()
        try await eventually { sampling.fake("Ubuntu-24.04")?.sampleCalls == 1 }
        #expect(await sampling.registry.status().first?.sessionCount == 0)
        sampling.clock.advance(by: .seconds(3))
        try await eventually("the idle stop") {
            await sampling.registry.status().isEmpty
        }
        #expect(sampling.fake("Ubuntu-24.04")?.stopCalls == 1)
        try await eventually("the timer's end") { await !sampling.sampler.hasTimer }
        // Nothing starts it again.
        sampling.clock.advance(by: .seconds(15))
        await Task.megaYield()
        #expect(sampling.factory.machines.count == 1)
    }

    /// A guest that does not answer within a second leaves MEMORY empty for that sample, and
    /// is not asked again until its request ends.
    @Test func boundsTheGuestsAnswerAndKeepsOneRequestInFlight() async throws {
        let sampling = try Sampling()
        try await sampling.start("Ubuntu-24.04")
        let fake = try #require(sampling.fake("Ubuntu-24.04"))
        fake.holdSamples()
        await sampling.sampler.addWatcher()
        try await eventually { fake.sampleCalls == 1 }
        // The idle timer, the sampler's timer, and the guest request's timeout.
        try await eventually { sampling.clock.sleeperCount == 3 }
        sampling.clock.advance(by: .seconds(1))
        try await eventually("the sample without the guest's figures") {
            let figures = await sampling.figures("Ubuntu-24.04")
            return figures?.hostMemoryBytes != nil && figures?.memoryUsedBytes == nil
        }
        sampling.clock.advance(by: .milliseconds(500))
        try await eventually("the second sample") {
            await sampling.figures("Ubuntu-24.04")?.cpuPercent != nil
        }
        #expect(fake.sampleCalls == 1)
        fake.releaseSamples()
        try await sampling.settle(sleepers: 2)
        sampling.clock.advance(by: .milliseconds(1_500))
        try await eventually("a sample with the guest's figures") {
            await sampling.figures("Ubuntu-24.04")?.memoryUsedBytes == 412 << 20
        }
        #expect(fake.sampleCalls == 2)
    }

    /// `sampleFailed`, and a malformed `sampled`, which the client reports as
    /// `guestAgentFailed`, leave MEMORY empty, and the machine runs on.
    @Test func reportsAFailedSampleAsEmptyMemory() async throws {
        let sampling = try Sampling()
        try await sampling.start("Ubuntu-24.04")
        let fake = try #require(sampling.fake("Ubuntu-24.04"))
        await sampling.sampler.addWatcher()
        try await eventually {
            await sampling.figures("Ubuntu-24.04")?.memoryUsedBytes == 412 << 20
        }
        for reason in [
            "sample: /proc/meminfo has no MemAvailable",
            "sample: the frame could not be decoded",
        ] {
            fake.sampleResult.withLock { $0 = .failure(.guestAgentFailed(reason: reason)) }
            try await sampling.settle(sleepers: 2)
            sampling.clock.advance(by: .milliseconds(1_500))
            try await eventually("an empty MEMORY") {
                let figures = await sampling.figures("Ubuntu-24.04")
                return figures?.memoryUsedBytes == nil && figures?.ipv4Address == nil
                    && figures?.hostMemoryBytes != nil
            }
            #expect(await sampling.figures("Ubuntu-24.04")?.state == .running)
            fake.sampleResult.withLock { $0 = .success(FakeMachine.defaultSample) }
            try await sampling.settle(sleepers: 2)
            sampling.clock.advance(by: .milliseconds(1_500))
            try await eventually("MEMORY again") {
                await sampling.figures("Ubuntu-24.04")?.memoryUsedBytes == 412 << 20
            }
        }
        #expect(fake.stopCalls == 0)
        #expect(!sampling.lines.all.contains { $0.contains("MemAvailable") })
    }

    @Test func computesCPUFromTwoReadings() async throws {
        let sampling = try Sampling()
        try await sampling.start("Ubuntu-24.04")
        await sampling.sampler.addWatcher()
        try await eventually {
            await sampling.figures("Ubuntu-24.04")?.hostMemoryBytes != nil
        }
        #expect(await sampling.figures("Ubuntu-24.04")?.cpuPercent == nil)
        let disk = sampling.distros.store.paths.diskImage(for: try DistroName("Ubuntu-24.04"))
        let identity = try #require(FileIdentity(path: disk.path(percentEncoded: false)))
        // 750 ms of CPU time over 1.5 s is half a core.
        sampling.processes.replace(
            .init(
                id: 500, path: MachineProcessFinder.executablePath, user: getuid(),
                files: [identity], cpuNanoseconds: 500_000 + 750_000_000))
        try await sampling.settle(sleepers: 2)
        sampling.clock.advance(by: .milliseconds(1_500))
        try await eventually("the CPU figure") {
            await sampling.figures("Ubuntu-24.04")?.cpuPercent == 50
        }
    }

    /// The lookup runs at the first sample of a run, then at each sample while it finds
    /// nothing, at most 10 more times; it is logged once, and runs again for the next run.
    @Test func looksUpTheProcessAtMostElevenTimesPerRun() async throws {
        let sampling = try Sampling()
        // The machine's process has another file open, so that the lookup finds nothing.
        sampling.processes.replace(
            .init(
                id: 500, path: MachineProcessFinder.executablePath, user: getuid(),
                files: [FileIdentity(device: 1, inode: 1)]))
        try await sampling.start("Ubuntu-24.04")
        #expect(sampling.processes.openFilesRead.isEmpty)
        await sampling.sampler.addWatcher()
        for samples in 1...15 {
            try await eventually("sample \(samples)") {
                sampling.fake("Ubuntu-24.04")?.sampleCalls == samples
            }
            try await sampling.settle(sleepers: 2)
            sampling.clock.advance(by: .milliseconds(1_500))
        }
        #expect(sampling.processes.openFilesRead.count == 11)
        #expect(
            sampling.lines.count(
                containing: "Ubuntu-24.04: its virtual machine process was not found; "
                    + "CPU and host memory stay empty until it restarts") == 1)
        #expect(await sampling.figures("Ubuntu-24.04")?.cpuPercent == nil)
        let firstRun = await sampling.figures("Ubuntu-24.04")?.run
        _ = await sampling.registry.terminate(sampling.machine("Ubuntu-24.04"), reason: "test")
        try await sampling.start("Ubuntu-24.04")
        try await eventually("the next run's lookup") {
            sampling.processes.openFilesRead.count == 12
        }
        let secondRun = await sampling.figures("Ubuntu-24.04")?.run
        #expect(firstRun != nil && secondRun != nil && firstRun != secondRun)
    }

    @Test func reportsEveryDistributionInItsState() async throws {
        let sampling = try Sampling(["Alpha", "Ubuntu-24.04"])
        let kernel = sampling.distros.store.paths.kernelDirectory
        try FileManager.default.createDirectory(at: kernel, withIntermediateDirectories: true)
        for file in ["Image", "initramfs.cpio.gz"] {
            try Data().write(to: kernel.appending(path: file))
        }
        try Data(
            #"{"guestVersion":"x","gitCommit":"y","kernel":{"release":"6.18.99-next"}}"#.utf8
        ).write(to: kernel.appending(path: "manifest.json"))
        try await sampling.start("Ubuntu-24.04")
        await sampling.sampler.addWatcher()
        try await eventually {
            await sampling.figures("Ubuntu-24.04")?.memoryUsedBytes != nil
        }
        let snapshot = try #require(await sampling.sampler.snapshot(after: 0))
        #expect(snapshot.defaultDistribution?.rawValue == "Alpha")
        let alpha = try #require(snapshot.distributions.first)
        let disk = sampling.distros.store.paths.diskImage(for: alpha.name)
        var expected = DistributionFigures(
            name: alpha.name, state: .stopped, defaultUser: "ayse",
            diskImagePath: disk.path(percentEncoded: false))
        expected.diskAllocatedBytes = DiskImage.usage(disk)?.allocatedBytes
        expected.diskSizeBytes = 4096
        expected.kernelRelease = "6.18.99-next"
        #expect(alpha == expected)
        let ubuntu = try #require(snapshot.distributions.last)
        #expect(ubuntu.state == .running && ubuntu.kernelRelease == "6.18.57-maw")
        #expect(ubuntu.bootMilliseconds == 271 && ubuntu.memoryLimitBytes == 1 << 30)
        #expect(ubuntu.uptimeMilliseconds == 0 && ubuntu.run != nil)
        #expect(ubuntu.diskSizeBytes == 4096)
    }

    @Test func answersAtOnceOrWithTheNextChange() async throws {
        let sampling = try Sampling()
        let first = try #require(await sampling.sampler.snapshot(after: 0))
        #expect(first.distributions.map(\.state) == [.stopped])
        let next = Task { await sampling.sampler.snapshot(after: first.sequence) }
        await Task.megaYield()
        try await sampling.start("Ubuntu-24.04")
        let changed = try #require(await next.value)
        #expect(changed.sequence > first.sequence)
        #expect(changed.distributions.map(\.state) != [.stopped])
        // A cancelled wait ends without a snapshot.
        try await eventually { await sampling.figures("Ubuntu-24.04")?.state == .running }
        await Task.megaYield()
        let latest = try #require(await sampling.sampler.snapshot(after: 0))
        let cancelled = Task { await sampling.sampler.snapshot(after: latest.sequence) }
        await Task.megaYield()
        cancelled.cancel()
        #expect(await cancelled.value == nil)
    }
}

extension Task where Success == Never, Failure == Never {
    /// Lets other tasks run for a while, for checks that something does not happen.
    static func megaYield() async {
        for _ in 0..<50 {
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
}
