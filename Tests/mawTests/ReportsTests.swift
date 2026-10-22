import Foundation
import MawCore
import MawXPC
import Testing

@testable import maw

@Suite struct ReportsTests {
    static let daemon = DaemonInfo(version: "0.1.0", processID: 4242, interfaceVersion: 1)

    @Test func showsTheDaemonAndItsMachines() {
        let status = DaemonStatus(
            daemon: Self.daemon, uptimeMilliseconds: 125_000, canRunVirtualMachines: true,
            machines: [
                MachineStatus(
                    machine: .initramfs, state: .running, uptimeMilliseconds: 121_400,
                    cpuCount: 4, memoryBytes: 2 << 30, sessionCount: 2)
            ])
        #expect(
            Reports.status(status) == """
                mawd 0.1.0, process 4242, running for 2m 05s

                  NAME       STATE    UPTIME  CPUS  MEMORY  SESSIONS
                  initramfs  Running  2m 01s  4     2G      2

                """)
    }

    @Test func showsAStartingMachineWithoutUptime() {
        let status = DaemonStatus(
            daemon: Self.daemon, uptimeMilliseconds: 900, canRunVirtualMachines: true,
            machines: [
                MachineStatus(
                    machine: .initramfs, state: .starting, uptimeMilliseconds: nil,
                    cpuCount: 4, memoryBytes: 2 << 30, sessionCount: 0)
            ])
        #expect(Reports.status(status).contains("  initramfs  Starting  -       4     2G      0\n"))
    }

    @Test func saysWhenNoMachineRuns() {
        let status = DaemonStatus(
            daemon: Self.daemon, uptimeMilliseconds: 3_000, canRunVirtualMachines: true,
            machines: [])
        #expect(
            Reports.status(status) == """
                mawd 0.1.0, process 4242, running for 3s

                No virtual machine is running.

                """)
    }

    @Test func warnsAboutAMissingEntitlement() {
        let status = DaemonStatus(
            daemon: Self.daemon, uptimeMilliseconds: 0, canRunVirtualMachines: false,
            machines: [])
        let text = Reports.status(status)
        #expect(text.contains("warning: mawd is not signed with the virtualization entitlement"))
        #expect(text.contains("scripts/sign-dev.sh"))
    }

    @Test func saysThatTheDaemonDoesNotRun() {
        #expect(
            Reports.daemonNotRunning
                == "The maw daemon is not running. It starts when a command needs a virtual machine.\n"
        )
    }

    @Test func formatsDurations() {
        #expect(Reports.duration(milliseconds: 0) == "0s")
        #expect(Reports.duration(milliseconds: 59_999) == "59s")
        #expect(Reports.duration(milliseconds: 60_000) == "1m 00s")
        #expect(Reports.duration(milliseconds: 3_599_000) == "59m 59s")
        #expect(Reports.duration(milliseconds: 3_720_000) == "1h 02m")
    }

    @Test func reportsEveryVersion() throws {
        let manifest = try JSONDecoder().decode(
            GuestFiles.Manifest.self,
            from: Data(
                #"{"guestVersion":"7a9b162","gitCommit":"7a9b1624c9541234","kernel":{"release":"6.18.57-maw"}}"#
                    .utf8))
        #expect(
            Reports.version(daemon: .running(Self.daemon), guest: .installed(manifest)) == """
                maw \(MawVersion.current)
                mawd 0.1.0 (process 4242, interface version 1)
                guest 7a9b162, kernel 6.18.57-maw, commit 7a9b1624c954

                """)
    }

    @Test func reportsWhatIsMissing() {
        #expect(
            Reports.version(daemon: .notRunning, guest: .missing) == """
                maw \(MawVersion.current)
                mawd: not running
                guest: not installed (run scripts/fetch-guest.sh)

                """)
        #expect(
            Reports.version(daemon: .notInstalled, guest: .unreadable).contains(
                "mawd: not installed (run mawd install)\nguest: manifest.json could not be read\n"))
    }
}

@Suite struct UnimplementedActionTests {
    @Test(arguments: [
        (["--install", "Ubuntu"], "--install", "05"),
        (["-l", "-o"], "--list --online", "05"),
        (["-l"], "--list", "06"),
        (["-l", "-v"], "--list --verbose", "06"),
        (["-s", "Ubuntu"], "--set-default", "06"),
        (["-t", "Ubuntu"], "--terminate", "06"),
        (["--export", "Ubuntu", "u.tar"], "--export", "06"),
        (["--import", "Ubuntu", "u.tar"], "--import", "06"),
        (["--unregister", "Ubuntu"], "--unregister", "06"),
    ])
    func namesThePhaseThatAddsIt(_ arguments: [String], _ feature: String, _ phase: String)
        async throws
    {
        let command = try Maw.parse(ArgumentNormalizer.normalize(arguments))
        await #expect(throws: MawError.notImplemented(feature: feature, phase: phase)) {
            try await command.run()
        }
    }
}
