import Darwin
import Foundation
import Testing

/// The foreground-program report (protocol version 4) on a real distribution, through the
/// integration probe (`Tests/maw-integration-probe`), which opens a login shell in the test
/// distribution through the test daemon and asks the agent on request.
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled,
        "Integration tests boot a real virtual machine; run scripts/integration-test.sh."),
    .serialized,
    .timeLimit(.minutes(10))
)
struct ForegroundIntegrationTests {
    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    /// None at the prompt, `sleep` while `sleep 30` runs, and none again once it has ended.
    @Test func reportsTheForegroundProgramOfALoginShell() async throws {
        let probe = try Probe(maw: maw)
        defer { probe.stop() }
        let started = try #require(await probe.result(1), "\(probe.transcript)")
        try #require(started.hasPrefix("started "), "\(probe.transcript)")
        // The prompt of the test user's bash ends with "$ ".
        try #require(
            await maw.eventually(within: .seconds(30)) { probe.terminal.contains("$ ") },
            "\(probe.transcript)")

        #expect(try await probe.send("foreground") == "none", "\(probe.transcript)")

        #expect(try await probe.send(#"send sleep 30\r"#) == "sent 9")
        var answer = ""
        let named = await maw.eventually(within: .seconds(10)) {
            answer = (try? await probe.send("foreground")) ?? ""
            return answer.hasPrefix("program ")
        }
        #expect(named, "\(probe.transcript)")
        let fields = answer.split(separator: " ")
        #expect(fields.count == 3 && Int32(fields[1]) != nil, "\(answer)")
        #expect(fields.last == "sleep", "\(answer)")

        // Ctrl-C ends sleep; bash takes the terminal back.
        #expect(try await probe.send(#"send \x03"#) == "sent 1")
        let none = await maw.eventually(within: .seconds(10)) {
            (try? await probe.send("foreground")) == "none"
        }
        #expect(none, "\(probe.transcript)")

        #expect(try await probe.send("close") == "closed", "\(probe.transcript)")
        let exited = await probe.process.waitForExit(timeout: .seconds(30))
        #expect(exited.status == 0, "\(probe.transcript)")
    }

    /// The probe as a subprocess: commands on its standard input, one result line each on its
    /// standard output, and the terminal's output on its standard error.
    final class Probe: @unchecked Sendable {
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
}
