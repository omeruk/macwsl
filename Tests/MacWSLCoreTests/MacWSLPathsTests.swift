import Foundation
import MacWSLCore
import Testing

@Suite struct MacWSLPathsTests {
    let home = URL(filePath: "/tmp/macwsl-tests/home", directoryHint: .isDirectory)
    var paths: MacWSLPaths { MacWSLPaths(homeDirectory: home) }

    @Test func derivesEveryPathFromTheInjectedHome() throws {
        let ubuntu = try DistroName("Ubuntu")
        let support = "/tmp/macwsl-tests/home/Library/Application Support/MacWSL"

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
                == "/tmp/macwsl-tests/home/Library/Logs/MacWSL/")
        #expect(
            paths.globalConfigFile.path(percentEncoded: false)
                == "/tmp/macwsl-tests/home/.macwslconfig")
    }

    @Test func keepsDistrosInSeparateDirectories() throws {
        let ubuntu = paths.distroDirectory(for: try DistroName("Ubuntu"))
        let debian = paths.distroDirectory(for: try DistroName("Debian"))
        #expect(ubuntu != debian)
        #expect(ubuntu.deletingLastPathComponent() == debian.deletingLastPathComponent())
    }

    @Test func defaultsToTheCurrentUsersHome() {
        #expect(
            MacWSLPaths().homeDirectory.standardizedFileURL
                == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL)
    }
}
