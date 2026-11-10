import Foundation
import Testing

extension SessionCoreIntegrationTests {
    /// The speed targets of `prompts/11b-linux-sessions.md` for the session core, which the
    /// terminal app's Linux tabs use. The integration probe takes each time itself, around the
    /// operation, so that its pipes to the test runner add nothing. Each test reports the median
    /// of 5 runs with `MawIntegration.report` and, where the prompt sets a target, expects it;
    /// the foreground report and the echo are reported in microseconds.
    ///
    /// "The prompt" is the output that first contains "$ ", the end of the test user's bash
    /// prompt; bash writes the whole prompt at once, so it arrives with its first bytes.
    @Suite struct Latency {
        let maw: MawIntegration

        init() throws {
            maw = try MawIntegration()
        }

        /// A second session holds the machine, which the test daemon would otherwise stop
        /// 3 seconds after its last session, so that each measured session opens in a running
        /// machine.
        @Test func measuresANewSessionInARunningDistribution() async throws {
            let holder = try await started()
            defer { holder.stop() }
            var times: [Double] = []
            for _ in 0..<5 {
                times.append(try await timeToPrompt())
            }
            let median = MawIntegration.report(
                "a new Linux session in a running distribution, from opening to the prompt",
                times)
            #expect(median < 150)
            #expect(try await holder.send("close") == "closed hung-up", "\(holder.transcript)")
        }

        @Test func measuresANewSessionInAStoppedDistribution() async throws {
            var times: [Double] = []
            for _ in 0..<5 {
                let stopped = try await maw.run(["--terminate", maw.distribution])
                #expect(stopped.status == 0, "\(stopped.standardError)")
                try await Task.sleep(for: .seconds(2))
                times.append(try await timeToPrompt())
            }
            let median = MawIntegration.report(
                "a new Linux session in a stopped distribution, from opening to the prompt",
                times)
            #expect(median < 2_000)
        }

        /// While `sleep 30` runs, so that the agent reads the leader's state and name.
        @Test func measuresTheForegroundReport() async throws {
            let probe = try await started()
            defer { probe.stop() }
            #expect(try await probe.send(#"send sleep 30\r"#) == "sent 9")
            let running = await maw.eventually(within: .seconds(10)) {
                (try? await probe.send("foreground"))?.hasPrefix("program ") == true
            }
            try #require(running, "\(probe.transcript)")

            var times: [Double] = []
            for _ in 0..<5 {
                let answer = try await probe.send("foreground-time")
                let fields = answer.split(separator: " ")
                try #require(
                    fields.count == 5 && fields[2] == "program" && fields[4] == "sleep",
                    "\(answer)")
                times.append(try #require(Double(fields[1]), "\(answer)") * 1_000)
            }
            let median = MawIntegration.report(
                "the foreground report while sleep runs, from the request to the answer", times,
                unit: "µs")
            #expect(median < 100_000)

            #expect(try await probe.send(#"send \x03"#) == "sent 1")
            #expect(try await probe.send("close") == "closed hung-up", "\(probe.transcript)")
        }

        /// Reported only. Each key goes through the session's input thread and its echo
        /// through the output handler, as in the terminal app.
        @Test func measuresTypingLatency() async throws {
            let probe = try await started()
            defer { probe.stop() }
            var times: [Double] = []
            for _ in 0..<5 {
                let answer = try await probe.send("echo-time q")
                let fields = answer.split(separator: " ")
                try #require(fields.count == 2, "\(answer)\n\(probe.transcript)")
                let time = try #require(Double(fields[1]), "\(answer)\n\(probe.transcript)")
                times.append(time * 1_000)
            }
            MawIntegration.report(
                "typing latency in a Linux session, from sending a key to its echo", times,
                unit: "µs")
            // Ctrl-U clears the typed line before the session closes.
            #expect(try await probe.send(#"send \x15"#) == "sent 1")
            #expect(try await probe.send("close") == "closed hung-up", "\(probe.transcript)")
        }

        /// The time from opening a new session to its prompt, which the probe took.
        private func timeToPrompt() async throws -> Double {
            let probe = try await started()
            defer { probe.stop() }
            let answer = try await probe.send("prompt-time")
            let fields = answer.split(separator: " ")
            let time = try #require(
                fields.count == 2 ? Double(fields[1]) : nil, "\(answer)\n\(probe.transcript)")
            #expect(try await probe.send("close") == "closed hung-up", "\(probe.transcript)")
            _ = await probe.process.waitForExit(timeout: .seconds(30))
            return time
        }

        /// A probe whose session has started and shows the test user's prompt.
        private func started() async throws -> IntegrationProbe {
            let probe = try IntegrationProbe(maw: maw)
            let started = try #require(await probe.result(1), "\(probe.transcript)")
            try #require(started.hasPrefix("started "), "\(probe.transcript)")
            try #require(
                await maw.eventually(within: .seconds(30)) { probe.terminal.contains("$ ") },
                "\(probe.transcript)")
            return probe
        }
    }
}
