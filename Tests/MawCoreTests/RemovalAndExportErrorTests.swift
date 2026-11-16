import Foundation
import MawCore
import Testing

/// The errors of `maw --unregister` and `maw --export`.
@Suite struct RemovalAndExportErrorTests {
    /// A name of 12 characters, the width that every line must fit with, as the phase 06b
    /// prompt requires.
    static let name = try! DistroName("Ubuntu-24.04")

    static let errors: [MawError] = [
        .distributionBusy(name, operation: .export),
        .distributionBusy(name, operation: .removal),
        .distributionBusy(name, operation: .install),
        .distributionRunning(name),
        .unregisterDeclined(name),
        .removalFailed(name, reason: "Operation not permitted"),
        .exportFileExists(path: "ubuntu.tar"),
        .exportToTerminal,
        .exportOutputNotWritable,
        .exportFailed(name, step: "checking the disk", reason: "e2fsck could not start"),
        .exportOutputClosed(name),
        .exportCancelled(name),
    ]

    @Test(arguments: errors)
    func survivesAJSONRoundTrip(_ error: MawError) throws {
        let decoded = try JSONDecoder().decode(
            MawError.self, from: try JSONEncoder().encode(error))
        #expect(decoded == error)
    }

    /// Every line, `maw: ` included, fits in 80 columns with a name of 12 characters. The
    /// reason of `removalFailed` and `exportFailed`, and the path of `exportFileExists`, come
    /// from elsewhere and can be of any length; the lines that maw itself words are checked.
    @Test(arguments: errors)
    func fitsEveryLineIn80Columns(_ error: MawError) {
        let text =
            "maw: " + (error.errorDescription ?? "") + "\n" + (error.recoverySuggestion ?? "")
        for line in text.split(separator: "\n") {
            #expect(line.count <= 80, "\(line.count): \(line)")
        }
    }

    /// Each suggestion names only commands of this build, and never asks to delete files by
    /// hand.
    @Test(arguments: errors)
    func suggestsNoStepThatThisBuildLacks(_ error: MawError) {
        let suggestion = error.recoverySuggestion ?? ""
        #expect(!suggestion.contains("rm "))
        #expect(!suggestion.contains("README"))
        #expect(!suggestion.contains("--import"))
    }

    @Test func namesTheOperationThatHoldsTheName() {
        #expect(
            MawError.distributionBusy(Self.name, operation: .export).errorDescription
                == "Ubuntu-24.04 is being exported by maw --export.")
        #expect(
            MawError.distributionBusy(Self.name, operation: .removal).errorDescription
                == "Ubuntu-24.04 is being removed by maw --unregister.")
        #expect(
            MawError.distributionBusy(Self.name, operation: .removal).recoverySuggestion
                == "Wait until maw --unregister has finished, then run the command again.")
    }

    @Test func suggestsTerminatingARunningDistribution() {
        let error = MawError.distributionRunning(Self.name)
        #expect(
            error.errorDescription
                == "Ubuntu-24.04 is not stopped; only a stopped distribution can be exported."
        )
        #expect(error.recoverySuggestion?.contains("maw --terminate Ubuntu-24.04") == true)
    }

    @Test func namesTheExportLogOfTheDistribution() {
        let error = MawError.exportFailed(
            Self.name, step: "writing the archive", reason: "No space left on device")
        #expect(
            error.errorDescription
                == "The export of Ubuntu-24.04 failed while writing the archive:\n"
                + "No space left on device.")
        #expect(
            error.recoverySuggestion?.contains("~/Library/Logs/maw/export/Ubuntu-24.04.log") == true
        )
    }
}

@Suite struct DistributionOperationTests {
    @Test func namesTheCommandOfEachOperation() {
        #expect(
            DistributionOperation.allCases.map(\.command) == [
                "maw --install", "maw --export", "maw --unregister", "maw --import",
            ])
    }

    /// The raw values travel in the daemon's messages and never change.
    @Test func keepsItsRawValues() {
        #expect(
            DistributionOperation.allCases.map(\.rawValue) == [
                "install", "export", "removal", "import",
            ])
    }

    /// An installation and an import create the distribution and start its machine
    /// themselves; an export and a removal do neither.
    @Test func tellsWhichOperationsCreateTheDistribution() {
        #expect(
            DistributionOperation.allCases.filter(\.createsTheDistribution) == [.install, .import])
    }
}
