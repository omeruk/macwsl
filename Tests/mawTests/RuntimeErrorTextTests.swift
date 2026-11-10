import Foundation
import MawClient
import MawCore
import Testing

@testable import maw

/// The terminal app renders errors with `runtimeErrorText(_:)` from `MawClient`, so that it
/// keeps no copy of maw's format. These tests hold the two together byte for byte.
@Suite struct RuntimeErrorTextTests {
    @Test(arguments: [
        // A message of two lines and a suggestion of one.
        MawError.machineStopped(machine: "Ubuntu-24.04", reason: "maw --terminate was run"),
        // A message of two lines and a suggestion of three.
        .sessionConnectionEnded(distribution: "Ubuntu-24.04"),
        // A message and a suggestion of one line each, the app's notice without a daemon.
        .daemonNotInstalled(label: "dev.maw.mawd"),
        // No suggestion.
        .launchAgentFailed(reason: "launchctl bootstrap exited with status 5"),
    ])
    func matchesWhatMawPrints(error: MawError) throws {
        let failure = try #require(Maw.failure(for: error))
        #expect(Array(runtimeErrorText(error).utf8) == Array(failure.output.utf8))
    }

    /// A message of one line and a suggestion of two.
    @Test func matchesWhatMawPrintsForATwoLineSuggestion() throws {
        let error = MawError.installationCancelled(try DistroName("Ubuntu-24.04"))
        let failure = try #require(Maw.failure(for: error))
        #expect(Array(runtimeErrorText(error).utf8) == Array(failure.output.utf8))
    }

    @Test func endsInOneLineFeed() {
        let text = runtimeErrorText(MawError.launchAgentFailed(reason: "it failed"))
        #expect(text == "maw: The maw LaunchAgent could not be changed: it failed.\n")
    }
}
