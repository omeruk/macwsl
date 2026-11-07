import Foundation
import MawCore
import Testing

@Suite struct MawPathsTests {
    let home = URL(filePath: "/tmp/maw-tests/home", directoryHint: .isDirectory)
    var paths: MawPaths { MawPaths(homeDirectory: home) }

    @Test func derivesEveryPathFromTheInjectedHome() throws {
        let ubuntu = try DistroName("Ubuntu")
        let support = "/tmp/maw-tests/home/Library/Application Support/maw"

        #expect(paths.applicationSupportDirectory.path(percentEncoded: false) == support + "/")
        #expect(paths.distrosDirectory.path(percentEncoded: false) == support + "/distros/")
        #expect(
            paths.distroDirectory(for: ubuntu).path(percentEncoded: false)
                == support + "/distros/Ubuntu/")
        #expect(
            paths.diskImage(for: ubuntu).path(percentEncoded: false)
                == support + "/distros/Ubuntu/disk.img")
        #expect(
            paths.metadataFile(for: ubuntu).path(percentEncoded: false)
                == support + "/distros/Ubuntu/distro.json")
        let label = try DaemonLabel("dev.maw.mawd")
        let id = try #require(UUID(uuidString: "6F1C0A52-0B4E-4E0C-9B7E-2B8F7A0C1D2E"))
        #expect(paths.stagingRoot.path(percentEncoded: false) == support + "/distros/.staging/")
        #expect(
            paths.stagingDirectory(label: label).path(percentEncoded: false)
                == support + "/distros/.staging/dev.maw.mawd/")
        #expect(
            paths.stagingDirectory(for: ubuntu, id: id, label: label).path(percentEncoded: false)
                == support
                + "/distros/.staging/dev.maw.mawd/Ubuntu-6F1C0A52-0B4E-4E0C-9B7E-2B8F7A0C1D2E/")
        #expect(paths.kernelDirectory.path(percentEncoded: false) == support + "/kernel/")
        #expect(
            paths.logsDirectory.path(percentEncoded: false)
                == "/tmp/maw-tests/home/Library/Logs/maw/")
        #expect(
            paths.globalConfigFile.path(percentEncoded: false)
                == "/tmp/maw-tests/home/.mawconfig")
    }

    @Test func placesTheDaemonsFiles() {
        #expect(
            paths.daemonLogFile.path(percentEncoded: false)
                == "/tmp/maw-tests/home/Library/Logs/maw/mawd.log")
        #expect(
            paths.launchAgentFile(label: "dev.maw.mawd").path(percentEncoded: false)
                == "/tmp/maw-tests/home/Library/LaunchAgents/dev.maw.mawd.plist")
        #expect(
            paths.daemonLockFile(label: "dev.maw.mawd").path(percentEncoded: false)
                == "/tmp/maw-tests/home/Library/Application Support/maw/dev.maw.mawd.lock")
    }

    /// The provisioning machines' console logs have a directory of their own, so that the
    /// installation of `foo` and a distribution named `install-foo` never share a log.
    @Test func placesInstallationLogsInADirectoryOfTheirOwn() throws {
        let foo = try DistroName("foo")
        #expect(
            paths.installLogFile(for: foo).path(percentEncoded: false)
                == "/tmp/maw-tests/home/Library/Logs/maw/install/foo.log")
        let logs = URL(filePath: "/logs", directoryHint: .isDirectory)
        #expect(
            MawPaths.installLogFile(for: foo, in: logs)
                != MawPaths.consoleLogFile(forMachineNamed: "install-foo", in: logs))
        #expect(
            MawPaths.consoleLogFile(forMachineNamed: "install-foo", in: logs)
                .path(percentEncoded: false) == "/logs/install-foo.log")
    }

    @Test func keepsDistrosInSeparateDirectories() throws {
        let ubuntu = paths.distroDirectory(for: try DistroName("Ubuntu"))
        let debian = paths.distroDirectory(for: try DistroName("Debian"))
        #expect(ubuntu != debian)
        #expect(ubuntu.deletingLastPathComponent() == debian.deletingLastPathComponent())
    }

    @Test func defaultsToTheCurrentUsersHome() {
        #expect(
            MawPaths().homeDirectory.standardizedFileURL
                == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL)
    }
}
