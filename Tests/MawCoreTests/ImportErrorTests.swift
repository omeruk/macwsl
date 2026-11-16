import Foundation
import MawCore
import Testing

/// The errors of `maw --import`.
@Suite struct ImportErrorTests {
    /// A name of 12 characters, the width that every line must fit with, as the phase 06b
    /// prompt requires.
    static let name = try! DistroName("Ubuntu-24.04")

    static let errors: [MawError] = [
        .importArchiveNotReadable(path: "ubuntu.tar", reason: "No such file or directory"),
        .importFromTerminal,
        .importInputNotReadable,
        .importNotARootFileSystem(name, found: "its top level holds only the directory rootfs/"),
        .importInitNotSystemd(name, reason: "/sbin/init is /bin/busybox"),
        .importPathNotResolvable(name, path: "/etc/netplan", reason: "its links form a loop"),
        .importFailed(name, step: "extracting the archive", reason: "Truncated tar archive"),
        .importCancelled(name),
        .importStartFailed(
            name, consoleLog: "~/Library/Logs/maw/Ubuntu-24.04.log",
            reason: "the guest agent did not answer"),
        .distributionBusy(name, operation: .import),
        .userNotFound("ayse", distribution: DefaultUserChoice.archiveDescription),
    ]

    @Test(arguments: errors)
    func survivesAJSONRoundTrip(_ error: MawError) throws {
        let decoded = try JSONDecoder().decode(
            MawError.self, from: try JSONEncoder().encode(error))
        #expect(decoded == error)
    }

    /// Every line, `maw: ` included, fits in 80 columns with a name of 12 characters. The
    /// reasons, the paths, and what the archive holds come from elsewhere and can be of any
    /// length; the samples above are of a typical length.
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
    func suggestsNoStepByHand(_ error: MawError) {
        let suggestion = error.recoverySuggestion ?? ""
        #expect(!suggestion.contains("rm "))
        #expect(!suggestion.contains("README"))
    }

    /// The console log comes before `maw --unregister`, which deletes it.
    @Test func namesTheConsoleLogBeforeTheRemoval() throws {
        let error = MawError.importStartFailed(
            Self.name, consoleLog: "/Users/ayse/Library/Logs/maw/Ubuntu-24.04.log",
            reason: "the guest agent did not answer within 30 seconds")
        #expect(
            error.errorDescription
                == "Ubuntu-24.04 was imported, but its first start failed:\n"
                + "the guest agent did not answer within 30 seconds.")
        let suggestion = try #require(error.recoverySuggestion)
        let log = try #require(
            suggestion.range(of: "/Users/ayse/Library/Logs/maw/Ubuntu-24.04.log"))
        let removal = try #require(suggestion.range(of: "maw --unregister Ubuntu-24.04"))
        #expect(log.upperBound < removal.lowerBound)
    }

    @Test func namesTheImportThatHoldsTheName() {
        #expect(
            MawError.distributionBusy(Self.name, operation: .import).errorDescription
                == "Ubuntu-24.04 is being imported by maw --import.")
    }

    @Test func saysWhatTheArchiveHoldsInsteadOfARootFileSystem() {
        #expect(
            MawError.importNotARootFileSystem(
                Self.name, found: "its top level holds only the directory rootfs/"
            ).errorDescription
                == "The archive for Ubuntu-24.04 holds no root file system at its top level:\n"
                + "its top level holds only the directory rootfs/.")
    }

    @Test func namesTheImportLogOfTheDistribution() {
        let error = MawError.importFailed(
            Self.name, step: "extracting the archive", reason: "Truncated tar archive")
        #expect(
            error.errorDescription
                == "The import of Ubuntu-24.04 failed while extracting the archive:\n"
                + "Truncated tar archive.")
        #expect(
            error.recoverySuggestion?.contains("~/Library/Logs/maw/install/Ubuntu-24.04.log")
                == true)
    }

    /// `userNotFound` serves sessions and imports alike.
    @Test func suggestsWhereAMissingUserComesFrom() {
        let error = MawError.userNotFound(
            "ayse", distribution: DefaultUserChoice.archiveDescription)
        #expect(error.errorDescription == "There is no user named 'ayse' in the archive.")
        #expect(error.recoverySuggestion?.contains("sudo adduser") == true)
        #expect(error.recoverySuggestion?.contains("the archive's /etc/passwd") == true)
    }
}
