import Foundation
import MawCore
import MawProtocol
import Testing

@testable import MawXPC

/// `Launchctl.run`, with programs other than launchctl standing in for it.
@Suite struct LaunchctlTests {
    /// `Launchctl.run` on a thread of its own: it waits for the program.
    static func run(_ arguments: [String], executable: String, timeout: Duration = .seconds(10))
        async throws(MawError) -> (status: Int32, output: String)
    {
        try await runOnDedicatedThread { () throws(MawError) in
            try Launchctl.run(arguments, executable: executable, timeout: timeout)
        }
    }

    @Test func returnsTheStatusAndTheOutputOfAProgramThatExits() async throws {
        // More than a pipe holds, so that the program finishes only if its output is read
        // while it runs.
        let result = try await Self.run(
            ["-c", "echo error >&2; head -c 300000 /dev/zero | tr '\\\\0' a"],
            executable: "/bin/sh")
        #expect(result.status == 0)
        #expect(result.output.hasPrefix("error\n"))
        #expect(result.output.utf8.count == 6 + 300_000)
    }

    @Test func returnsANonZeroStatus() async throws {
        let result = try await Self.run(["-c", "echo refused; exit 3"], executable: "/bin/sh")
        #expect(result.status == 3)
        #expect(result.output == "refused\n")
    }

    @Test func reportsAProgramEndedByASignal() async throws {
        let result = try await Self.run(["-c", "kill -TERM $$"], executable: "/bin/sh")
        #expect(result.status == 128 + SIGTERM)
    }

    @Test func killsAProgramThatDoesNotFinishInTime() async throws {
        // A duration of its own, so that pgrep finds this sleep and no other.
        let duration = "1000.\(Int.random(in: 100_000...999_999))"
        let started = ContinuousClock.now
        await #expect(throws: MawError.launchctlTimedOut(command: "sleep \(duration)", seconds: 1))
        {
            _ = try await Self.run([duration], executable: "/bin/sleep", timeout: .seconds(1))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        let search = try await Self.run(
            ["-f", "^/bin/sleep \(duration)$"], executable: "/usr/bin/pgrep")
        #expect(search.status == 1, "The program is still running: \(search.output)")
    }

    /// `bootout` returns while launchd still lists the job; the wait ends once it does not.
    @Test func waitsUntilLaunchdNoLongerListsTheJob() async throws {
        var answers = [true, true, true, false]
        try await Launchctl.waitUntilRemoved(
            service: "gui/501/test", timeout: .seconds(10), interval: .milliseconds(1),
            clock: SuspendingClock()
        ) { () throws(MawError) in answers.removeFirst() }
        #expect(answers.isEmpty)
    }

    @Test func doesNotWaitForAJobThatIsGone() async throws {
        var asked = 0
        try await Launchctl.waitUntilRemoved(
            service: "gui/501/test", timeout: .seconds(10), interval: .seconds(10),
            clock: SuspendingClock()
        ) { () throws(MawError) in
            asked += 1
            return false
        }
        #expect(asked == 1)
    }

    @Test func reportsAJobThatLaunchdDoesNotRemoveInTime() async {
        let started = ContinuousClock.now
        await #expect(throws: MawError.launchAgentNotRemoved(service: "gui/501/test", seconds: 1)) {
            try await Launchctl.waitUntilRemoved(
                service: "gui/501/test", timeout: .seconds(1), interval: .milliseconds(50),
                clock: SuspendingClock()
            ) { () throws(MawError) in true }
        }
        let waited = ContinuousClock.now - started
        #expect(waited >= .seconds(1) && waited < .seconds(5))
    }

    /// The limit counts only the time of its clock: by default `SuspendingClock`, which stands
    /// still while the Mac sleeps. Here a clock that stands still throughout: polls that take
    /// longer than the limit in real time do not end the wait.
    @Test func countsOnlyTheTimeOfItsClock() async throws {
        var answers = [true, true, true, false]
        try await Launchctl.waitUntilRemoved(
            service: "gui/501/test", timeout: .milliseconds(10), interval: .milliseconds(20),
            clock: StoppedClock()
        ) { () throws(MawError) in answers.removeFirst() }
        #expect(answers.isEmpty)
    }

    @Test func passesOnAnErrorFromLaunchctl() async {
        let failure = MawError.launchctlTimedOut(
            command: "launchctl print gui/501/test", seconds: 60)
        await #expect(throws: failure) {
            try await Launchctl.waitUntilRemoved(
                service: "gui/501/test", timeout: .seconds(10), interval: .milliseconds(1),
                clock: SuspendingClock()
            ) { () throws(MawError) in throw failure }
        }
    }

    @Test func reportsAProgramThatCannotBeStarted() {
        #expect {
            _ = try Launchctl.run([], executable: "/nonexistent/launchctl", timeout: .seconds(10))
        } throws: { error in
            guard case .launchAgentFailed(let reason) = error as? MawError else { return false }
            return reason.contains("could not be started")
        }
    }
}

/// A clock whose time does not move.
struct StoppedClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {}
}
