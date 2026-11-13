import Testing

@testable import mawd

/// The hidden option of `mawd serve` for the measurements.
@Suite struct ServeOptionsTests {
    private func failure(_ arguments: String...) -> String? {
        do {
            _ = try Mawd.parseAsRoot(arguments)
            return nil
        } catch {
            return Mawd.message(for: error)
        }
    }

    @Test func acceptsASampleIntervalOfAtLeast100Milliseconds() throws {
        #expect(failure("serve", "--sample-interval-ms", "100") == nil)
        #expect(
            failure("serve", "--sample-interval-ms", "99")
                == "--sample-interval-ms must be at least 100.")
    }

    @Test func acceptsSamplingWithInfo() {
        #expect(failure("serve", "--sample-with-info") == nil)
    }

    /// `mawd install` accepts neither option, so neither can reach the LaunchAgent.
    @Test func installRejectsTheMeasurementOptions() {
        #expect(failure("install", "--sample-interval-ms", "100") != nil)
        #expect(failure("install", "--sample-with-info") != nil)
    }
}
