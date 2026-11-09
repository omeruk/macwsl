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
        let probe = try IntegrationProbe(maw: maw)
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

        #expect(try await probe.send("close") == "closed hung-up", "\(probe.transcript)")
        let exited = await probe.process.waitForExit(timeout: .seconds(30))
        #expect(exited.status == 0, "\(probe.transcript)")
    }
}
