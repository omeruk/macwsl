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
}
