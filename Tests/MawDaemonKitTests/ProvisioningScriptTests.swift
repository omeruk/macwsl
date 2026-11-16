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

    @Test(arguments: [
        ProvisioningScript.text, ProvisioningScript.mawConfWriter, ImportInspection.script,
    ])
    func isValidShell(_ script: String) async throws {
        let file = FileManager.default.temporaryDirectory.appending(
            path: "maw-provision-\(UUID().uuidString).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-n", file.path(percentEncoded: false)]
        try shell.run()
        try #require(await shell.waitForExit(within: .seconds(30)))
        #expect(shell.terminationStatus == 0)
    }

    @Test func passesValuesAsArgumentsAndNeverThePassword() throws {
        let arguments = try ProvisioningScript.arguments(for: configuration(), linger: true)
        #expect(
            arguments == ["/mnt/root", "install", "ubuntu-24-04", "ayse", "tr_TR.UTF-8", "yes"])
        #expect(!ProvisioningScript.text.contains("never in argv"))
        #expect(!ProvisioningScript.text.contains("chpasswd"))
    }

    @Test func dropsALocaleItCannotUse() throws {
        for locale in [nil, "tr_TR.ISO-8859-9", "x; rm -rf /", "tr_TR.UTF-8\n"] as [String?] {
            #expect(
                try ProvisioningScript.arguments(for: configuration(locale: locale), linger: false)
                    == ["/mnt/root", "install", "ubuntu-24-04", "ayse", "", "no"])
        }
    }

    @Test(arguments: ["", "-x", "Upper", "a b", "a;b", String(repeating: "a", count: 64)])
    func refusesAnInvalidHostName(_ hostname: String) {
        #expect(throws: MawError.self) {
            try ProvisioningScript.arguments(for: configuration(hostname: hostname), linger: true)
        }
        #expect(throws: MawError.self) {
            try ProvisioningScript.importArguments(
                hostname: hostname, defaultUser: DefaultUserChoice(user: "ayse", source: .option))
        }
    }

    /// The import names its default user, with no locale, and lets every user but `root`
    /// linger.
    @Test func passesTheImportsDefaultUser() throws {
        #expect(
            try ProvisioningScript.importArguments(
                hostname: "copy", defaultUser: DefaultUserChoice(user: "ayse", source: .mawConf))
                == ["/mnt/root", "import", "copy", "ayse", "", "yes"])
        #expect(
            try ProvisioningScript.importArguments(
                hostname: "copy", defaultUser: DefaultUserChoice(user: "root", source: .fallback))
                == ["/mnt/root", "import", "copy", "root", "", "no"])
        #expect(throws: MawError.self) {
            try ProvisioningScript.importArguments(
                hostname: "copy", defaultUser: DefaultUserChoice(user: "-rf", source: .option))
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

    @Test func readsTheLineOfAPathThatCannotBeResolved() {
        let output = "something\nmaw-unresolvable\t/etc/netplan/50-maw.yaml\tit loops\n"
        let line = ProvisioningScript.unresolvablePath(in: output)
        #expect(line?.path == "/etc/netplan/50-maw.yaml")
        #expect(line?.reason == "it loops")
        #expect(ProvisioningScript.unresolvablePath(in: "no such line\n") == nil)
    }
}

/// The resolver that every script uses, `ProvisioningScript.functions`, run against roots in
/// temporary directories.
enum RootResolverTests {
    /// Each test runs a script that starts many processes, so the suite is a load generator
    /// (decision record 0018): its tests run one at a time, apart from the latency tests.
    @Suite struct Load {
        func resolve(_ path: String, in fake: FakeRoot) async throws -> String {
            let run = try await ShellRun.run(
                "root=$1\n" + ProvisioningScript.functions + "\nresolve \"$2\"\n",
                [fake.path, path])
            try #require(run.status == 0, "\(run.output)")
            return run.output.trimmingCharacters(in: .newlines)
        }

        @Test func followsLinksInsideTheRoot() async throws {
            let fake = try FakeRoot.ubuntu()
            #expect(try await resolve("/sbin/init", in: fake) == "/usr/lib/systemd/systemd")
            #expect(try await resolve("/etc/passwd", in: fake) == "/etc/passwd")
            #expect(
                try await resolve("/etc/netplan/50-maw.yaml", in: fake)
                    == "/etc/netplan/50-maw.yaml")
            #expect(try await resolve("/", in: fake) == "/")
            #expect(try await resolve("//etc/./passwd", in: fake) == "/etc/passwd")
        }

        /// An absolute target starts again at the root, and `..` never leaves it.
        @Test func keepsEveryResultInsideTheRoot() async throws {
            let fake = try FakeRoot.ubuntu()
            try fake.link("etc/up", to: "../../../../tmp")
            try fake.link("etc/absolute", to: "/etc")
            #expect(try await resolve("/etc/up/x", in: fake) == "/tmp/x")
            #expect(try await resolve("/etc/absolute/passwd", in: fake) == "/etc/passwd")
            #expect(try await resolve("/../../etc/passwd", in: fake) == "/etc/passwd")
            // A dangling link resolves to where it points.
            try fake.link("etc/dangling", to: "/nowhere/file")
            #expect(try await resolve("/etc/dangling", in: fake) == "/nowhere/file")
        }

        @Test func refusesALoopAndAFileUsedAsADirectory() async throws {
            let fake = try FakeRoot.ubuntu()
            try fake.link("etc/loop", to: "loop")
            try fake.link("etc/a", to: "b")
            try fake.link("etc/b", to: "/etc/a")
            #expect(
                try await resolve("/etc/loop", in: fake) == "!it has more than 40 links, or a loop")
            #expect(
                try await resolve("/etc/a/x", in: fake) == "!it has more than 40 links, or a loop")
            #expect(
                try await resolve("/etc/passwd/x", in: fake) == "!/etc/passwd is not a directory")
        }
    }
}

/// The `import` mode of `ProvisioningScript.text`, run against roots in temporary
/// directories. It runs without `chroot`, because the roots have no `dpkg-divert`.
enum ImportConfigurationTests {
    /// Each test runs a script that starts many processes, so the suite is a load generator
    /// (decision record 0018): its tests run one at a time, apart from the latency tests.
    @Suite struct Load {
        func configure(_ fake: FakeRoot, user: String = "ayse") async throws -> ShellRun {
            try await ShellRun.run(
                ProvisioningScript.text,
                [fake.path, "import", "copy", user, "", user == "root" ? "no" : "yes"])
        }

        @Test func writesTheSystemFilesAndCreatesNoUser() async throws {
            let fake = try FakeRoot.ubuntu()
            let passwd = fake.contents("etc/passwd")
            let run = try await configure(fake)
            try #require(run.status == 0, "\(run.output)")

            #expect(fake.contents("etc/hostname") == "copy\n")
            #expect(fake.contents("etc/hosts")?.contains("127.0.1.1\tcopy\n") == true)
            #expect(fake.contents("etc/fstab") == "LABEL=maw-root\t/\text4\tdefaults\t0\t0\n")
            #expect(
                fake.contents("etc/netplan/50-maw.yaml")?.contains("driver: virtio_net") == true)
            #expect(fake.mode("etc/netplan/50-maw.yaml") == 0o600)
            #expect(fake.linkTarget("etc/resolv.conf") == "../run/systemd/resolve/stub-resolv.conf")
            #expect(
                fake.contents("etc/systemd/journald.conf.d/50-maw.conf")?
                    .contains("SystemMaxUse=256M") == true)
            for unit in ProvisioningScript.maskedUnits {
                #expect(fake.linkTarget("etc/systemd/system/\(unit)") == "/dev/null", "\(unit)")
            }
            // A new identity.
            #expect(fake.contents("etc/machine-id") == "")
            #expect(fake.mode("etc/machine-id") == 0o444)
            #expect(!fake.exists("var/lib/dbus/machine-id"))
            // The default user lingers.
            #expect(fake.exists("var/lib/systemd/linger/ayse"))

            // No user, no home, no maw.conf, and no locale: the archive keeps its own.
            #expect(fake.contents("etc/passwd") == passwd)
            #expect(!fake.exists("etc/maw.conf"))
            #expect(!fake.exists("etc/default/locale"))
            #expect(!fake.exists("home/ayse/.sudo_as_admin_successful"))
            #expect(fake.entriesOutsideTheRoot() == ["outside", "outside/sentinel"])
        }

        @Test func letsNoLingerForRoot() async throws {
            let fake = try FakeRoot.ubuntu()
            let run = try await configure(fake, user: "root")
            try #require(run.status == 0, "\(run.output)")
            #expect(!fake.exists("var/lib/systemd/linger"))
        }

        /// A link where the script writes is replaced, not written through.
        @Test func replacesALinkInsteadOfWritingThroughIt() async throws {
            let fake = try FakeRoot.ubuntu()
            try FileManager.default.removeItem(at: fake.url("etc/hostname"))
            try fake.link("etc/hostname", to: "/etc/passwd")
            let passwd = fake.contents("etc/passwd")
            let run = try await configure(fake)
            try #require(run.status == 0, "\(run.output)")
            #expect(fake.linkTarget("etc/hostname") == nil)
            #expect(fake.contents("etc/hostname") == "copy\n")
            #expect(fake.contents("etc/passwd") == passwd)
        }

        /// `etc/netplan` as a link to `/etc` writes into the root's `/etc`.
        @Test func writesThroughAnAbsoluteDirectoryLinkInsideTheRoot() async throws {
            let fake = try FakeRoot.ubuntu()
            try fake.link("etc/netplan", to: "/etc")
            let run = try await configure(fake)
            try #require(run.status == 0, "\(run.output)")
            #expect(fake.contents("etc/50-maw.yaml")?.contains("driver: virtio_net") == true)
            #expect(fake.entriesOutsideTheRoot() == ["outside", "outside/sentinel"])
            #expect(!FileManager.default.fileExists(atPath: "/etc/50-maw.yaml"))
        }

        /// `etc/netplan` as a link to `../../../../tmp` writes into the root's `/tmp`.
        @Test func keepsARelativeDirectoryLinkInsideTheRoot() async throws {
            let existedBefore = FileManager.default.fileExists(atPath: "/tmp/50-maw.yaml")
            let fake = try FakeRoot.ubuntu()
            try fake.link("etc/netplan", to: "../../../../tmp")
            let run = try await configure(fake)
            try #require(run.status == 0, "\(run.output)")
            #expect(fake.contents("tmp/50-maw.yaml")?.contains("driver: virtio_net") == true)
            #expect(fake.entriesOutsideTheRoot() == ["outside", "outside/sentinel"])
            if !existedBefore {
                #expect(!FileManager.default.fileExists(atPath: "/tmp/50-maw.yaml"))
            }
        }

        /// A path that cannot be resolved ends the script with status 3 and the line that names
        /// it, before anything is written under it.
        @Test func stopsAtAPathThatCannotBeResolved() async throws {
            let fake = try FakeRoot.ubuntu()
            try fake.link("etc/netplan", to: "netplan")
            let run = try await configure(fake)
            #expect(run.status == ProvisioningScript.unresolvableStatus)
            let line = try #require(ProvisioningScript.unresolvablePath(in: run.output))
            #expect(line.path == "/etc/netplan/50-maw.yaml")
            #expect(line.reason == "it has more than 40 links, or a loop")
            #expect(fake.entriesOutsideTheRoot() == ["outside", "outside/sentinel"])
        }

        /// Without netplan, systemd-networkd gets a configuration of its own, and it and
        /// systemd-resolved start with the system.
        @Test func configuresSystemdNetworkdWithoutNetplan() async throws {
            let fake = try FakeRoot.ubuntu()
            let run = try await configure(fake)
            try #require(run.status == 0, "\(run.output)")
            let network = try #require(fake.contents("etc/systemd/network/50-maw.network"))
            #expect(network.contains("[Match]\nDriver=virtio_net\n"))
            #expect(network.contains("[Network]\nDHCP=ipv4\n"))
            for unit in ["systemd-networkd.service", "systemd-resolved.service"] {
                #expect(
                    fake.linkTarget("etc/systemd/system/multi-user.target.wants/\(unit)")
                        == "/usr/lib/systemd/system/\(unit)")
            }
        }

        @Test func leavesTheNetworkToNetplanWhenItIsThere() async throws {
            let fake = try FakeRoot.ubuntu()
            try fake.link(
                "usr/lib/systemd/system-generators/netplan", to: "../../../libexec/netplan/generate"
            )
            try fake.file("usr/libexec/netplan/generate", mode: 0o755)
            let run = try await configure(fake)
            try #require(run.status == 0, "\(run.output)")
            #expect(!fake.exists("etc/systemd/network/50-maw.network"))
            #expect(!fake.exists("etc/systemd/system/multi-user.target.wants"))
            #expect(fake.contents("etc/netplan/50-maw.yaml") != nil)
        }

        @Test func createsTheMissingMountPoints() async throws {
            let fake = try FakeRoot.ubuntu()
            for directory in ["dev", "proc", "sys", "run"] {
                try FileManager.default.removeItem(at: fake.url(directory))
            }
            let run = try await configure(fake)
            try #require(run.status == 0, "\(run.output)")
            for directory in ["dev", "proc", "sys", "run"] {
                var isDirectory: ObjCBool = false
                #expect(
                    FileManager.default.fileExists(
                        atPath: fake.url(directory).path(percentEncoded: false),
                        isDirectory: &isDirectory) && isDirectory.boolValue, "\(directory)")
            }
        }
    }
}

/// `ProvisioningScript.mawConfWriter`, which writes the text of `MawConf` into the root.
enum MawConfWriterTests {
    /// Each test runs a script that starts many processes, so the suite is a load generator
    /// (decision record 0018): its tests run one at a time, apart from the latency tests.
    @Suite struct Load {
        @Test func writesItsInputAsMawConf() async throws {
            let fake = try FakeRoot.ubuntu()
            let text = MawConf.contents(defaultUser: try UserName("ayse"))
            let run = try await ShellRun.run(
                ProvisioningScript.mawConfWriter, [fake.path], input: text)
            try #require(run.status == 0, "\(run.output)")
            #expect(fake.contents("etc/maw.conf") == text)
            #expect(fake.mode("etc/maw.conf") == 0o644)
            #expect(MawConf(parsing: text).defaultUser == "ayse")
        }

        /// A `maw.conf` that the archive has as a link is replaced by a file.
        @Test func replacesALink() async throws {
            let fake = try FakeRoot.ubuntu()
            try fake.link("etc/maw.conf", to: "/etc/passwd")
            let passwd = fake.contents("etc/passwd")
            let run = try await ShellRun.run(
                ProvisioningScript.mawConfWriter, [fake.path], input: "[user]\ndefault = ayse\n")
            try #require(run.status == 0, "\(run.output)")
            #expect(fake.linkTarget("etc/maw.conf") == nil)
            #expect(fake.contents("etc/maw.conf") == "[user]\ndefault = ayse\n")
            #expect(fake.contents("etc/passwd") == passwd)
        }
    }
}
