import Foundation
import Testing

/// Measures standard input streamed through maw into the test distribution: the throughput of
/// a fast reader, and the time a slow one takes. The input window (decision record 0016) must
/// not slow either down.
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled,
        "Integration tests boot a real virtual machine; run scripts/integration-test.sh."),
    .serialized
)
struct StreamMeasurementTests {
    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    /// 1.3 GB from `/dev/zero` into `cat > /dev/null`.
    @Test func measuresInputThroughput() async throws {
        #expect(try await maw.session(["-e", "true"]).status == 0)
        let size = 1_300_000_000
        var times: [Double] = []
        for _ in 0..<5 {
            times.append(try await stream("head -c \(size) /dev/zero", into: "cat > /dev/null"))
        }
        let median = MawIntegration.report("1.3 GB from /dev/zero into cat > /dev/null", times)
        let rate = Double(size) / median / 1e3
        print(String(format: "measurement: median throughput %.0f MB/s", rate))
    }

    /// 256 MiB of pseudo-random data into `sha256sum`, which reads slower than vsock delivers,
    /// as `DaemonIntegrationTests.streamsLargeInputIntoASlowReader` streams it.
    @Test func measuresASlowReader() async throws {
        #expect(try await maw.session(["-e", "true"]).status == 0)
        let input = FileManager.default.temporaryDirectory.appending(
            path: "maw-measure-\(UUID().uuidString)")
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var bytes = Data(count: 256 << 20)
        bytes.withUnsafeMutableBytes { buffer in
            for index in buffer.bindMemory(to: UInt64.self).indices {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                buffer.bindMemory(to: UInt64.self)[index] = state
            }
        }
        try bytes.write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        var times: [Double] = []
        for _ in 0..<5 {
            times.append(try await stream("cat '\(input.path)'", into: "sha256sum > /dev/null"))
        }
        MawIntegration.report("256 MiB into sha256sum", times)
    }

    /// Runs `<source> | maw -e sh -c <sink>` and returns its duration in milliseconds.
    func stream(_ source: String, into sink: String) async throws -> Double {
        let started = ContinuousClock.now
        let result = try await DebugBootProcess(
            executable: URL(filePath: "/bin/sh"),
            arguments: [
                "-c", "\(source) | \"$0\" -d \"$1\" -e sh -c \"$2\"", maw.maw.path,
                maw.distribution, sink,
            ],
            separateStandardError: true, environment: maw.mawEnvironment
        ).waitForExit(timeout: .seconds(120))
        let elapsed = (ContinuousClock.now - started).fractionalMilliseconds
        #expect(result.status == 0, "\(result.standardError)")
        return elapsed
    }
}
