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
