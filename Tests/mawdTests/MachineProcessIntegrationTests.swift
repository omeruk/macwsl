import Darwin
import Foundation
import MawCore
import MawDaemonKit
import Testing

/// The lookup of a machine's Virtualization process on a real distribution. It detects a
/// change of Virtualization.framework's process model, which would leave CPU and host memory
/// empty ([decision record 0020](../../docs/decisions/0020-distribution-figures.md)).
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled,
        "Integration tests boot a real virtual machine; run scripts/integration-test.sh."),
    .serialized,
    .timeLimit(.minutes(10))
)
struct MachineProcessIntegrationTests {
    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    /// While a session keeps the test distribution running, the lookup finds exactly one
    /// process, and reads its CPU time and footprint.
    @Test func findsTheRunningMachinesProcess() async throws {
        let probe = try IntegrationProbe(maw: maw)
        defer { probe.stop() }
        let started = try #require(await probe.result(1), "\(probe.transcript)")
        try #require(started.hasPrefix("started "), "\(probe.transcript)")

        let disk = maw.paths.diskImage(for: try DistroName(maw.distribution))
        let identity = try #require(FileIdentity(path: disk.path(percentEncoded: false)))
        let table = DarwinProcessTable()
        var times: [Double] = []
        var found: ProcessIdentity?
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let process = MachineProcessFinder.find(
                diskImage: identity, user: getuid(), in: table)
            let elapsed = (ContinuousClock.now - start).components
            times.append(
                Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
            let candidate = try #require(
                process, "no single process has \(disk.path(percentEncoded: false)) open")
            if let found {
                #expect(candidate == found)
            }
            found = candidate
        }
        MawIntegration.report("process lookup", times)

        let process = try #require(found)
        #expect(table.executablePath(of: process.processID) == MachineProcessFinder.executablePath)
        let first = try #require(MachineProcessFinder.usage(of: process, in: table))
        #expect(first.footprintBytes > 50 << 20)
        try await Task.sleep(for: .seconds(1))
        let second = try #require(MachineProcessFinder.usage(of: process, in: table))
        #expect(second.cpuNanoseconds >= first.cpuNanoseconds)
    }
}
