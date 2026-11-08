import MawCore
import MawDaemonKit
import MawProtocol
import MawXPC
import Testing
import os

@Suite struct MachineRegistryTests {
    let clock = TestClock()

    func makeRegistry(_ factory: FakeFactory) -> MachineRegistry<TestClock> {
        MachineRegistry(clock: clock, factory: factory.factory)
    }

    @Test func startsAMachineOnItsFirstSession() async throws {
        let factory = FakeFactory()
        let registry = makeRegistry(factory)

        let (lease, descriptor) = try await registry.openSession(on: .initramfs) { _, _ in }
        #expect(lease.machine == .initramfs)
        #expect(descriptor.rawValue >= 0)
        #expect(factory.machines.count == 1)
        #expect(factory.machines[0].startCalls == 1)
        let status = await registry.status()
        #expect(status.map(\.state) == [.running])
        #expect(status.first?.sessionCount == 1)
        #expect(status.first?.cpuCount == 2)
    }

    @Test func concurrentRequestsShareOneStart() async throws {
        let factory = FakeFactory { _ in (nil, true) }
        let registry = makeRegistry(factory)

        let sessions = (0..<10).map { _ in
            Task { try await registry.openSession(on: .initramfs) { _, _ in }.0 }
        }
        try await eventually("the machine waits to start") {
            factory.machines.first?.isWaitingToStart == true
        }
        #expect(await registry.status().map(\.state) == [.starting])
        factory.machines[0].finishStart()

        var leases: Set<Lease> = []
        for session in sessions {
            leases.insert(try await session.value)
        }
        #expect(leases.count == 10)
        #expect(factory.machines.count == 1, "A second virtual machine was started.")
        #expect(factory.machines[0].startCalls == 1)
        #expect(await registry.status().first?.sessionCount == 10)
    }

    @Test func stopsTheMachineAMinuteAfterTheLastSession() async throws {
        let factory = FakeFactory()
        let registry = makeRegistry(factory)
        let (first, _) = try await registry.openSession(on: .initramfs) { _, _ in }
        let (second, _) = try await registry.openSession(on: .initramfs) { _, _ in }

        await registry.release(first)
        #expect(clock.sleeperCount == 0, "A session is still open; no timer may run.")
        await registry.release(second)
        try await eventually("the idle timer starts") { clock.sleeperCount == 1 }

        clock.advance(by: .seconds(59))
        #expect(factory.machines[0].stopCalls == 0)
        clock.advance(by: .seconds(1))
        try await eventually("the machine stops") { await registry.status().isEmpty }
        #expect(factory.machines[0].stopCalls == 1)
    }

    @Test func aNewSessionCancelsTheIdleTimer() async throws {
        let factory = FakeFactory()
        let registry = makeRegistry(factory)
        let (first, _) = try await registry.openSession(on: .initramfs) { _, _ in }
        await registry.release(first)
        try await eventually("the idle timer starts") { clock.sleeperCount == 1 }

        clock.advance(by: .seconds(30))
        _ = try await registry.openSession(on: .initramfs) { _, _ in }
        try await eventually("the idle timer is cancelled") { clock.sleeperCount == 0 }

        clock.advance(by: .seconds(120))
        #expect(factory.machines[0].stopCalls == 0)
        #expect(factory.machines.count == 1)
        #expect(await registry.status().first?.state == .running)
    }

    @Test func releasingALeaseTwiceHasNoEffect() async throws {
        let factory = FakeFactory()
        let registry = makeRegistry(factory)
        let (first, _) = try await registry.openSession(on: .initramfs) { _, _ in }
        _ = try await registry.openSession(on: .initramfs) { _, _ in }

        await registry.release(first)
        await registry.release(first)
        #expect(await registry.status().first?.sessionCount == 1)
        #expect(clock.sleeperCount == 0)
    }

    @Test func aFailedMachineEndsItsSessionsAndStartsAgain() async throws {
        let factory = FakeFactory()
        let registry = makeRegistry(factory)
        let ended = EndedLeases()
        let (lease, _) = try await registry.openSession(on: .initramfs, onEnd: ended.handler)

        factory.machines[0].crash("the guest kernel panicked")
        try await eventually("the session ends") { ended.all.count == 1 }
        #expect(ended.all.first?.0 == lease)
        #expect(ended.all.first?.1 == "the guest kernel panicked")
        #expect(await registry.status().isEmpty)

        // The next session starts a new machine.
        _ = try await registry.openSession(on: .initramfs) { _, _ in }
        #expect(factory.machines.count == 2)
        #expect(factory.machines[1].startCalls == 1)
        #expect(await registry.status().first?.sessionCount == 1)

        // The old lease is gone; releasing it does not touch the new machine.
        await registry.release(lease)
        #expect(await registry.status().first?.sessionCount == 1)
    }

    @Test func aStartThatFailsReachesEveryWaiterAndIsRetriedNextTime() async throws {
        let factory = FakeFactory { index in
            (index == 0 ? MawError.vmStartFailed(reason: "test") : nil, index == 0)
        }
        let registry = makeRegistry(factory)
        let waiters = (0..<3).map { _ in
            Task { () async -> MawError? in
                do {
                    _ = try await registry.openSession(on: .initramfs) { _, _ in }
                    return nil
                } catch {
                    return error as? MawError
                }
            }
        }
        try await eventually("the machine waits to start") {
            factory.machines.first?.isWaitingToStart == true
        }
        factory.machines[0].finishStart()
        for waiter in waiters {
            #expect(await waiter.value == .vmStartFailed(reason: "test"))
        }
        #expect(await registry.status().isEmpty)
        #expect(await registry.isActive == false)

        _ = try await registry.openSession(on: .initramfs) { _, _ in }
        #expect(factory.machines.count == 2)
    }

    @Test func aFactoryErrorReachesTheCaller() async throws {
        let registry = MachineRegistry(clock: clock) {
            (machine: MachineID) throws(MawError) -> any MachineHandle in
            throw .kernelNotFound(path: "/nowhere/Image")
        }
        await #expect(throws: MawError.kernelNotFound(path: "/nowhere/Image")) {
            try await registry.openSession(on: .initramfs) { _, _ in }
        }
        #expect(await registry.isActive == false)
    }

    @Test func shutdownStopsEveryMachineAndEndsItsSessions() async throws {
        let factory = FakeFactory()
        let registry = makeRegistry(factory)
        let ended = EndedLeases()
        _ = try await registry.openSession(on: .initramfs, onEnd: ended.handler)
        _ = try await registry.openSession(on: .initramfs, onEnd: ended.handler)
        let debian = MachineID.distribution(try DistroName("Debian"))
        _ = try await registry.openSession(on: debian, onEnd: ended.handler)

        let summary = await registry.shutdown(reason: "maw --shutdown was run")
        #expect(summary.stoppedMachines == [debian, .initramfs])
        #expect(summary.endedSessions == 3)
        #expect(ended.all.count == 3)
        #expect(ended.all.allSatisfy { $0.1 == "maw --shutdown was run" })
        #expect(factory.machines.allSatisfy { $0.stopCalls == 1 })
        #expect(await registry.status().isEmpty)
    }

    @Test func shutdownWithNothingRunningStopsNothing() async {
        let registry = makeRegistry(FakeFactory())
        let summary = await registry.shutdown(reason: "test")
        #expect(summary == ShutdownSummary(stoppedMachines: [], endedSessions: 0))
    }

    @Test func shutdownDuringAStartWaitsAndThenStops() async throws {
        let factory = FakeFactory { index in (nil, index == 0) }
        let registry = makeRegistry(factory)
        let ended = EndedLeases()
        let session = Task { try await registry.openSession(on: .initramfs, onEnd: ended.handler) }
        try await eventually("the machine waits to start") {
            factory.machines.first?.isWaitingToStart == true
        }

        let shutdown = Task { await registry.shutdown(reason: "maw --shutdown was run") }
        factory.machines[0].finishStart()
        let summary = await shutdown.value
        #expect(summary.stoppedMachines == [.initramfs])
        #expect(factory.machines[0].stopCalls == 1)

        // The session that was waiting for the start ends in one of three ways, depending on
        // the interleaving: it opened before the shutdown and its lease ended; the shutdown
        // stopped the machine while it connected, which it reports; or it found the machine
        // stopped and started a new one.
        let outcome: String
        do {
            _ = try await session.value
            outcome = ended.all.count == 1 ? "ended" : "restarted"
        } catch let error as MawError {
            #expect(
                error == .machineStopped(machine: "initramfs", reason: "maw --shutdown was run"))
            outcome = "failed"
        }
        #expect(ended.all.count == (outcome == "ended" ? 1 : 0))
        #expect(factory.machines.count == (outcome == "restarted" ? 2 : 1))
    }

    // MARK: Terminate

    static let reason = "maw --terminate was run"

    /// Gives a request that a test has just sent time to reach the registry. No expectation may
    /// depend on whether it has, because nothing shows it.
    func settle() async throws {
        for _ in 0..<10 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func terminateStopsOneMachineAndEndsItsSessionsWithTheReason() async throws {
        let factory = FakeFactory()
        let registry = makeRegistry(factory)
        let ended = EndedLeases()
        let debian = MachineID.distribution(try DistroName("Debian"))
        let ubuntu = MachineID.distribution(try DistroName("Ubuntu-24.04"))
        let (first, _) = try await registry.openSession(on: debian, onEnd: ended.handler)
        let (second, _) = try await registry.openSession(on: debian, onEnd: ended.handler)
        _ = try await registry.openSession(on: ubuntu, onEnd: ended.handler)
        let debianMachine = try #require(factory.machines.first { $0.machine == debian })
        let ubuntuMachine = try #require(factory.machines.first { $0.machine == ubuntu })

        let summary = await registry.terminate(debian, reason: Self.reason)
        #expect(summary == TerminateSummary(wasRunning: true, endedSessions: 2))
        #expect(Set(ended.all.map(\.0)) == [first, second])
        #expect(ended.all.allSatisfy { $0.1 == Self.reason })
        #expect(debianMachine.stopCalls == 1)

        // The other machine keeps running with its session.
        #expect(ubuntuMachine.stopCalls == 0)
        let status = await registry.status()
        #expect(status.map(\.machine) == [ubuntu])
        #expect(status.first?.state == .running)
        #expect(status.first?.sessionCount == 1)

        // The next session starts the machine again.
        _ = try await registry.openSession(on: debian) { _, _ in }
        #expect(factory.machines.filter { $0.machine == debian }.count == 2)
    }

    @Test func terminateCancelsTheIdleTimer() async throws {
        let factory = FakeFactory()
        let registry = makeRegistry(factory)
        let (lease, _) = try await registry.openSession(on: .initramfs) { _, _ in }
        await registry.release(lease)
        try await eventually("the idle timer starts") { clock.sleeperCount == 1 }

        let summary = await registry.terminate(.initramfs, reason: Self.reason)
        #expect(summary == TerminateSummary(wasRunning: true, endedSessions: 0))
        try await eventually("the idle timer is cancelled") { clock.sleeperCount == 0 }
        clock.advance(by: .seconds(60))
        #expect(factory.machines[0].stopCalls == 1)
    }

    @Test func terminateOfAStoppedMachineStartsNothing() async throws {
        let factory = FakeFactory()
        let registry = makeRegistry(factory)
        let debian = MachineID.distribution(try DistroName("Debian"))

        // A machine that never ran.
        #expect(
            await registry.terminate(debian, reason: Self.reason)
                == TerminateSummary(wasRunning: false, endedSessions: 0))
        #expect(factory.machines.isEmpty)

        // A machine that ran and stopped after its idle timeout.
        let (lease, _) = try await registry.openSession(on: debian) { _, _ in }
        await registry.release(lease)
        try await eventually("the idle timer starts") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(60))
        try await eventually("the machine stops") { await registry.status().isEmpty }
        #expect(
            await registry.terminate(debian, reason: Self.reason)
                == TerminateSummary(wasRunning: false, endedSessions: 0))
        #expect(factory.machines.count == 1)
        #expect(factory.machines[0].stopCalls == 1)
        #expect(await registry.isActive == false)
    }

    /// The start finishes, and then the machine stops. The only other request waits for the
    /// start and is not a session; how it ends depends on which of the two resumes first, and
    /// no expectation depends on that.
    @Test func terminateDuringAStartWaitsAndThenStops() async throws {
        let factory = FakeFactory { index in (nil, index == 0) }
        let registry = makeRegistry(factory)
        let debian = MachineID.distribution(try DistroName("Debian"))
        let starter = Task { try await registry.start(debian) }
        try await eventually("the machine waits to start") {
            factory.machines.first?.isWaitingToStart == true
        }

        let terminate = Task { await registry.terminate(debian, reason: Self.reason) }
        try await settle()
        #expect(await registry.status().map(\.state) == [.starting])
        #expect(factory.machines[0].stopCalls == 0)
        factory.machines[0].finishStart()

        #expect(await terminate.value == TerminateSummary(wasRunning: true, endedSessions: 0))
        #expect(factory.machines[0].startCalls == 1)
        #expect(factory.machines[0].stopCalls == 1)
        try await starter.value
    }

    @Test func terminateOfAMachineWhoseStartFailsSucceeds() async throws {
        let factory = FakeFactory { index in
            (index == 0 ? MawError.vmStartFailed(reason: "test") : nil, index == 0)
        }
        let registry = makeRegistry(factory)
        let debian = MachineID.distribution(try DistroName("Debian"))
        let starter = Task { () async -> MawError? in
            do throws(MawError) {
                try await registry.start(debian)
                return nil
            } catch {
                return error
            }
        }
        try await eventually("the machine waits to start") {
            factory.machines.first?.isWaitingToStart == true
        }

        let terminate = Task { await registry.terminate(debian, reason: Self.reason) }
        try await settle()
        factory.machines[0].finishStart()
        #expect(await terminate.value == TerminateSummary(wasRunning: false, endedSessions: 0))
        #expect(factory.machines[0].stopCalls == 0)
        #expect(await starter.value == .vmStartFailed(reason: "test"))
        #expect(await registry.status().isEmpty)
    }

    @Test func terminateDuringAStopWaitsForIt() async throws {
        let factory = FakeFactory(holdsStop: true)
        let registry = makeRegistry(factory)
        let ended = EndedLeases()
        let debian = MachineID.distribution(try DistroName("Debian"))
        _ = try await registry.openSession(on: debian, onEnd: ended.handler)

        let first = Task { await registry.terminate(debian, reason: Self.reason) }
        try await eventually("the machine waits to stop") {
            factory.machines.first?.isWaitingToStop == true
        }
        #expect(await registry.status().map(\.state) == [.stopping])

        let second = Task { await registry.terminate(debian, reason: Self.reason) }
        // Its result is the same if it arrives only after the stop.
        try await settle()
        #expect(await registry.status().map(\.state) == [.stopping])
        factory.machines[0].finishStop()

        #expect(await first.value == TerminateSummary(wasRunning: true, endedSessions: 1))
        #expect(await second.value == TerminateSummary(wasRunning: false, endedSessions: 0))
        #expect(factory.machines.count == 1)
        #expect(factory.machines[0].stopCalls == 1)
        #expect(ended.all.count == 1)
        #expect(await registry.status().isEmpty)
    }

    @Test func reportsActivityChanges() async throws {
        let changes = ActivityLog()
        let factory = FakeFactory()
        let registry = MachineRegistry(
            clock: clock, factory: factory.factory, activityChanged: changes.record)
        let (lease, _) = try await registry.openSession(on: .initramfs) { _, _ in }
        #expect(changes.values.last == true)
        await registry.release(lease)
        try await eventually("the idle timer starts") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(60))
        try await eventually("activity ends") { changes.values.last == false }
    }

    @Test func reportsUptime() async throws {
        let registry = makeRegistry(FakeFactory())
        _ = try await registry.openSession(on: .initramfs) { _, _ in }
        clock.advance(by: .milliseconds(1_500))
        #expect(await registry.status().first?.uptimeMilliseconds == 1_500)
    }
}

/// Records the values passed to `activityChanged`.
final class ActivityLog: Sendable {
    private let log = OSAllocatedUnfairLock(initialState: [Bool]())

    var values: [Bool] { log.withLock { $0 } }

    var record: @Sendable (Bool) -> Void {
        { [log] active in log.withLock { $0.append(active) } }
    }
}
