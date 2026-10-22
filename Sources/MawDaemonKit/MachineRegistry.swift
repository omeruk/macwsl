#if os(macOS)
    import MawCore
    import MawProtocol
    import MawXPC

    /// A session's claim on a running machine. While a machine has a lease, it keeps running.
    public struct Lease: Hashable, Sendable {
        public let id: UInt64
        public let machine: MachineID
    }

    /// Owns every machine: starts it on its first session, stops it after its last, and ends
    /// its sessions when it stops.
    ///
    /// ```
    /// stopped ──openSession──▶ starting ──agent ready──▶ running ──idle / shutdown──▶ stopping
    ///    ▲                        │ fails                   │ stops unexpectedly         │
    ///    └────────────────────────┴─────────────────────────┴────────────────────────────┘
    /// ```
    ///
    /// Concurrent requests for a machine that is starting wait for that start, and requests
    /// for one that is stopping wait for the stop and then start it again, so that a machine
    /// never runs twice. Transitions happen inside the tasks that start and stop machines,
    /// before anyone waiting on those tasks resumes; code after every `await` re-reads the
    /// state, because the actor may have been re-entered.
    public actor MachineRegistry<C: Clock> where C.Duration == Duration {
        /// Called when a lease ends because its machine stopped, with the reason.
        public typealias LeaseEndHandler = @Sendable (Lease, String) -> Void

        private enum State {
            case stopped
            case starting(any MachineHandle, Task<Result<any MachineHandle, MawError>, Never>)
            case running(any MachineHandle, since: C.Instant)
            case stopping(any MachineHandle, Task<Void, Never>)

            var handle: (any MachineHandle)? {
                switch self {
                case .stopped: nil
                case .starting(let handle, _), .running(let handle, _), .stopping(let handle, _):
                    handle
                }
            }
        }

        private struct Slot {
            var state: State = .stopped
            /// Incremented for every new handle, so that events from an earlier one are ignored.
            var generation: UInt64 = 0
            var leases: [UInt64: LeaseEndHandler] = [:]
            var idleTimer: Task<Void, Never>?
        }

        private let clock: C
        private let idleTimeout: Duration
        private let factory: MachineFactory
        private let log: DaemonLog
        private let activityChanged: @Sendable (Bool) -> Void
        private var slots: [MachineID: Slot] = [:]
        private var nextLeaseID: UInt64 = 1
        /// Leases whose agent connection is being opened. If their machine stops meanwhile,
        /// the reason is kept here for `openSession` to throw, instead of calling `onEnd`.
        private var connecting: [UInt64: String?] = [:]

        /// - Parameters:
        ///   - activityChanged: Called with whether any machine is starting, running, or
        ///     stopping, whenever that may have changed.
        public init(
            clock: C, idleTimeout: Duration = DaemonTimeouts.machineIdle,
            log: DaemonLog = DaemonLog(),
            factory: @escaping MachineFactory,
            activityChanged: @escaping @Sendable (Bool) -> Void = { _ in }
        ) {
            self.clock = clock
            self.idleTimeout = idleTimeout
            self.factory = factory
            self.log = log
            self.activityChanged = activityChanged
        }

        // MARK: Sessions

        /// Starts `machine` if needed, takes a lease on it, and connects to its guest agent.
        /// `onEnd` runs if the machine stops while the lease is held.
        public func openSession(
            on machine: MachineID, onEnd: @escaping LeaseEndHandler
        ) async throws(MawError) -> (Lease, OwnedDescriptor) {
            while true {
                switch slots[machine, default: Slot()].state {
                case .stopped:
                    try beginStart(machine)
                case .starting(_, let task):
                    if case .failure(let error) = await task.value {
                        throw error
                    }
                case .stopping(_, let task):
                    await task.value
                case .running(let handle, _):
                    // The lease comes first, so that the idle timer cannot stop the machine
                    // while the connection is being made.
                    let lease = addLease(on: machine, onEnd: onEnd)
                    connecting[lease.id] = .some(nil)
                    let result: Result<OwnedDescriptor, MawError>
                    do throws(MawError) {
                        result = .success(try await handle.connectToAgent())
                    } catch {
                        result = .failure(error)
                    }
                    if case .some(.some(let reason)) = connecting.removeValue(forKey: lease.id) {
                        // The machine stopped while the connection was being made.
                        throw .machineStopped(machine: machine.name, reason: reason)
                    }
                    switch result {
                    case .success(let descriptor):
                        return (lease, descriptor)
                    case .failure(let error):
                        release(lease)
                        throw error
                    }
                }
            }
        }

        /// Ends a lease. Releasing the last one starts the idle timer. Releasing a lease that
        /// has already ended does nothing.
        public func release(_ lease: Lease) {
            guard slots[lease.machine]?.leases.removeValue(forKey: lease.id) != nil else {
                return
            }
            scheduleIdleStopIfUnused(lease.machine)
        }

        private func addLease(on machine: MachineID, onEnd: @escaping LeaseEndHandler) -> Lease {
            let lease = Lease(id: nextLeaseID, machine: machine)
            nextLeaseID += 1
            slots[machine]?.leases[lease.id] = onEnd
            slots[machine]?.idleTimer?.cancel()
            slots[machine]?.idleTimer = nil
            return lease
        }

        // MARK: Starting

        private func beginStart(_ machine: MachineID) throws(MawError) {
            let handle = try factory(machine)
            var slot = slots[machine, default: Slot()]
            slot.generation += 1
            let generation = slot.generation
            log.notice("\(machine): starting")
            let started = clock.now
            slot.state = .starting(
                handle,
                Task {
                    let result: Result<any MachineHandle, MawError>
                    do throws(MawError) {
                        try await handle.start()
                        result = .success(handle)
                    } catch {
                        result = .failure(error)
                    }
                    didFinishStart(machine, generation: generation, result, since: started)
                    return result
                })
            slots[machine] = slot
            activityChanged(true)
        }

        private func didFinishStart(
            _ machine: MachineID, generation: UInt64, _ result: Result<any MachineHandle, MawError>,
            since started: C.Instant
        ) {
            guard slots[machine]?.generation == generation else { return }
            switch result {
            case .success(let handle):
                let elapsed = started.duration(to: clock.now)
                log.notice("\(machine): running after \(elapsed.milliseconds) ms")
                slots[machine]?.state = .running(handle, since: clock.now)
                Task { [weak self] in
                    for await reason in handle.unexpectedStops {
                        await self?.didStopUnexpectedly(
                            machine, generation: generation, reason: reason)
                        return
                    }
                }
                // A start that nobody uses, because its requester failed or left, still stops.
                scheduleIdleStopIfUnused(machine)
            case .failure(let error):
                log.error("\(machine): failed to start: \(error.description)")
                slots[machine]?.state = .stopped
                reportActivity()
            }
        }

        // MARK: Stopping

        private func didStopUnexpectedly(_ machine: MachineID, generation: UInt64, reason: String) {
            guard var slot = slots[machine], slot.generation == generation,
                case .running = slot.state
            else { return }
            log.error("\(machine): stopped unexpectedly: \(reason)")
            slot.state = .stopped
            slot.idleTimer?.cancel()
            slot.idleTimer = nil
            let ended = slot.leases
            slot.leases = [:]
            slots[machine] = slot
            end(ended, on: machine, reason: reason)
            reportActivity()
        }

        /// Calls each lease's end handler, except for leases still connecting, which
        /// `openSession` fails instead.
        private func end(
            _ leases: [UInt64: LeaseEndHandler], on machine: MachineID, reason: String
        ) {
            for (id, onEnd) in leases {
                if connecting[id] != nil {
                    connecting[id] = .some(reason)
                } else {
                    onEnd(Lease(id: id, machine: machine), reason)
                }
            }
        }

        private func scheduleIdleStopIfUnused(_ machine: MachineID) {
            guard var slot = slots[machine], slot.leases.isEmpty, case .running = slot.state
            else { return }
            slot.idleTimer?.cancel()
            let generation = slot.generation
            let timeout = idleTimeout
            slot.idleTimer = Task { [clock] in
                do {
                    try await clock.sleep(for: timeout)
                } catch {
                    return
                }
                await idleTimerFired(machine, generation: generation)
            }
            slots[machine] = slot
        }

        private func idleTimerFired(_ machine: MachineID, generation: UInt64) async {
            guard let slot = slots[machine], slot.generation == generation, slot.leases.isEmpty,
                case .running = slot.state
            else { return }
            slots[machine]?.idleTimer = nil
            log.notice("\(machine): no session for \(idleTimeout.milliseconds / 1000) s")
            _ = await stop(machine, reason: "it was idle")
        }

        /// Stops a machine, waiting first for a start in progress. Ends its leases with
        /// `reason`, and returns how many there were, or `nil` if it was not running.
        private func stop(_ machine: MachineID, reason: String) async -> Int? {
            while true {
                guard var slot = slots[machine] else { return nil }
                switch slot.state {
                case .stopped:
                    return nil
                case .starting(_, let task):
                    _ = await task.value
                case .stopping(_, let task):
                    await task.value
                    return nil
                case .running(let handle, _):
                    slot.idleTimer?.cancel()
                    slot.idleTimer = nil
                    let ended = slot.leases
                    slot.leases = [:]
                    let generation = slot.generation
                    let task = Task {
                        let outcome = await handle.stop()
                        log.notice("\(machine): stopped because \(reason); \(outcome)")
                        didFinishStop(machine, generation: generation)
                    }
                    slot.state = .stopping(handle, task)
                    slots[machine] = slot
                    end(ended, on: machine, reason: reason)
                    await task.value
                    return ended.count
                }
            }
        }

        private func didFinishStop(_ machine: MachineID, generation: UInt64) {
            guard slots[machine]?.generation == generation else { return }
            slots[machine]?.state = .stopped
            reportActivity()
        }

        /// Stops every machine and ends every session with `reason`.
        public func shutdown(reason: String) async -> ShutdownSummary {
            var stopped: [MachineID] = []
            var endedSessions = 0
            for machine in slots.keys.sorted(by: { $0.name < $1.name }) {
                if let ended = await stop(machine, reason: reason) {
                    stopped.append(machine)
                    endedSessions += ended
                }
            }
            return ShutdownSummary(stoppedMachines: stopped, endedSessions: endedSessions)
        }

        // MARK: Status

        /// Every machine that is not stopped, by name.
        public func status() -> [MachineStatus] {
            slots.compactMap { machine, slot -> MachineStatus? in
                let state: MachineStatus.State
                var uptime: UInt64?
                switch slot.state {
                case .stopped:
                    return nil
                case .starting:
                    state = .starting
                case .running(_, let since):
                    state = .running
                    uptime = UInt64(max(0, since.duration(to: clock.now).milliseconds))
                case .stopping:
                    state = .stopping
                }
                let handle = slot.state.handle
                return MachineStatus(
                    machine: machine, state: state, uptimeMilliseconds: uptime,
                    cpuCount: handle?.cpuCount ?? 0, memoryBytes: handle?.memoryBytes ?? 0,
                    sessionCount: slot.leases.count)
            }
            .sorted { $0.machine.name < $1.machine.name }
        }

        /// Whether any machine is starting, running, or stopping.
        public var isActive: Bool {
            slots.values.contains {
                if case .stopped = $0.state { false } else { true }
            }
        }

        private func reportActivity() {
            activityChanged(isActive)
        }
    }
#endif
