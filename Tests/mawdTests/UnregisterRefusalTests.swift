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
