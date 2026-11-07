import Foundation
import MawCore
import Testing

@testable import MawDaemonKit

/// The provisioning machine's console log, without a virtual machine: `boot` starts the log
/// afresh before it looks for the guest files, which this test does not have.
@Suite struct VirtualProvisioningMachineTests {
    /// Installing `foo` starts its console log afresh, and leaves the console log of a
    /// distribution named `install-foo` as it was.
    @Test func startsItsLogAfreshAndLeavesADistributionsLogAlone() async throws {
        let logs = FileManager.default.temporaryDirectory.appending(
            path: "maw-logs-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logs) }
        let distributionLog = MawPaths.consoleLogFile(forMachineNamed: "install-foo", in: logs)
        try Data("install-foo's console".utf8).write(to: distributionLog)
        let installLog = MawPaths.installLogFile(for: try DistroName("foo"), in: logs)
        try FileManager.default.createDirectory(
            at: installLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("an earlier attempt".utf8).write(to: installLog)

        let machine = VirtualProvisioningMachine(
            kernelDirectory: logs.appending(path: "no-guest-files", directoryHint: .isDirectory),
            consoleLog: installLog)
        await #expect(throws: MawError.self) {
            try await machine.boot(disk: logs.appending(path: "disk.img"))
        }
        #expect(!FileManager.default.fileExists(atPath: installLog.path(percentEncoded: false)))
        #expect(try Data(contentsOf: distributionLog) == Data("install-foo's console".utf8))
    }

    // MARK: The extraction's two programs

    typealias Outcome = StreamingProcess.Outcome

    struct SpawnFailure: Error, LocalizedError {
        var errorDescription: String? { "posix_spawn failed: Resource temporarily unavailable" }
    }

    @Test func reportsNothingWhenBothSucceed() {
        #expect(
            VirtualProvisioningMachine.extractionFailure(
                tar: .success(Outcome(status: 0, errors: "")), bsdtar: .exited(code: 0),
                bsdtarErrors: "no output") == nil)
    }

    @Test func reportsTarAloneWhenOnlyTarFailed() {
        #expect(
            VirtualProvisioningMachine.extractionFailure(
                tar: .success(Outcome(status: 1, errors: "tar: Error reading archive")),
                bsdtar: .exited(code: 0), bsdtarErrors: "no output")
                == "/usr/bin/tar exited with status 1: tar: Error reading archive")
        #expect(
            VirtualProvisioningMachine.extractionFailure(
                tar: .failure(SpawnFailure()), bsdtar: .exited(code: 0),
                bsdtarErrors: "no output")
                == "/usr/bin/tar cannot start: posix_spawn failed: Resource temporarily "
                + "unavailable")
    }

    @Test func reportsBsdtarAloneWhenOnlyBsdtarFailed() {
        #expect(
            VirtualProvisioningMachine.extractionFailure(
                tar: .success(Outcome(status: 0, errors: "")), bsdtar: .exited(code: 1),
                bsdtarErrors: "bsdtar: Write failed: No space left on device")
                == "bsdtar exited with code 1: bsdtar: Write failed: No space left on device")
    }

    /// Either can be the cause, so both are named: before, bsdtar's status hid tar's.
    @Test func reportsBothWhenBothFailed() {
        let reason = VirtualProvisioningMachine.extractionFailure(
            tar: .success(Outcome(status: 1, errors: "tar: Error reading archive")),
            bsdtar: .exited(code: 1), bsdtarErrors: "bsdtar: Truncated input file")
        #expect(
            reason
                == "/usr/bin/tar exited with status 1: tar: Error reading archive; "
                + "bsdtar exited with code 1: bsdtar: Truncated input file")
        #expect(
            MawError.provisioningFailed(
                step: "extracting the root file system", reason: reason ?? ""
            ).errorDescription
                == "The installation failed while extracting the root file system: "
                + "/usr/bin/tar exited with status 1: tar: Error reading archive; bsdtar "
                + "exited with code 1: bsdtar: Truncated input file.")
        #expect(
            VirtualProvisioningMachine.extractionFailure(
                tar: .failure(SpawnFailure()), bsdtar: .signaled(signal: 9),
                bsdtarErrors: "no output")
                == "/usr/bin/tar cannot start: posix_spawn failed: Resource temporarily "
                + "unavailable; bsdtar ended by SIGKILL: no output")
    }
}
