import Darwin
import Foundation
import MawCore
import Testing

/// `maw --list`, `maw --set-default`, and `maw --terminate` against the test daemon, with the
/// shared test distribution and a second one that each test installs from the cached image.
///
/// The test daemon shares the owner's distributions directory and `state.json`, so the listing
/// also shows the owner's distributions. The tests therefore look only at the rows of names
/// under `MAW_TEST_PREFIX`, and they start, terminate, and choose as the default only such
/// names. Plain `maw`, without `-d`, runs only once the default is a test distribution. Every
/// test that changes the default restores `state.json` afterwards
/// (`MawIntegration.withStateFileRestored`), and every test removes the distributions it
/// installed.
///
/// When a session waits for a machine that is starting and `--terminate` waits for the same
/// start, either may resume first (`docs/daemon.md`, "The terminate sequence"). No test here
/// starts a session and a terminate at the same time, so none depends on the order.
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled,
        "Integration tests boot a real virtual machine; run scripts/integration-test.sh."),
    .serialized,
    // Bounds each test as a whole; every wait in it also has a time limit of its own.
    .timeLimit(.minutes(20))
)
struct DistroManagementIntegrationTests {
    typealias Listed = MawIntegration.ListedDistribution

    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    var distribution: String { maw.distribution }

    // MARK: Listing

    @Test func listsTheTestDistributionsWithTheirStatesAndTheDefault() async throws {
        try await maw.withStateFileRestored {
            try await maw.withDistribution("list") { second in
                // Both stopped, and the second one the default.
                for name in [distribution, second] {
                    try expectQuietSuccess(try await maw.run(["--terminate", name]))
                }
                try expectQuietSuccess(try await maw.run(["--set-default", second]))
                // The listing is sorted by name, and "<prefix>-list" sorts first.
                #expect(
                    try await maw.listed()
                        == [
                            Listed(name: second, isDefault: true, state: "Stopped"),
                            Listed(name: distribution, isDefault: false, state: "Stopped"),
                        ])
                #expect(
                    try await maw.listed(["--list"])
                        == [
                            Listed(name: second, isDefault: true),
                            Listed(name: distribution, isDefault: false),
                        ])
                #expect(
                    try await maw.listedNames(["--list", "--quiet"]) == [second, distribution])
                #expect(try await maw.listedNames(["--list", "--running", "--quiet"]).isEmpty)

                // Once the second one runs a session.
                let session = try maw.start(["-d", second, "-e", "sleep", "100"])
                try await maw.waitForSessions(1, in: second)
                #expect(
                    try await maw.listed()
                        == [
                            Listed(name: second, isDefault: true, state: "Running"),
                            Listed(name: distribution, isDefault: false, state: "Stopped"),
                        ])
                #expect(
                    try await maw.listedNames(["--list", "--running", "--quiet"]) == [second])

                try expectQuietSuccess(try await maw.run(["--terminate", second]))
                #expect(await session.waitForExit(timeout: .seconds(30)).status == 1)
            }
        }
    }

    // MARK: The default

    /// `--set-default` decides what plain `maw` opens, and a new daemon still opens the same
    /// distribution. Plain `maw` runs only after the listing shows a test distribution as the
    /// default, so that it never starts one of the owner's.
    @Test func setsTheDistributionThatPlainMawOpensAcrossARestart() async throws {
        try await maw.withStateFileRestored {
            try await maw.withDistribution("default") { second in
                for name in [distribution, second] {
                    try expectQuietSuccess(try await maw.run(["--set-default", name]))
                    try await requireDefault(name)
                    let opened = try await maw.run(["--", "hostname"])
                    #expect(opened.status == 0, "\(opened.standardError)")
                    #expect(opened.output == "\(maw.hostname(of: name))\n")
                }

                // SIGTERM stops the daemon's machines and ends it; launchd starts a new one
                // for the next request, the listing.
                let daemon = try await maw.daemonProcessID()
                #expect(kill(daemon, SIGTERM) == 0)
                let ended = await maw.eventually(within: .seconds(60)) {
                    kill(daemon, 0) != 0 && errno == ESRCH
                }
                try #require(ended, "The test daemon \(daemon) did not exit after SIGTERM.")
                try await requireDefault(second)
                #expect(try await maw.daemonProcessID() != daemon)
                let opened = try await maw.run(["--", "hostname"])
                #expect(opened.status == 0, "\(opened.standardError)")
                #expect(opened.output == "\(maw.hostname(of: second))\n")
            }
        }
    }

    // MARK: Terminate

    /// `--terminate` of one distribution ends its session and stops its machine cleanly; the
    /// other distribution keeps its machine and its session, which still passes a signal.
    @Test func terminateStopsOneMachineAndKeepsTheOther() async throws {
        try await maw.withDistribution("other") { second in
            let kept = try maw.start(["-d", distribution, "-e", "sleep", "100"])
            let ended = try maw.start(["-d", second, "-e", "sleep", "100"])
            try await maw.waitForSessions(1)
            try await maw.waitForSessions(1, in: second)
            let shutdowns = maw.shutdownLines(of: second).count

            try expectQuietSuccess(try await maw.run(["--terminate", second]))

            let result = await ended.waitForExit(timeout: .seconds(30))
            #expect(result.status == 1)
            #expect(
                result.standardError.contains(
                    "maw: The session ended because the virtual machine \(second) stopped:\n"
                        + "maw --terminate was run.\n"),
                "\(result.standardError)")
            #expect(try await maw.machineRow(of: second) == "")
            let shutdown = maw.shutdownLines(of: second)
            #expect(shutdown.count == shutdowns + 1, "\(shutdown)")
            #expect(shutdown.last?.contains("shutdown: clean after ") == true, "\(shutdown)")

            let row = try await maw.machineRow()
            #expect(row.contains("Running") && row.hasSuffix(" 1"), "\(row)")
            #expect(kept.isRunning)
            #expect(
                try await maw.listed().filter { [distribution, second].contains($0.name) }
                    .map { "\($0.name) \($0.state ?? "")" }
                    == [
                        "\(second) Stopped", "\(distribution) Running",
                    ])
            kept.signal(SIGINT)
            #expect(await kept.waitForExit(timeout: .seconds(30)).status == 130)
        }
    }

    /// A shell on a terminal ends with `machineStopped` naming `maw --terminate`, the terminal
    /// is restored, and the next command starts the machine again.
    @Test func terminateEndsATerminalSessionWithItsReason() async throws {
        let session = try maw.interactive(["-d", distribution])
        let host = maw.hostname(of: distribution)
        try #require(
            await session.waitForPrompt(user: maw.user, host: host), "\(session.plainOutput)")

        try expectQuietSuccess(try await maw.run(["--terminate", distribution]))

        let status = await session.waitForExit(timeout: .seconds(30))
        #expect(status == 1, "\(session.plainOutput)")
        #expect(
            session.plainOutput.replacing("\r\n", with: "\n").contains(
                "maw: The session ended because the virtual machine \(distribution) stopped:\n"
                    + "maw --terminate was run.\n"
                    + "Run the command again to start a new virtual machine.\n"),
            "\(session.plainOutput)")
        #expect(session.terminalIsRestored, "The terminal attributes differ after the session.")
        #expect(try await maw.machineRow() == "")

        let next = try await maw.session(["-e", "true"])
        #expect(next.status == 0, "\(next.standardError)")
    }

    /// `--terminate` of a distribution whose machine is stopped succeeds and boots nothing.
    @Test func terminateOfAStoppedDistributionStartsNothing() async throws {
        try expectQuietSuccess(try await maw.run(["--terminate", distribution]))
        #expect(try await maw.machineRow() == "")
        let boots = maw.bootLines(of: distribution).count

        try expectQuietSuccess(try await maw.run(["--terminate", distribution]))

        #expect(try await maw.machineRow() == "")
        #expect(maw.bootLines(of: distribution).count == boots)
        #expect(
            try await maw.listed().first { $0.name == distribution }?.state == "Stopped")
    }

    // MARK: Unknown names

    /// An unknown name fails with `distributionNotInstalled` and its suggestion, and changes
    /// neither the default nor any machine.
    @Test func reportsAnUnknownNameWithItsSuggestion() async throws {
        try await maw.withStateFileRestored {
            let missing = "\(maw.prefix)-missing"
            let stateBefore = try? Data(contentsOf: maw.paths.stateFile)
            for action in ["--terminate", "--set-default"] {
                let result = try await maw.run([action, missing])
                #expect(result.status == 1, "\(action)")
                #expect(result.output == "", "\(action)")
                #expect(
                    result.standardError
                        == "maw: No distribution named '\(missing)' is installed.\n"
                        + "maw --list shows the installed distributions.\n",
                    "\(action): \(result.standardError)")
            }
            #expect((try? Data(contentsOf: maw.paths.stateFile)) == stateBefore)
        }
    }

    // MARK: Measurements

    @Test func measuresListVerbose() async throws {
        try await maw.withDistribution("measure-list") { _ in
            // The daemon runs, and the first listing is not counted.
            #expect(try await maw.run(["--list", "--verbose"]).status == 0)
            var times: [Double] = []
            for _ in 0..<5 {
                let (status, elapsed) = try await maw.timed(["--list", "--verbose"])
                #expect(status == 0)
                times.append(elapsed)
            }
            let median = MawIntegration.report(
                "maw --list --verbose, daemon running, at least two distributions installed",
                times)
            #expect(median < 50)
        }
    }

    @Test func measuresSetDefault() async throws {
        try await maw.withStateFileRestored {
            #expect(try await maw.run(["--set-default", distribution]).status == 0)
            var times: [Double] = []
            for _ in 0..<5 {
                let (status, elapsed) = try await maw.timed(["--set-default", distribution])
                #expect(status == 0)
                times.append(elapsed)
            }
            let median = MawIntegration.report(
                "maw --set-default, daemon running", times)
            #expect(median < 50)
        }
    }

    /// Each run boots the test distribution and waits for systemd to finish starting, so that
    /// the machine runs and is idle, and then terminates it before the idle timeout would.
    ///
    /// The agent accepts sessions before systemd has created the system bus's socket, and
    /// `systemctl` as the default user fails at once without it ("Failed to connect to bus"),
    /// so the session waits for the socket, for at most 30 seconds, before it asks systemd.
    @Test func measuresTerminateOfARunningIdleDistribution() async throws {
        var times: [Double] = []
        for _ in 0..<5 {
            let booted = try await maw.session([
                "--",
                "for i in $(seq 300); do [ -S /run/dbus/system_bus_socket ] && break; sleep 0.1;"
                    + " done; systemctl is-system-running --wait",
            ])
            #expect(
                ["running", "degraded"].contains(booted.lines.first ?? ""),
                "\(booted.status) \(booted.output)\(booted.standardError)")
            let shutdowns = maw.shutdownLines(of: distribution).count
            let (status, elapsed) = try await maw.timed(["--terminate", distribution])
            #expect(status == 0)
            // The machine was still running, and this terminate stopped it.
            let shutdown = maw.shutdownLines(of: distribution)
            #expect(shutdown.count == shutdowns + 1, "\(shutdown)")
            #expect(shutdown.last?.contains("shutdown: clean after ") == true, "\(shutdown)")
            times.append(elapsed)
        }
        let median = MawIntegration.report(
            "maw --terminate of a running, idle distribution, to maw's exit", times)
        #expect(median < 1_000)
    }

    /// Reported only. launchd starts a daemon at most once every 10 seconds, so each run ends
    /// a daemon that has run for longer than that.
    @Test func measuresListWhileTheDaemonIsNotRunning() async throws {
        var times: [Double] = []
        for _ in 0..<5 {
            try await Task.sleep(for: .seconds(11))
            let daemon = try await maw.daemonProcessID()
            #expect(kill(daemon, SIGTERM) == 0)
            let ended = await maw.eventually(within: .seconds(60)) {
                kill(daemon, 0) != 0 && errno == ESRCH
            }
            try #require(ended, "The test daemon \(daemon) did not exit after SIGTERM.")
            let (status, elapsed) = try await maw.timed(["--list"])
            #expect(status == 0)
            times.append(elapsed)
        }
        MawIntegration.report("maw --list while the daemon is not running", times)
    }

    // MARK: Helpers

    /// `--set-default` and `--terminate` print nothing and exit with 0 when they succeed.
    func expectQuietSuccess(
        _ result: DebugBootProcess.Result, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        try #require(result.status == 0, "\(result.standardError)", sourceLocation: sourceLocation)
        #expect(result.output == "", sourceLocation: sourceLocation)
        #expect(result.standardError == "", sourceLocation: sourceLocation)
    }

    /// Requires `maw --list` to mark `name`, a test distribution, as the default.
    func requireDefault(
        _ name: String, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let listed = try await maw.listed(["--list"], sourceLocation: sourceLocation)
        try #require(
            listed.contains(Listed(name: name, isDefault: true)),
            "The listing does not mark \(name) as the default: \(listed)",
            sourceLocation: sourceLocation)
    }
}
