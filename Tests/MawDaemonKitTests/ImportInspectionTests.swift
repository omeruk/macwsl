import Foundation
import MawCore
import Testing

@testable import MawDaemonKit

/// The checks of an extracted archive before it is configured: `ImportInspection.script` run
/// against roots in temporary directories, and the decisions read from its output.
enum ImportInspectionTests {
    /// Each test runs a script that starts many processes, so the suite is a load generator
    /// (decision record 0018): its tests run one at a time, apart from the latency tests.
    @Suite struct Load {
        static let name = try! DistroName("Ubuntu-24.04")

        func inspect(_ fake: FakeRoot) async throws -> ImportInspection.Report {
            let run = try await ShellRun.run(ImportInspection.script, [fake.path])
            try #require(run.status == 0, "\(run.output)")
            return ImportInspection.Report(parsing: run.output)
        }

        func refusal(_ report: ImportInspection.Report) -> MawError? {
            do {
                try report.evaluate(for: Self.name)
                return nil
            } catch {
                return error
            }
        }

        @Test func acceptsARootFileSystemWithSystemd() async throws {
            let fake = try FakeRoot.ubuntu()
            try fake.file("etc/maw.conf", "[user]\ndefault = ayse\n")
            let report = try await inspect(fake)
            #expect(refusal(report) == nil)
            #expect(report.finding(.initProgram).found == "/usr/lib/systemd/systemd")
            #expect(report.files == [.passwd: "/etc/passwd", .mawConf: "/etc/maw.conf"])
            #expect(report.entryCount == 11)
        }

        /// The files are read where their links lead inside the root.
        @Test func findsTheFilesThroughLinksInsideTheRoot() async throws {
            let fake = try FakeRoot.ubuntu()
            try fake.file("srv/conf/wsl.conf", "[user]\ndefault = ayse\n")
            try fake.link("etc/wsl.conf", to: "/srv/conf/wsl.conf")
            try fake.link("etc/maw.conf", to: "../../../../outside/sentinel")
            let report = try await inspect(fake)
            #expect(report.files[.wslConf] == "/srv/conf/wsl.conf")
            // The link that would leave the root leads to /outside/sentinel inside it, which does
            // not exist.
            #expect(
                report.finding(.mawConf)
                    == .init(kind: .missing, found: "/outside/sentinel", isLink: true))
            #expect(report.files[.mawConf] == nil)
        }

        @Test func refusesAnInitThatIsNotSystemd() async throws {
            let fake = try FakeRoot.ubuntu()
            try FileManager.default.removeItem(at: fake.url("usr/sbin/init"))
            try fake.file("usr/bin/busybox", mode: 0o755)
            try fake.link("usr/sbin/init", to: "/usr/bin/busybox")
            #expect(
                refusal(try await inspect(fake))
                    == .importInitNotSystemd(
                        Self.name, reason: "/sbin/init leads to /usr/bin/busybox"))
        }

        @Test func refusesAMissingOrBrokenInit() async throws {
            let fake = try FakeRoot.ubuntu()
            try FileManager.default.removeItem(at: fake.url("usr/sbin/init"))
            #expect(
                refusal(try await inspect(fake))
                    == .importInitNotSystemd(Self.name, reason: "the archive has no /sbin/init"))

            try fake.link("usr/sbin/init", to: "/lib/systemd/missing")
            #expect(
                refusal(try await inspect(fake))
                    == .importInitNotSystemd(
                        Self.name,
                        reason: "/sbin/init leads to /usr/lib/systemd/missing, which does not exist"
                    ))

            try FileManager.default.removeItem(at: fake.url("usr/sbin/init"))
            try fake.link("usr/sbin/init", to: "init")
            #expect(
                refusal(try await inspect(fake))
                    == .importInitNotSystemd(
                        Self.name,
                        reason:
                            "/sbin/init cannot be followed: it has more than 40 links, or a loop"))

            try FileManager.default.removeItem(at: fake.url("usr/sbin/init"))
            try fake.file("usr/sbin/init", "not a program")
            #expect(
                refusal(try await inspect(fake))
                    == .importInitNotSystemd(
                        Self.name,
                        reason: "/sbin/init leads to /usr/sbin/init, which is not executable"
                    ))
        }

        /// A systemd that is not executable is not systemd.
        @Test func refusesASystemdThatIsNotExecutable() async throws {
            let fake = try FakeRoot.ubuntu()
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: fake.url("usr/lib/systemd/systemd").path(percentEncoded: false))
            #expect(
                refusal(try await inspect(fake))
                    == .importInitNotSystemd(
                        Self.name,
                        reason:
                            "/sbin/init leads to /usr/lib/systemd/systemd, which is not executable"
                    ))
        }

        @Test func refusesARootUnderOneDirectory() async throws {
            let fake = try FakeRoot()
            try fake.file("rootfs/etc/passwd", "root:x:0:0:root:/root:/bin/bash\n")
            try fake.directory("rootfs/usr")
            #expect(
                refusal(try await inspect(fake))
                    == .importNotARootFileSystem(
                        Self.name, found: "its top level holds only the directory rootfs/"))
        }

        @Test func refusesAnEmptyArchive() async throws {
            #expect(
                refusal(try await inspect(try FakeRoot()))
                    == .importNotARootFileSystem(Self.name, found: "the archive is empty"))
        }

        @Test func namesWhatTheTopLevelHoldsAndWhatItLacks() async throws {
            let fake = try FakeRoot()
            for directory in ["bin", "boot", "etc", "home", "usr"] {
                try fake.directory(directory)
            }
            #expect(
                refusal(try await inspect(fake))
                    == .importNotARootFileSystem(
                        Self.name,
                        found:
                            "its top level holds bin/, boot/, etc/, and 2 more,\nbut no etc/passwd")
            )
        }

        @Test func refusesAPasswdThatCannotBeResolved() async throws {
            let fake = try FakeRoot.ubuntu()
            try FileManager.default.removeItem(at: fake.url("etc/passwd"))
            try fake.link("etc/passwd", to: "passwd")
            #expect(
                refusal(try await inspect(fake))
                    == .importPathNotResolvable(
                        Self.name, path: "/etc/passwd",
                        reason: "it has more than 40 links, or a loop"))
        }

        /// The output's lines, read without the script.
        @Test func readsTheReport() {
            let report = ImportInspection.Report(
                parsing: """
                    entry\tbin/
                    entry\tna\tme
                    entries\t2
                    path\t/etc/passwd\tfile\tplain\t/etc/passwd
                    path\t/sbin/init\texecutable\tlink\t/usr/lib/systemd/systemd
                    path\t/etc/unknown\tfile\tplain\t/x
                    garbage
                    """)
            #expect(report.entries == ["bin/", "na\tme"])
            #expect(report.entryCount == 2)
            #expect(report.finding(.passwd) == .init(kind: .file, found: "/etc/passwd"))
            #expect(report.finding(.usr) == .init(kind: .missing, found: "/usr"))
            #expect(report.initReason() == nil)
        }

        /// Every line that the inspection can add to an error fits in 80 columns, with names and
        /// paths at their longest.
        @Test func keepsItsLinesWithin80Columns() {
            let long = String(repeating: "x", count: 200)
            let report = ImportInspection.Report(
                entries: [long + "/", long, "\u{1B}[31m" + long], entryCount: 9_999,
                findings: [.initProgram: .init(kind: .missing, found: "/" + long, isLink: true)])
            let lines =
                report.topLevel(missingPasswd: true, missingUsr: true).split(separator: "\n")
                + (report.initReason() ?? "").split(separator: "\n")
            for line in lines {
                #expect(line.count + 1 <= 80, "\(line.count): \(line)")
                #expect(!line.contains("\u{1B}"))
            }
        }
    }
}
