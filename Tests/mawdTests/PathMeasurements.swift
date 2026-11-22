import Darwin
import Foundation
import MawCore
import Testing

/// The measurements of `prompts/07-file-sharing-and-paths.md`, "Speed targets", for pull request
/// B, which scripts/measure-paths.sh runs through scripts/integration-test.sh with
/// `MAW_MEASURE=1`. They never run with the other integration tests.
///
/// maw runs in a directory of `MawIntegration.withMacDirectory` under `~/Library/Caches/maw`,
/// which each measurement removes even on failure. Each measurement runs 5 times, after one
/// warm-up, and prints its median and its slowest run on a line that starts with
/// "measurement:".
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled && MawIntegration.environment["MAW_MEASURE"] == "1",
        "The measurements run only through scripts/measure-paths.sh."),
    .serialized,
    .timeLimit(.minutes(30))
)
struct PathMeasurements {
    static let runs = 5

    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    /// The warm start of `maw` to a prompt, from a directory under the home directory: the
    /// login shell starts through runuser -l and the shell helper.
    @Test func measuresTheWarmPrompt() async throws {
        try await maw.withMacDirectory { mac, _ in
            try await maw.inDirectory(mac.path(percentEncoded: false)) {
                #expect(try await maw.session(["-e", "true"]).status == 0)
                var times: [Double] = []
                for _ in 1...Self.runs {
                    let started = ContinuousClock.now
                    let session = try maw.interactive(["-d", maw.distribution])
                    #expect(
                        await session.waitForPrompt(
                            user: maw.user, host: maw.hostname(of: maw.distribution)))
                    times.append((ContinuousClock.now - started).fractionalMilliseconds)
                    session.type("exit\r")
                    _ = await session.waitForExit(timeout: .seconds(30))
                }
                let median = MawIntegration.report(
                    "warm maw to a prompt, from a directory under the home directory", times)
                #expect(median < 150)
            }
        }
    }

    @Test func measuresPwd() async throws {
        try await maw.withMacDirectory { mac, linux in
            try await maw.inDirectory(mac.path(percentEncoded: false)) {
                #expect(try await maw.session(["-e", "true"]).status == 0)
                var times: [Double] = []
                for _ in 1...Self.runs {
                    let (status, elapsed) = try await maw.timed(
                        ["-d", maw.distribution, "--", "pwd"])
                    #expect(status == 0)
                    times.append(elapsed)
                }
                MawIntegration.report(
                    "warm maw -- pwd, from a directory under the home directory", times)
                let shown = try await maw.run(["-d", maw.distribution, "--", "pwd"])
                #expect(shown.output == "\(linux)\n")
            }
        }
    }

    /// `mawpath` of one path, timed in the guest, as the default user.
    @Test func measuresMawpath() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let script =
            "mawpath '\(home)/Projects/app' > /dev/null; for i in 1 2 3 4 5; do"
            + " s=$(date +%s%N); mawpath '\(home)/Projects/app' > /dev/null;"
            + " e=$(date +%s%N); echo \"elapsed $((e - s))\"; done"
        let result = try await maw.run(["-d", maw.distribution, "-e", "sh", "-c", script])
        try #require(result.status == 0, "\(result.standardError)")
        let times = result.lines.filter { $0.hasPrefix("elapsed ") }.compactMap {
            Double($0.dropFirst("elapsed ".count)).map { $0 / 1e6 }
        }
        let median = MawIntegration.report("mawpath of one path, in the guest", times)
        #expect(times.count == Self.runs)
        #expect(median < 20)
    }
}
