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
