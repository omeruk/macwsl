import Foundation
import Testing

/// The terminal app's measurements of `prompts/11c-distribution-figures.md` ("Speed targets"
/// and "Limits on cost"), which scripts/measure-figures.sh runs with `MAW_MEASURE=1`. Each runs
/// the app's harness (`App/MawTerminalKit/Tests/FiguresHarness`, signed as the app by the
/// script) 5 times against the test daemon, with the test distribution running, and prints the
/// median and the 95th percentile as `FigureMeasurements` does.
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled && MawIntegration.environment["MAW_MEASURE"] == "1",
        "The measurements run only through scripts/measure-figures.sh."),
    .serialized,
    .timeLimit(.minutes(60))
)
struct AppFigureMeasurements {
    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    /// From the screen becoming visible to the first figures, and to the first CPU figure.
    @Test func measuresTheAppsFirstFigures() async throws {
        let session = try await heldSession()
        defer { session.stop() }
        var values: [String: [Double]] = [:]
        for _ in 0..<FigureMeasurements.runs {
            try await harness(["first-figures", maw.distribution], into: &values)
            // The daemon notes the end of the watch before the next one starts at once.
            try await Task.sleep(for: .seconds(2))
        }
        FigureMeasurements.report(
            "the app: first figures from the screen becoming visible",
            values["first-figures"] ?? [], unit: "ms", target: "< 500")
        FigureMeasurements.report(
            "the app: first CPU figure from the screen becoming visible",
            values["first-cpu"] ?? [], unit: "ms", target: "< 3000")
    }

    /// From just before `maw --terminate` to the app provider's new state.
    @Test func measuresAStateChangeInTheApp() async throws {
        var values: [String: [Double]] = [:]
        for _ in 0..<FigureMeasurements.runs {
            let session = try await heldSession()
            try await harness(
                ["state-change", maw.distribution, maw.maw.path(percentEncoded: false)],
                into: &values)
            session.stop()
            try await Task.sleep(for: .seconds(2))
        }
        FigureMeasurements.report(
            "the app: a state change by maw --terminate, to the provider",
            values["state-change"] ?? [], unit: "ms", target: "< 500")
    }

    /// The app's CPU over 60 s with the screen visible and one distribution running, above
    /// its cost with another tab selected.
    @Test func measuresTheAppsCost() async throws {
        let session = try await heldSession()
        defer { session.stop() }
        var values: [String: [Double]] = [:]
        for _ in 0..<FigureMeasurements.runs {
            try await harness(["cost", maw.distribution], into: &values, timeout: .seconds(300))
        }
        FigureMeasurements.report(
            "the app's CPU above its cost with the screen hidden, % of one core (< 1)",
            values["cost-above-hidden"] ?? [], unit: "", target: "")
        FigureMeasurements.report(
            "the app's CPU with the screen visible, % of one core", values["cost-shown"] ?? [],
            unit: "", target: "")
        FigureMeasurements.report(
            "the app's CPU with the screen hidden, % of one core", values["cost-hidden"] ?? [],
            unit: "", target: "")
    }

    /// Three windows that show the screen make one watch, and hiding them ends it.
    @Test func checksOneWatchForThreeWindows() async throws {
        var values: [String: [Double]] = [:]
        try await harness(["windows", "3"], into: &values)
        let pid = try #require(values["pid"]?.first.map { Int32($0) })
        #expect(values["windows-visible"] == [3])
        // The whole log: the harness's process ID appears in no earlier line.
        let log = try String(
            contentsOf: maw.logDirectory.appending(path: "mawd.log"), encoding: .utf8)
        let lines = log.split(separator: "\n").map(String.init)
        let started = lines.filter {
            $0.hasSuffix("process \(pid) started watching the distributions")
        }
        let stopped = lines.filter {
            $0.hasSuffix("process \(pid) stopped watching the distributions")
        }
        #expect(started.count == 1 && stopped.count == 1, "\(lines.suffix(20))")
        print(
            "measurement: the app with 3 windows showing the screen: \(started.count) watch "
                + "started, \(stopped.count) ended after the screens were hidden")
    }

    // MARK: Helpers

    /// Runs the harness once and adds each `value: <name> <number>` line to `values`.
    private func harness(
        _ arguments: [String], into values: inout [String: [Double]],
        timeout: Duration = .seconds(60)
    ) async throws {
        let path = try #require(
            MawIntegration.environment["MAW_FIGURES_HARNESS_PATH"],
            "MAW_FIGURES_HARNESS_PATH must point to the signed harness.")
        let run = try DebugBootProcess(
            executable: URL(filePath: path), arguments: arguments, separateStandardError: true,
            environment: maw.mawEnvironment)
        let result = await run.waitForExit(timeout: timeout)
        try #require(
            result.status == 0, "harness \(arguments): \(result.output)\(run.standardError)")
        // The output can arrive after the exit; "done" is the harness's last line.
        let complete = await maw.eventually(within: .seconds(5)) {
            DebugBootProcess.lines(of: run.output).contains("done")
        }
        try #require(complete, "harness \(arguments) ended without done: \(run.output)")
        var found = false
        for line in DebugBootProcess.lines(of: run.output) where line.hasPrefix("value: ") {
            let words = line.dropFirst("value: ".count).split(separator: " ")
            if words.count == 2, let number = Double(words[1]) {
                values[String(words[0]), default: []].append(number)
                found = true
            }
        }
        try #require(found, "harness \(arguments) gave no value: \(run.output)")
    }

    /// A session in the test distribution, which keeps its machine running.
    private func heldSession() async throws -> IntegrationProbe {
        let session = try IntegrationProbe(maw: maw)
        try #require(
            await session.result(1)?.hasPrefix("started ") == true, "\(session.transcript)")
        return session
    }
}
