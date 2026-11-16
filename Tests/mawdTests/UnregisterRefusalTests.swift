import Testing

/// The integration tests' rule for the names they may unregister
/// (`MawIntegration.unregisterRefusal`). The test daemon shares the owner's distributions, so
/// the rule runs in CI, without a daemon.
@Suite struct UnregisterRefusalTests {
    static let prefix = "maw-it-1763164800"
    static let created: Set<String> = ["maw-it-1763164800-copy", "maw-it-1763164800-stopped"]

    @Test(arguments: ["maw-it-1763164800-copy", "maw-it-1763164800-stopped"])
    func allowsANameThisProcessCreated(_ name: String) {
        #expect(
            MawIntegration.unregisterRefusal(
                of: name, prefix: Self.prefix, created: Self.created) == nil)
    }

    /// The owner's names, the shared test distribution, another run's names, and names that only
    /// resemble the prefix are all refused.
    @Test(arguments: [
        "Ubuntu-24.04", "Copy", "maw-it-1763164800-shared", "maw-it-1763164800-other",
        "maw-it-1763164799-copy", "MAW-IT-1763164800-COPY", "maw-it-1763164800",
        "maw-it-1763164800-",
        "maw-it-17631648000-copy", "x-maw-it-1763164800-copy",
    ])
    func refusesEveryOtherName(_ name: String) {
        #expect(
            MawIntegration.unregisterRefusal(
                of: name, prefix: Self.prefix, created: Self.created) != nil)
    }

    /// A prefix without the run's form refuses every name, even one in the set.
    @Test(arguments: ["", "maw-it-", "Ubuntu", "maw-it-x", "maw-it-1763164800-copy"])
    func refusesEveryNameUnderAnotherPrefix(_ prefix: String) {
        #expect(
            MawIntegration.unregisterRefusal(
                of: "\(prefix)-copy", prefix: prefix, created: ["\(prefix)-copy"]) != nil)
    }
}

/// The line of a measurement (`MawIntegration.reportLine`), which runs in CI without a daemon.
@Suite struct MeasurementReportTests {
    @Test func namesTheLongestTimeAsTheSlowest() {
        let (line, median) = MawIntegration.reportLine("an export", [7_400, 7_300, 7_500])
        #expect(
            line
                == "measurement: an export, 3 runs: 7400, 7300, 7500 ms; median 7400 ms, slowest 7500 ms"
        )
        #expect(median == 7_400)
    }

    /// For a throughput, the slowest run is the lowest figure.
    @Test func namesTheLowestThroughputAsTheSlowest() {
        let (line, _) = MawIntegration.reportLine(
            "a throughput", [181, 179, 183], unit: "MB/s", higherIsFaster: true)
        #expect(
            line
                == "measurement: a throughput, 3 runs: 181, 179, 183 MB/s; median 181 MB/s, slowest 179 MB/s"
        )
    }
}
