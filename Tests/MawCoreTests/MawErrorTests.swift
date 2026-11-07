import Foundation
import MawCore
import Testing

@Suite struct MawErrorTests {
    static let errors: [MawError] = [
        .notImplemented(feature: "--list", phase: "06"),
        .distributionNotInstalled(try! DistroName("Ubuntu")),
        .unsupportedDirectory("projects"),
        .daemonNotInstalled(label: "dev.maw.mawd"),
        .daemonUnreachable(reason: "launchd could not start it"),
        .daemonConnectionLost(during: "the session"),
        .daemonVersionMismatch(client: 2, daemon: 1),
        .daemonProtocolError(reason: "the reply is not valid JSON"),
        .clientSignatureRejected(identifier: "maw-5555"),
        .machineStopped(machine: "initramfs", reason: "maw --shutdown was run"),
        .launchAgentFailed(reason: "launchctl bootstrap failed"),
        .launchctlTimedOut(command: "launchctl bootout gui/501/dev.maw.mawd", seconds: 60),
        .launchAgentNotRemoved(service: "gui/501/dev.maw.mawd", seconds: 30),
        .guestCommandNotFound(command: "nope", reason: "not in PATH"),
        .virtualizationEntitlementMissing,
        .rootFileSystemCheckFailed(
            distribution: try! DistroName("Ubuntu"), e2fsckStatus: 8, diskImage: "/d/disk.img",
            consoleLog: "/l/Ubuntu.log"),
    ]

    @Test(arguments: errors)
    func survivesAJSONRoundTrip(_ error: MawError) throws {
        let data = try JSONEncoder().encode(error)
        #expect(try JSONDecoder().decode(MawError.self, from: data) == error)
    }

    @Test func namesThePhaseOfAMissingFeature() {
        let error = MawError.notImplemented(feature: "--list", phase: "06")
        #expect(error.errorDescription == "--list is not implemented yet; phase 06 adds it.")
        #expect(error.recoverySuggestion == nil)
    }

    @Test func suggestsInstallingAMissingDistribution() throws {
        let error = MawError.distributionNotInstalled(try DistroName("Ubuntu"))
        #expect(error.errorDescription == "No distribution named 'Ubuntu' is installed.")
        #expect(error.recoverySuggestion == "Install it with maw --install Ubuntu.")
    }

    @Test func explainsThatPathTranslationIsMissing() {
        let error = MawError.unsupportedDirectory("projects")
        #expect(
            error.errorDescription
                == "--cd needs an absolute Linux path, such as /root, but 'projects' is not one.")
        #expect(error.recoverySuggestion?.contains("phase 07") == true)
    }

    @Test func suggestsInstallingTheDaemon() {
        let error = MawError.daemonNotInstalled(label: "dev.maw.mawd")
        #expect(
            error.errorDescription
                == "The maw daemon is not installed: launchd has no LaunchAgent named "
                + "dev.maw.mawd.")
        #expect(error.recoverySuggestion == "Register the daemon with mawd install.")
    }

    @Test(arguments: [
        MawError.daemonUnreachable(reason: "x"), .daemonConnectionLost(during: "x"),
        .daemonProtocolError(reason: "x"),
    ])
    func pointsToTheDaemonsLog(_ error: MawError) {
        #expect(error.recoverySuggestion?.contains("~/Library/Logs/maw/mawd.log") == true)
    }

    @Test func namesTheCommandsForAJobThatLaunchdHasNotRemoved() {
        let error = MawError.launchAgentNotRemoved(service: "gui/501/dev.maw.mawd", seconds: 30)
        #expect(
            error.errorDescription
                == "launchd had not removed gui/501/dev.maw.mawd 30 seconds after launchctl "
                + "bootout, so it could not be loaded again.")
        #expect(
            error.recoverySuggestion?.contains("launchctl print gui/501/dev.maw.mawd") == true)
        #expect(error.recoverySuggestion?.contains("mawd install") == true)
    }

    @Test func suggestsReinstallingTheDaemonOnAVersionMismatch() {
        let error = MawError.daemonVersionMismatch(client: 2, daemon: 1)
        #expect(
            error.errorDescription
                == "The maw daemon speaks interface version 1, but this maw speaks version 2.")
        #expect(error.recoverySuggestion?.contains("mawd install") == true)
    }

    /// A host and guest files from different builds fail at the handshake with the fix named.
    @Test func namesTheGuestFilesFixOnAProtocolMismatch() {
        let error = MawError.guestAgentVersionMismatch(host: 3, guest: 2)
        #expect(
            error.errorDescription
                == "The guest agent speaks protocol version 2, but this build of maw speaks "
                + "version 3.")
        #expect(
            error.recoverySuggestion
                == "The guest files come from another build of maw. Install guest files built "
                + "from the same commit: fetch them with scripts/fetch-guest.sh, or rebuild them "
                + "as Guest/README.md describes.")
    }

    @Test func namesTheCauseAndAFixOfAFailedDialBack() {
        let failed = MawError.sessionDialBackFailed(reason: "no source port below 1024 is free")
        #expect(
            failed.errorDescription
                == "The guest agent could not connect to maw for the session: no source port "
                + "below 1024 is free.")
        #expect(
            failed.recoverySuggestion
                == "Run the command again. If it fails again, restart the virtual machines with "
                + "maw --shutdown; the console log in ~/Library/Logs/maw has the agent's warning.")

        let missing = MawError.sessionDialBackMissing(milliseconds: 5000)
        #expect(
            missing.errorDescription
                == "The guest agent reported that it connected to maw for the session, but no "
                + "connection with the session's nonce arrived within 5000 ms.")
        #expect(
            missing.recoverySuggestion
                == "Run the command again. If it fails again, restart the virtual machines with "
                + "maw --shutdown; the virtual machine's console log in ~/Library/Logs/maw lists "
                + "the connections that were refused.")

        let busy = MawError.sessionDialBackBusy(limit: 64)
        #expect(
            busy.errorDescription
                == "64 sessions are already waiting for a connection from this virtual machine's "
                + "agent.")
        #expect(
            busy.recoverySuggestion
                == "Wait for other sessions to start, then run the command again.")
    }

    @Test func namesALeftoverDistributionDirectoryAndLeavesItToTheUser() {
        let error = MawError.distributionDirectoryExists(path: "/maw/distros/Work")
        #expect(
            error.errorDescription
                == "/maw/distros/Work already exists, but it holds no installed distribution: its "
                + "distro.json is missing.")
        #expect(
            error.recoverySuggestion
                == "maw leaves the directory as it is, because it may hold a distribution's "
                + "disk.img. Move it elsewhere, or delete it if you no longer need what it holds, "
                + "then run maw --install again. Or install under another name with --name.")
    }

    @Test func namesTheSigningScriptForARejectedSignature() {
        let error = MawError.clientSignatureRejected(identifier: "maw-5555")
        #expect(error.recoverySuggestion?.contains("scripts/sign-dev.sh") == true)
    }

    @Test func namesTheSigningScriptAndInstallForAMissingEntitlement() {
        #expect(
            MawError.virtualizationEntitlementMissing.errorDescription
                == "mawd is not signed with the virtualization entitlement "
                + "(com.apple.security.virtualization), so it cannot create virtual machines.")
        let suggestion = MawError.virtualizationEntitlementMissing.recoverySuggestion ?? ""
        #expect(suggestion.contains("scripts/sign-dev.sh"))
        #expect(suggestion.contains("mawd install"))
    }

    @Test func saysWhyTheMachineStopped() {
        let error = MawError.machineStopped(machine: "initramfs", reason: "maw --shutdown was run")
        #expect(
            error.errorDescription
                == "The session ended because the virtual machine initramfs stopped: "
                + "maw --shutdown was run.")
    }

    // MARK: A root file system that failed its check

    static let disk = "/Users/ayse/Library/Application Support/maw/distros/Ubuntu/disk.img"
    static let consoleLog = "/Users/ayse/Library/Logs/maw/Ubuntu.log"

    static func rootCheckFailure(_ status: Int) -> MawError {
        .rootFileSystemCheckFailed(
            distribution: try! DistroName("Ubuntu"), e2fsckStatus: status, diskImage: disk,
            consoleLog: consoleLog)
    }

    @Test(arguments: [4, 5, 6, 7])
    func reportsErrorsThatE2fsckLeftUncorrected(_ status: Int) {
        #expect(
            Self.rootCheckFailure(status).errorDescription
                == "The file system of Ubuntu could not be repaired automatically: e2fsck found "
                + "errors that it left uncorrected (exit status \(status)). Ubuntu was not "
                + "started; its console log, \(Self.consoleLog), has the details.")
    }

    /// Status 8 does not establish that the file system has errors: e2fsck also reports it
    /// for a disk that it cannot open or a superblock that it cannot read.
    @Test(arguments: [8, 12])
    func reportsACheckThatStoppedWithAnOperationalError(_ status: Int) {
        let description = Self.rootCheckFailure(status).errorDescription ?? ""
        #expect(
            description
                == "The file system of Ubuntu could not be checked automatically: e2fsck "
                + "stopped with an operational error (exit status \(status)), as it does, for "
                + "example, when it cannot open the disk or read its superblock. Ubuntu was not "
                + "started; its console log, \(Self.consoleLog), has the details.")
        #expect(!description.contains("damaged"))
        #expect(!description.contains("has errors"))
    }

    @Test(arguments: [16, 32, 127, 128, 137])
    func reportsACheckThatDidNotComplete(_ status: Int) {
        let description = Self.rootCheckFailure(status).errorDescription ?? ""
        #expect(
            description
                == "The file system of Ubuntu could not be checked automatically: e2fsck ended "
                + "with exit status \(status) and did not complete the check. Ubuntu was not "
                + "started; its console log, \(Self.consoleLog), has the details.")
        #expect(!description.contains("damaged"))
    }

    /// The suggestion says that the image is kept, that it should be copied first, and that
    /// no repair command exists yet, whatever the status.
    @Test(arguments: [4, 8, 16])
    func suggestsKeepingACopyOfTheDiskImage(_ status: Int) {
        #expect(
            Self.rootCheckFailure(status).recoverySuggestion
                == "maw keeps the disk image \(Self.disk) and has not written to it; only "
                + "e2fsck -p may have repaired parts of it before it stopped. Copy the image to "
                + "a safe place before you try any repair by hand. maw has no command to repair "
                + "a file system yet; a later phase adds one. If you do not need the "
                + "distribution's files, the README explains how to remove it, after which "
                + "maw --install can install it again.")
    }

    @Test func endsAMessageWithOnePeriod() {
        let error = MawError.fileNotAccessible(
            path: "/tmp/distro.json",
            reason: "The data couldn’t be read because it isn’t in the correct format.")
        #expect(
            error.errorDescription
                == "The file /tmp/distro.json cannot be used: The data couldn’t be read because "
                + "it isn’t in the correct format.")
    }
}

@Suite struct MachineIDTests {
    @Test func namesEachMachine() throws {
        #expect(MachineID.initramfs.name == "initramfs")
        #expect(MachineID.distribution(try DistroName("Ubuntu-24.04")).name == "Ubuntu-24.04")
    }

    @Test(arguments: [MachineID.initramfs, .distribution(try! DistroName("Ubuntu"))])
    func survivesAJSONRoundTrip(_ machine: MachineID) throws {
        let data = try JSONEncoder().encode(machine)
        #expect(try JSONDecoder().decode(MachineID.self, from: data) == machine)
    }
}
