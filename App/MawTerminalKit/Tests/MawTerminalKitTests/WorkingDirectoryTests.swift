import Foundation
import MawTerminalKit
import Testing

@Suite struct OSC7LocationTests {
    @Test func parsesFileURLs() {
        let location = OSC7Location(parsing: "file://mbp.local/Users/omer/projects")
        #expect(location?.host == "mbp.local")
        #expect(location?.path == "/Users/omer/projects")
    }

    @Test func decodesPercentEscapes() {
        #expect(
            OSC7Location(parsing: "file:///Users/omer/My%20Files")?.path == "/Users/omer/My Files")
        #expect(OSC7Location(parsing: "file:///tmp/%C3%A7al%C4%B1%C5%9Fma")?.path == "/tmp/çalışma")
    }

    @Test func treatsAnEmptyHostAsNone() {
        #expect(OSC7Location(parsing: "file:///tmp")?.host == nil)
    }

    @Test func dropsATrailingSlashExceptForTheRoot() {
        #expect(OSC7Location(parsing: "file:///tmp/")?.path == "/tmp")
        #expect(OSC7Location(parsing: "file:///")?.path == "/")
    }

    @Test(arguments: ["http://host/tmp", "/tmp", "file://host", "not a url", ""])
    func rejectsOtherURLs(_ text: String) {
        #expect(OSC7Location(parsing: text) == nil)
    }

    @Test func recognizesTheLocalHost() throws {
        let names: Set<String> = ["mbp.local"]
        #expect(try #require(OSC7Location(parsing: "file:///tmp")).isLocal(localNames: names))
        #expect(
            try #require(OSC7Location(parsing: "file://localhost/tmp")).isLocal(localNames: names))
        #expect(
            try #require(OSC7Location(parsing: "file://MBP.local/tmp")).isLocal(localNames: names))
        #expect(try #require(OSC7Location(parsing: "file://mbp/tmp")).isLocal(localNames: names))
        #expect(
            try #require(OSC7Location(parsing: "file://server/tmp")).isLocal(localNames: names)
                == false)
    }
}

@Suite struct WorkingDirectoryTrackerTests {
    let start = ContinuousClock.now

    @Test func pollsAVisibleIdleSession() {
        let tracker = WorkingDirectoryTracker()
        #expect(tracker.shouldPoll(at: start, isVisible: true))
        #expect(!tracker.shouldPoll(at: start, isVisible: false))
    }

    @Test func pollsAtMostOncePerSecond() {
        var tracker = WorkingDirectoryTracker()
        tracker.polled("/tmp", at: start)
        #expect(!tracker.shouldPoll(at: start + .milliseconds(999), isVisible: true))
        #expect(tracker.shouldPoll(at: start + .seconds(1), isVisible: true))
    }

    @Test func waitsForOutputToGoIdle() {
        var tracker = WorkingDirectoryTracker()
        tracker.outputArrived(at: start)
        #expect(!tracker.shouldPoll(at: start + .milliseconds(100), isVisible: true))
        #expect(tracker.shouldPoll(at: start + .milliseconds(300), isVisible: true))
    }

    @Test func osc7StopsPollingAndWins() {
        var tracker = WorkingDirectoryTracker()
        tracker.polled("/polled", at: start)
        expectTrue(tracker.reported("/reported"))
        #expect(tracker.directory == "/reported")
        #expect(!tracker.shouldPoll(at: start + .seconds(10), isVisible: true))
        expectFalse(tracker.polled("/later", at: start + .seconds(10)))
        #expect(tracker.directory == "/reported")
    }

    @Test func aFailedPollKeepsTheLastDirectory() {
        var tracker = WorkingDirectoryTracker()
        tracker.polled("/tmp", at: start)
        expectFalse(tracker.polled(nil, at: start + .seconds(2)))
        #expect(tracker.directory == "/tmp")
    }

    @Test func reportsOnlyChanges() {
        var tracker = WorkingDirectoryTracker()
        expectTrue(tracker.polled("/tmp", at: start))
        expectFalse(tracker.polled("/tmp", at: start + .seconds(2)))
        expectTrue(tracker.reported("/var"))
        expectFalse(tracker.reported("/var"))
    }

    @Test func abbreviatesTheHomeDirectory() {
        #expect(abbreviatingHome("/Users/omer", home: "/Users/omer") == "~")
        #expect(abbreviatingHome("/Users/omer/projects", home: "/Users/omer") == "~/projects")
        #expect(abbreviatingHome("/Users/omerx", home: "/Users/omer") == "/Users/omerx")
        #expect(abbreviatingHome("/tmp", home: "/Users/omer") == "/tmp")
    }
}

@Suite struct TerminationStatusTests {
    @Test func decodesWaitStatuses() {
        #expect(TerminationStatus(waitStatus: 0) == .exited(0))
        #expect(TerminationStatus(waitStatus: 3 << 8) == .exited(3))
        #expect(TerminationStatus(waitStatus: SIGKILL) == .signaled(SIGKILL))
        #expect(TerminationStatus(waitStatus: 0x7F) == .unknown)
    }

    @Test func describesTheStatus() {
        #expect(TerminationStatus.exited(0).description == "exited")
        #expect(TerminationStatus.exited(2).description == "exited with status 2")
        #expect(TerminationStatus.signaled(SIGKILL).description.hasPrefix("ended by signal 9"))
    }
}

@Suite struct HostSummaryTests {
    @Test func formatsAsInTheDistributionsBoard() {
        let summary = HostSummary(
            physicalMemory: 16 << 30, processorCount: 10,
            macOSVersion: [27, 0, 0])
        #expect(summary.description == "16 GB · 10 cores · macOS 27.0")
    }

    @Test func includesAPatchVersion() {
        let summary = HostSummary(
            physicalMemory: 8 << 30, processorCount: 1,
            macOSVersion: [14, 6, 1])
        #expect(summary.description == "8 GB · 1 core · macOS 14.6.1")
    }
}
