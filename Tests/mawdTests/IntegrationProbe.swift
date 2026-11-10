import Darwin
import Foundation
import Testing

/// The integration probe (`Tests/maw-integration-probe`) as a subprocess, with a session in the
/// test distribution: commands on its standard input, one result line each on its standard
/// output, and the terminal's output on its standard error.
final class IntegrationProbe: @unchecked Sendable {
    let process: DebugBootProcess
    private let input = Pipe()
    private let lock = NSLock()
    private var commands = 1

    init(maw: MawIntegration) throws {
        let path = try #require(
            MawIntegration.environment["MAW_INTEGRATION_PROBE_PATH"],
            "MAW_INTEGRATION_PROBE_PATH must point to the signed probe.")
        process = try DebugBootProcess(
            executable: URL(filePath: path), arguments: [maw.distribution],
            standardInputPipe: input, separateStandardError: true,
            environment: maw.mawEnvironment)
    }

    var results: [String] {
        process.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    var terminal: String { process.standardError }

    var transcript: String { "results:\n\(process.output)\nterminal:\n\(terminal)" }

    /// The `index`th result line, from 1, once it has arrived.
    func result(_ index: Int, timeout: Duration = .seconds(60)) async -> String? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let lines = results
            if lines.count >= index {
                return lines[index - 1]
            }
            if !process.isRunning {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let lines = results
        return lines.count >= index ? lines[index - 1] : nil
    }

    /// Sends one command and returns its result line.
    func send(_ command: String) async throws -> String {
        let index = lock.withLock {
            commands += 1
            return commands
        }
        try input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
        return try #require(await result(index), "no result for \(command)\n\(transcript)")
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.signal(SIGTERM)
        }
    }
}
