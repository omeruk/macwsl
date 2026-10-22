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
        .guestCommandNotFound(command: "nope", reason: "not in PATH"),
        .virtualizationEntitlementMissing,
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

    @Test func suggestsReinstallingTheDaemonOnAVersionMismatch() {
        let error = MawError.daemonVersionMismatch(client: 2, daemon: 1)
        #expect(
            error.errorDescription
                == "The maw daemon speaks interface version 1, but this maw speaks version 2.")
        #expect(error.recoverySuggestion?.contains("mawd install") == true)
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
