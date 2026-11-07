import Foundation
import MawCore
import MawTestSupport
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

    @Test func isValidShell() async throws {
        let script = FileManager.default.temporaryDirectory.appending(
            path: "maw-provision-\(UUID().uuidString).sh")
        try ProvisioningScript.text.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-n", script.path(percentEncoded: false)]
        try shell.run()
        try #require(await shell.waitForExit(within: .seconds(30)))
        #expect(shell.terminationStatus == 0)
    }

    /// The script writes `/etc/maw.conf` with a `printf` of its own, from the shell variable
    /// `$user`. Run with `/bin/sh`, that command must write exactly `MawConf.contents`, the
    /// text that `MawConf` reads back (`MawConfTests`), so that the two cannot diverge.
    @Test(arguments: ["ayse", "build-bot_1$"])
    func writesTheMawConfThatMawConfDescribes(_ user: String) async throws {
        let lines = ProvisioningScript.text.split(separator: "\n", omittingEmptySubsequences: false)
        let start = try #require(lines.firstIndex { $0.contains("> \"$root/etc/maw.conf\"") })
        // The command, with the lines it continues from.
        var first = start
        while first > lines.startIndex, lines[first - 1].hasSuffix("\\") {
            first -= 1
        }
        let command = lines[first...start].joined(separator: "\n")
        try #require(command.contains("printf"), "\(command)")

        let root = FileManager.default.temporaryDirectory.appending(
            path: "maw-root-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root.appending(path: "etc"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = [
            "-c", "user=$1 root=$2\n\(command)", "sh", user, root.path(percentEncoded: false),
        ]
        try shell.run()
        try #require(await shell.waitForExit(within: .seconds(30)))
        #expect(shell.terminationStatus == 0)

        let written = try String(
            contentsOf: root.appending(path: "etc/maw.conf"), encoding: .utf8)
        #expect(written == MawConf.contents(defaultUser: try UserName(user)))
        #expect(MawConf(parsing: written).defaultUser == user)
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
