import MawDaemonKit
import Testing
import os

@Suite struct DaemonLifetimeTests {
    let clock = TestClock()
    let exits = OSAllocatedUnfairLock(initialState: 0)

    func makeLifetime() -> DaemonLifetime<TestClock> {
        DaemonLifetime(clock: clock) { [exits] in exits.withLock { $0 += 1 } }
    }

    var exitCount: Int { exits.withLock { $0 } }

    @Test func exitsAfterFiveIdleMinutes() async throws {
        let lifetime = makeLifetime()
        await lifetime.begin()
        try await eventually("the timer starts") { clock.sleeperCount == 1 }

        clock.advance(by: .seconds(299))
        #expect(exitCount == 0)
        clock.advance(by: .seconds(1))
        try await eventually("the daemon exits") { exitCount == 1 }
    }

    @Test func aClientKeepsItRunning() async throws {
        let lifetime = makeLifetime()
        await lifetime.begin()
        await lifetime.clientConnected()
        try await eventually("the timer is cancelled") { clock.sleeperCount == 0 }
        clock.advance(by: .seconds(3_600))
        #expect(exitCount == 0)

        await lifetime.clientDisconnected()
        try await eventually("the timer starts") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(300))
        try await eventually("the daemon exits") { exitCount == 1 }
    }

    @Test func aRunningMachineKeepsItRunning() async throws {
        let lifetime = makeLifetime()
        await lifetime.begin()
        await lifetime.setMachinesActive(true)
        clock.advance(by: .seconds(3_600))
        #expect(exitCount == 0)
        #expect(await lifetime.isIdle == false)

        await lifetime.setMachinesActive(false)
        try await eventually("the timer starts") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(300))
        try await eventually("the daemon exits") { exitCount == 1 }
    }

    @Test func activityRestartsTheFullTimeout() async throws {
        let lifetime = makeLifetime()
        await lifetime.begin()
        try await eventually("the timer starts") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(200))
        await lifetime.clientConnected()
        await lifetime.clientDisconnected()
        try await eventually("a new timer starts") { clock.sleeperCount == 1 }

        clock.advance(by: .seconds(200))
        #expect(exitCount == 0, "The earlier 200 seconds must not count.")
        clock.advance(by: .seconds(100))
        try await eventually("the daemon exits") { exitCount == 1 }
    }

    @Test func exitsOnlyOnce() async throws {
        let lifetime = makeLifetime()
        await lifetime.begin()
        try await eventually("the timer starts") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(300))
        try await eventually("the daemon exits") { exitCount == 1 }
        await lifetime.clientConnected()
        await lifetime.clientDisconnected()
        clock.advance(by: .seconds(600))
        #expect(exitCount == 1)
    }
}
