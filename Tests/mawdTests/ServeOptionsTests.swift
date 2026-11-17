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

    @Test func acceptsLeavingOutTheMacShare() throws {
        #expect(failure("serve", "--without-mac-share") == nil)
        let command = try Mawd.parseAsRoot(["serve", "--without-mac-share"])
        #expect((command as? Serve)?.withoutMacShare == true)
        #expect((try Mawd.parseAsRoot(["serve"]) as? Serve)?.withoutMacShare == false)
    }

    /// `mawd install` accepts neither option, so neither can reach the LaunchAgent.
    @Test func installRejectsTheMeasurementOptions() {
        #expect(failure("install", "--sample-interval-ms", "100") != nil)
        #expect(failure("install", "--sample-with-info") != nil)
        #expect(failure("install", "--without-mac-share") != nil)
    }
}
