#if os(macOS)
    import Darwin
    import Foundation
    import MawCore
    import MawProtocol
    import MawVirtualization
    import MawXPC
    import os

    /// Samples the running distributions while at least one client watches them, and answers
    /// `watchDistributions` with snapshots (docs/daemon.md, "Watching the distributions").
    ///
    /// It reads only machines that the registry reports running: it never starts a machine,
    /// takes no lease, and never touches the idle timer. Its timer exists only while a client
    /// watches and a distribution runs. Each sample asks the guest for `sample` and reads the
    /// machine's process on the Mac, which it looks up at the run's first sample.
    public actor FigureSampler<C: Clock> where C.Duration == Duration {
        public static var defaultInterval: Duration { .milliseconds(1500) }
        /// The longest a sample waits for the guest's reply, connection included.
        public static var guestTimeout: Duration { .seconds(1) }

        struct Figures: Equatable {
            var memoryUsedBytes: UInt64?
            var ipv4Address: String?
            var cpuPercent: Double?
            var hostMemoryBytes: UInt64?
            var sampleMicroseconds: UInt64?
        }

        /// One run of one distribution's machine.
        struct Run {
            let id: UInt64
            let handle: any MachineHandle
            var lookup = MachineProcessLookup()
            var figures = Figures()
            /// The samples published since the first watcher arrived, failed ones included, so
            /// that a client can tell each sample from the snapshots that other changes publish.
            var samples: UInt64 = 0
            /// The CPU time at the previous sample, for the next one's difference.
            var cpu: (nanoseconds: UInt64, at: C.Instant)?
            /// Whether it was sampled since watching started.
            var hasSampled = false
            var isSampling = false
            /// Whether a `sample` request is in flight, possibly past its timeout.
            var isAskingGuest = false
        }

        private let clock: C
        private let interval: Duration
        private let registry: MachineRegistry<C>
        private let store: DistributionStore?
        private let processes: any ProcessTable
        private let log: DaemonLog
        private var watchers = 0
        private var runs: [DistroName: Run] = [:]
        private var timer: Task<Void, Never>?
        private var refreshes: UInt64 = 0
        private var sequence: UInt64 = 1
        private var cached: DistributionSnapshot?
        private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]

        public init(
            clock: C, registry: MachineRegistry<C>, store: DistributionStore?,
            processes: any ProcessTable = DarwinProcessTable(),
            interval: Duration = defaultInterval, log: DaemonLog = DaemonLog()
        ) {
            self.clock = clock
            self.interval = interval
            self.registry = registry
            self.store = store
            self.processes = processes
            self.log = log
        }

        /// Whether the timer runs, and whether a sample or a guest request is in progress, for
        /// the tests.
        var hasTimer: Bool { timer != nil }
        var isBusy: Bool { runs.values.contains { $0.isSampling || $0.isAskingGuest } }

        // MARK: Watchers and changes

        /// The first watcher samples every running distribution at once and starts the timer.
        public func addWatcher() async {
            watchers += 1
            if watchers == 1 {
                await refresh()
            }
        }

        /// The last watcher's end stops the timer and forgets the figures, so that a later
        /// watch never reports CPU over the time nobody watched. A run keeps its process.
        public func removeWatcher() {
            watchers = max(0, watchers - 1)
            guard watchers == 0 else { return }
            for name in runs.keys {
                runs[name]?.figures = Figures()
                runs[name]?.cpu = nil
                runs[name]?.samples = 0
                runs[name]?.hasSampled = false
            }
            changed()
            updateTimer()
        }

        /// Called after a machine's state changes: samples a machine that now runs at once if
        /// watched, and wakes the waiting watchers.
        public func machinesChanged() async {
            await refresh()
            changed()
        }

        /// Called after a distribution is installed or the default changes.
        public func distributionsChanged() {
            changed()
        }

        private func refresh() async {
            refreshes += 1
            let ticket = refreshes
            let running = await registry.machines()
            // A later refresh read the registry after this one, and applies its own reading.
            guard ticket == refreshes else { return }
            var current: [DistroName: Run] = [:]
            for machine in running where machine.status.state == .running {
                guard case .distribution(let name) = machine.status.machine else { continue }
                current[name] =
                    runs[name]?.id == machine.run
                    ? runs[name] : Run(id: machine.run, handle: machine.handle)
            }
            runs = current
            if watchers > 0 {
                for (name, run) in runs where !run.hasSampled {
                    sample(name)
                }
            }
            updateTimer()
        }

        private func updateTimer() {
            guard watchers > 0, !runs.isEmpty else {
                timer?.cancel()
                timer = nil
                return
            }
            guard timer == nil else { return }
            timer = Task { [clock, interval] in
                while true {
                    do {
                        try await clock.sleep(for: interval)
                    } catch {
                        return
                    }
                    self.tick()
                }
            }
        }

        /// Samples every running distribution; internal for the tests. The timer may have woken
        /// just before the last watcher left and cancelled it; then it samples nothing.
        func tick() {
            guard watchers > 0 else { return }
            for name in runs.keys {
                sample(name)
            }
        }

        private func changed() {
            sequence += 1
            cached = nil
            for continuation in waiting.values {
                continuation.resume()
            }
            waiting = [:]
        }

        // MARK: Sampling

        /// Starts one sample of `name`, unless one is in progress. The guest is asked only if
        /// no earlier request of this run is still in flight.
        private func sample(_ name: DistroName) {
            guard var run = runs[name], !run.isSampling else { return }
            run.isSampling = true
            run.hasSampled = true
            let askGuest = !run.isAskingGuest
            run.isAskingGuest = true
            runs[name] = run
            let (id, handle, lookup) = (run.id, run.handle, run.lookup)
            let disk = store?.paths.diskImage(for: name)
            Task {
                async let guest = askGuest ? self.askGuest(handle, name: name, run: id) : nil
                let host = await readHost(lookup, disk: disk)
                let answer = await guest
                finish(name, run: id, host: host, guest: answer)
            }
        }

        struct Host: Sendable {
            var lookup: MachineProcessLookup
            var outcome: MachineProcessLookup.Outcome
            var usage: ProcessUsage?
            var at: C.Instant
        }

        /// Looks up the machine's process if needed and reads its usage, off the actor, because
        /// a lookup takes milliseconds.
        private nonisolated func readHost(_ lookup: MachineProcessLookup, disk: URL?) async -> Host
        {
            var lookup = lookup
            let outcome = lookup.next {
                guard let disk, let identity = FileIdentity(path: disk.path(percentEncoded: false))
                else { return nil }
                return MachineProcessFinder.find(diskImage: identity, user: getuid(), in: processes)
            }
            var usage: ProcessUsage?
            if case .found(let process) = outcome {
                usage = MachineProcessFinder.usage(of: process, in: processes)
            }
            return Host(lookup: lookup, outcome: outcome, usage: usage, at: clock.now)
        }

        /// The guest's sample with its time in microseconds, or `nil` if it fails, is malformed,
        /// or takes longer than `guestTimeout`. A request past its timeout goes on until the
        /// handle gives up; `isAskingGuest` stays set until then, so that no second one starts.
        private nonisolated func askGuest(
            _ handle: any MachineHandle, name: DistroName, run: UInt64
        ) async -> (GuestSample, UInt64)? {
            let first = FirstResult<(GuestSample, UInt64)?>()
            return await withCheckedContinuation { continuation in
                first.wait(continuation)
                let timeout = Task { [clock] in
                    try? await clock.sleep(for: Self.guestTimeout)
                    first.resume(nil)
                }
                Task { [clock] in
                    let started = clock.now
                    let sample = try? await handle.sample()
                    let elapsed = started.duration(to: clock.now).components
                    let microseconds =
                        UInt64(max(0, elapsed.seconds)) * 1_000_000
                        + UInt64(max(0, elapsed.attoseconds)) / 1_000_000_000_000
                    // The answer first: the cancelled timeout task resumes with nil, which
                    // must find the answer already taken.
                    first.resume(sample.map { ($0, microseconds) })
                    timeout.cancel()
                    await self.guestAnswered(name, run: run)
                }
            }
        }

        private func guestAnswered(_ name: DistroName, run: UInt64) {
            guard runs[name]?.id == run else { return }
            runs[name]?.isAskingGuest = false
        }

        private func finish(
            _ name: DistroName, run id: UInt64, host: Host, guest: (GuestSample, UInt64)?
        ) {
            guard var run = runs[name], run.id == id else { return }
            run.isSampling = false
            run.lookup = host.lookup
            if host.outcome == .gaveUp {
                log.notice(
                    "\(MachineID.distribution(name)): its virtual machine process was not found; "
                        + "CPU and host memory stay empty until it restarts")
            }
            // The figures of a watch that has ended are not kept, and the next watch samples
            // at once.
            guard watchers > 0 else {
                run.hasSampled = false
                runs[name] = run
                return
            }
            var figures = Figures()
            // The decoder rejects more available memory than total; a sample from elsewhere
            // that has it is not used, rather than subtracted.
            if let guest, guest.0.memoryAvailableBytes <= guest.0.memoryTotalBytes {
                figures.memoryUsedBytes = guest.0.memoryUsedBytes
                figures.ipv4Address = guest.0.ipv4Address
                figures.sampleMicroseconds = guest.1
            }
            if let usage = host.usage {
                figures.hostMemoryBytes = usage.footprintBytes
                if let previous = run.cpu, usage.cpuNanoseconds >= previous.nanoseconds {
                    let (seconds, attoseconds) = previous.at.duration(to: host.at).components
                    let elapsed = Double(seconds) + Double(attoseconds) / 1e18
                    if elapsed > 0 {
                        figures.cpuPercent =
                            Double(usage.cpuNanoseconds - previous.nanoseconds) / elapsed / 1e7
                    }
                }
                run.cpu = (usage.cpuNanoseconds, host.at)
            } else {
                run.cpu = nil
            }
            run.figures = figures
            run.samples += 1
            runs[name] = run
            changed()
        }

        // MARK: Snapshots

        /// The first snapshot whose sequence is greater than `after`, once it exists, or `nil`
        /// if the task is cancelled first.
        public func snapshot(after: UInt64) async -> DistributionSnapshot? {
            while sequence <= after {
                guard !Task.isCancelled else { return nil }
                let id = UUID()
                await withTaskCancellationHandler {
                    await withCheckedContinuation { waiting[id] = $0 }
                } onCancel: {
                    Task { await self.stopWaiting(id) }
                }
            }
            if let cached, cached.sequence == sequence {
                return cached
            }
            let current = sequence
            let machines = await registry.machines()
            let snapshot = DistributionSnapshot(
                sequence: current, distributions: figures(machines),
                defaultDistribution: store?.defaultDistribution())
            if sequence == current {
                cached = snapshot
            }
            return snapshot
        }

        private func stopWaiting(_ id: UUID) {
            waiting.removeValue(forKey: id)?.resume()
        }

        private func figures(_ machines: [RegisteredMachine]) -> [DistributionFigures] {
            guard let store else { return [] }
            var registered: [DistroName: RegisteredMachine] = [:]
            for machine in machines {
                if case .distribution(let name) = machine.status.machine {
                    registered[name] = machine
                }
            }
            let nextKernel = (try? GuestFiles(directory: store.paths.kernelDirectory))?
                .manifest?.kernel.release
            return store.installed().map { metadata in
                let name = metadata.name
                let disk = store.paths.diskImage(for: name)
                var entry = DistributionFigures(
                    name: name, state: DistributionState(registered[name]?.status.state),
                    defaultUser: metadata.defaultUser,
                    diskImagePath: disk.path(percentEncoded: false))
                let usage = DiskImage.usage(disk)
                entry.diskAllocatedBytes = usage?.allocatedBytes
                entry.diskSizeBytes = usage?.sizeBytes
                entry.kernelRelease = nextKernel
                guard let machine = registered[name], machine.status.state == .running else {
                    return entry
                }
                entry.kernelRelease = machine.handle.kernelRelease
                entry.run = machine.run
                entry.uptimeMilliseconds = machine.status.uptimeMilliseconds
                entry.bootMilliseconds = machine.handle.bootMilliseconds
                entry.memoryLimitBytes = machine.handle.memoryBytes
                if let run = runs[name], run.id == machine.run {
                    entry.memoryUsedBytes = run.figures.memoryUsedBytes
                    entry.ipv4Address = run.figures.ipv4Address
                    entry.cpuPercent = run.figures.cpuPercent
                    entry.hostMemoryBytes = run.figures.hostMemoryBytes
                    entry.lastSampleMicroseconds = run.figures.sampleMicroseconds
                    entry.sampleNumber = run.samples > 0 ? run.samples : nil
                }
                return entry
            }
        }
    }

    extension DistributionState {
        /// The state of a machine that the registry lists, or `stopped` if it lists none.
        init(_ state: MachineStatus.State?) {
            self =
                switch state {
                case nil: .stopped
                case .starting: .starting
                case .running: .running
                case .stopping: .stopping
                }
        }
    }

    /// A continuation that the first of several tasks resumes.
    final class FirstResult<Value: Sendable>: Sendable {
        private let continuation = OSAllocatedUnfairLock<CheckedContinuation<Value, Never>?>(
            initialState: nil)

        func wait(_ continuation: CheckedContinuation<Value, Never>) {
            self.continuation.withLock { $0 = continuation }
        }

        func resume(_ value: Value) {
            continuation.withLock { stored in
                defer { stored = nil }
                return stored
            }?.resume(returning: value)
        }
    }
#endif
