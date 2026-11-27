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

    @Test func acceptsLeavingOutForwarding() throws {
        #expect(failure("serve", "--without-forwarding") == nil)
        let command = try Mawd.parseAsRoot(["serve", "--without-forwarding"])
        #expect((command as? Serve)?.withoutForwarding == true)
        #expect((try Mawd.parseAsRoot(["serve"]) as? Serve)?.withoutForwarding == false)
    }

    @Test func acceptsLeavingOutDNS() throws {
        #expect(failure("serve", "--without-dns") == nil)
        let command = try Mawd.parseAsRoot(["serve", "--without-dns"])
        #expect((command as? Serve)?.withoutDNS == true)
        #expect((try Mawd.parseAsRoot(["serve"]) as? Serve)?.withoutDNS == false)
    }

    /// `mawd install` accepts neither option, so neither can reach the LaunchAgent.
    @Test func installRejectsTheMeasurementOptions() {
        #expect(failure("install", "--sample-interval-ms", "100") != nil)
        #expect(failure("install", "--sample-with-info") != nil)
        #expect(failure("install", "--without-mac-share") != nil)
        #expect(failure("install", "--without-forwarding") != nil)
        #expect(failure("install", "--without-dns") != nil)
    }
}
