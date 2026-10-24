import Foundation
import MawCore
import Testing

@testable import MawXPC

/// `Launchctl.run`, with programs other than launchctl standing in for it.
@Suite struct LaunchctlTests {
    @Test func returnsTheStatusAndTheOutputOfAProgramThatExits() throws {
        // More than a pipe holds, so that the program finishes only if its output is read
        // while it runs.
        let result = try Launchctl.run(
            ["-c", "echo error >&2; head -c 300000 /dev/zero | tr '\\\\0' a"],
            executable: "/bin/sh", timeout: .seconds(10))
        #expect(result.status == 0)
        #expect(result.output.hasPrefix("error\n"))
        #expect(result.output.utf8.count == 6 + 300_000)
    }

    @Test func returnsANonZeroStatus() throws {
        let result = try Launchctl.run(
            ["-c", "echo refused; exit 3"], executable: "/bin/sh", timeout: .seconds(10))
        #expect(result.status == 3)
        #expect(result.output == "refused\n")
    }

    @Test func reportsAProgramEndedByASignal() throws {
        let result = try Launchctl.run(
            ["-c", "kill -TERM $$"], executable: "/bin/sh", timeout: .seconds(10))
        #expect(result.status == 128 + SIGTERM)
    }

    @Test func killsAProgramThatDoesNotFinishInTime() throws {
        // A duration of its own, so that pgrep finds this sleep and no other.
        let duration = "1000.\(Int.random(in: 100_000...999_999))"
        let started = ContinuousClock.now
        #expect(throws: MawError.launchctlTimedOut(command: "sleep \(duration)", seconds: 1)) {
            _ = try Launchctl.run([duration], executable: "/bin/sleep", timeout: .seconds(1))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        let search = try Launchctl.run(
            ["-f", "^/bin/sleep \(duration)$"], executable: "/usr/bin/pgrep", timeout: .seconds(10))
        #expect(search.status == 1, "The program is still running: \(search.output)")
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
