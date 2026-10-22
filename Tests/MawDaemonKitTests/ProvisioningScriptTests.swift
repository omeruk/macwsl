import Foundation
import MawCore
import MawXPC
import Testing

@testable import MawDaemonKit

@Suite struct ProvisioningScriptTests {
    func configuration(hostname: String = "ubuntu-24-04", locale: String? = "tr_TR.UTF-8")
        throws -> GuestConfiguration
    {
        GuestConfiguration(
            hostname: hostname, user: try UserName("ayse"), password: Secret("never in argv"),
            locale: locale)
    }

    @Test func isValidShell() throws {
        let script = FileManager.default.temporaryDirectory.appending(
            path: "maw-provision-\(UUID().uuidString).sh")
        try ProvisioningScript.text.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-n", script.path(percentEncoded: false)]
        try shell.run()
        shell.waitUntilExit()
        #expect(shell.terminationStatus == 0)
    }

    @Test func passesValuesAsArgumentsAndNeverThePassword() throws {
        let arguments = try ProvisioningScript.arguments(for: configuration(), linger: true)
        #expect(arguments == ["ubuntu-24-04", "ayse", "tr_TR.UTF-8", "yes"])
        #expect(!ProvisioningScript.text.contains("never in argv"))
        #expect(!ProvisioningScript.text.contains("chpasswd"))
    }

    @Test func dropsALocaleItCannotUse() throws {
        for locale in [nil, "tr_TR.ISO-8859-9", "x; rm -rf /", "tr_TR.UTF-8\n"] as [String?] {
            #expect(
                try ProvisioningScript.arguments(for: configuration(locale: locale), linger: false)
                    == ["ubuntu-24-04", "ayse", "", "no"])
        }
    }

    @Test(arguments: ["", "-x", "Upper", "a b", "a;b", String(repeating: "a", count: 64)])
    func refusesAnInvalidHostName(_ hostname: String) {
        #expect(throws: MawError.self) {
            try ProvisioningScript.arguments(for: configuration(hostname: hostname), linger: true)
        }
    }

    @Test func masksTheServicesThatServeNoPurpose() {
        let masked = Set(ProvisioningScript.maskedUnits)
        for unit in [
            "cloud-init.service", "snapd.service", "snapd.socket",
            "systemd-networkd-wait-online.service", "serial-getty@hvc0.service",
        ] {
            #expect(masked.contains(unit), "\(unit)")
        }
        // Security updates, the clock, DNS, and the network stay.
        for unit in [
            "unattended-upgrades.service", "apt-daily.timer", "systemd-timesyncd.service",
            "systemd-resolved.service", "systemd-networkd.service", "fstrim.timer",
        ] {
            #expect(!masked.contains(unit), "\(unit)")
        }
        #expect(masked.count == ProvisioningScript.maskedUnits.count)
    }
}
