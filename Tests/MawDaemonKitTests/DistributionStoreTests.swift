import Foundation
import MawCore
import Testing

@testable import MawDaemonKit

@Suite struct DistributionStoreTests {
    let home: URL
    let store: DistributionStore

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(
            path: "maw-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = DistributionStore(
            paths: MawPaths(homeDirectory: home), daemonLabel: try DaemonLabel("dev.maw.mawd"))
        try FileManager.default.createDirectory(
            at: store.paths.distrosDirectory, withIntermediateDirectories: true)
    }

    func metadata(_ name: String) throws -> DistroMetadata {
        DistroMetadata(
            name: try DistroName(name), catalogEntry: try DistroName("Ubuntu-24.04"),
            release: "24.04.5", imageSHA256: String(repeating: "a", count: 64),
            createdAt: Date(timeIntervalSince1970: 0), defaultUser: "ayse", diskSize: 1 << 30,
            macAddress: "02:00:00:00:00:01")
    }

    func install(_ name: String) throws {
        let staging = store.stagingDirectory(for: try DistroName(name))
        try store.createStagingDirectory(staging)
        try store.commit(staging: staging, metadata: try metadata(name))
    }

    func contents(of url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false)))
            ?? []).sorted()
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// A staging directory of another daemon's label with a disk in it.
    func otherLabelsStaging() throws -> URL {
        let other = DistributionStore(paths: store.paths, daemonLabel: try DaemonLabel("other"))
        let staging = other.stagingDirectory(for: try DistroName("Ubuntu-24.04"))
        try other.createStagingDirectory(staging)
        try Data("disk".utf8).write(to: staging.appending(path: "disk.img"))
        return staging
    }

    /// A directory outside `distros/` with a file in it, which no removal may reach.
    func outsideDirectory() throws -> URL {
        let outside = home.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appending(path: "keep"))
        return outside
    }

    @Test func installsByRenamingTheStagingDirectory() throws {
        let name = try DistroName("Ubuntu-24.04")
        #expect(!store.isInstalled(name))
        try install("Ubuntu-24.04")
        #expect(store.isInstalled(name))
        #expect(try store.metadata(for: name) == (try metadata("Ubuntu-24.04")))
        #expect(store.installed().map(\.name) == [name])
        #expect(contents(of: store.paths.distrosDirectory) == [".staging", "Ubuntu-24.04"])
        #expect(contents(of: store.paths.stagingDirectory(label: store.daemonLabel)).isEmpty)
    }

    @Test func buildsInADirectoryOfItsOwnLabel() throws {
        let staging = store.stagingDirectory(for: try DistroName("Ubuntu-24.04"))
        #expect(
            staging.deletingLastPathComponent().lastPathComponent == "dev.maw.mawd")
        #expect(staging.lastPathComponent.hasPrefix("Ubuntu-24.04-"))
        try store.createStagingDirectory(staging)
        #expect(exists(staging))
        let mode =
            try FileManager.default.attributesOfItem(
                atPath: staging.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o700)
        // It never reuses a directory that exists.
        #expect(throws: MawError.self) { try store.createStagingDirectory(staging) }
    }

    @Test func createsNoStagingDirectoryOutsideItsOwnLabel() throws {
        let name = try DistroName("Ubuntu-24.04")
        let other = DistributionStore(paths: store.paths, daemonLabel: try DaemonLabel("other"))
        for staging in [
            other.stagingDirectory(for: name), store.paths.distroDirectory(for: name),
            store.paths.stagingRoot, store.paths.stagingDirectory(label: store.daemonLabel),
        ] {
            #expect(throws: MawError.self, "\(staging)") {
                try store.createStagingDirectory(staging)
            }
        }
        #expect(contents(of: store.paths.distrosDirectory).isEmpty)
    }

    @Test func removesItsOwnStagingLeftovers() throws {
        let staging = store.stagingDirectory(for: try DistroName("Ubuntu-24.04"))
        try store.createStagingDirectory(staging)
        try Data("disk".utf8).write(to: staging.appending(path: "disk.img"))
        try install("Debian")
        #expect(store.removeStagingLeftovers() == [staging.lastPathComponent])
        #expect(!exists(staging))
        #expect(store.isInstalled(try DistroName("Debian")))
    }

    /// Another daemon, of another label, may be installing: its staging directory stays.
    @Test func neverRemovesAnotherLabelsStagingDirectory() throws {
        let others = try otherLabelsStaging()
        let own = store.stagingDirectory(for: try DistroName("Debian"))
        try store.createStagingDirectory(own)
        #expect(store.removeStagingLeftovers() == [own.lastPathComponent])
        #expect(exists(others.appending(path: "disk.img")))
        store.removeStagingDirectory(others)
        #expect(exists(others.appending(path: "disk.img")))
    }

    @Test func removesALinkInsideTheStagingDirectoryAsALink() throws {
        let outside = try outsideDirectory()
        let staging = store.stagingDirectory(for: try DistroName("Ubuntu-24.04"))
        try store.createStagingDirectory(staging)
        try FileManager.default.createSymbolicLink(
            at: staging.appending(path: "disk.img"), withDestinationURL: outside)
        let label = store.paths.stagingDirectory(label: store.daemonLabel)
        try FileManager.default.createSymbolicLink(
            at: label.appending(path: "link"), withDestinationURL: outside)
        #expect(store.removeStagingLeftovers().sorted() == [staging.lastPathComponent, "link"])
        #expect(contents(of: label).isEmpty)
        #expect(contents(of: outside) == ["keep"])
    }

    /// A link in place of `.staging` or of the label's directory is never followed: nothing is
    /// removed, and nothing is created through it.
    @Test(arguments: [false, true])
    func neverFollowsALinkInPlaceOfAStagingDirectory(atRoot: Bool) throws {
        let outside = try outsideDirectory()
        let name = try DistroName("Ubuntu-24.04")
        // What the daemon would remove if it followed the link.
        let lure =
            atRoot
            ? outside.appending(path: "dev.maw.mawd/Ubuntu-24.04-x", directoryHint: .isDirectory)
            : outside.appending(path: "Ubuntu-24.04-x", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lure, withIntermediateDirectories: true)
        let link =
            atRoot
            ? store.paths.stagingRoot : store.paths.stagingDirectory(label: store.daemonLabel)
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(store.removeStagingLeftovers().isEmpty)
        store.removeStagingDirectory(
            store.stagingDirectory(for: name).deletingLastPathComponent()
                .appending(path: "Ubuntu-24.04-x"))
        #expect(exists(lure))
        #expect(exists(outside.appending(path: "keep")))
        let staging = store.stagingDirectory(for: name)
        #expect(throws: MawError.self) { try store.createStagingDirectory(staging) }
        #expect(!exists(outside.appending(path: staging.lastPathComponent)))
        #expect(!exists(outside.appending(path: "dev.maw.mawd/\(staging.lastPathComponent)")))
    }

    @Test func removesTheStagingDirectoriesOfEarlierBuildsOnlyWhenAsked() throws {
        let legacy = store.paths.distrosDirectory.appending(
            path: ".staging-Ubuntu-24.04-6F1C0A52", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: legacy.appending(path: "disk.img"))
        let others = try otherLabelsStaging()
        try install("Debian")

        #expect(store.removeStagingLeftovers().isEmpty)
        #expect(exists(legacy))
        #expect(store.legacyStagingDirectories() == [legacy.lastPathComponent])
        #expect(store.removeLegacyStagingDirectories() == [legacy.lastPathComponent])
        #expect(!exists(legacy))
        #expect(store.legacyStagingDirectories().isEmpty)
        #expect(exists(others.appending(path: "disk.img")))
        #expect(store.isInstalled(try DistroName("Debian")))
    }

    @Test func removesALegacyLinkAsALink() throws {
        let outside = try outsideDirectory()
        let legacy = store.paths.distrosDirectory.appending(path: ".staging-Ubuntu-24.04-1")
        try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: outside)
        #expect(store.removeLegacyStagingDirectories() == [legacy.lastPathComponent])
        #expect(contents(of: outside) == ["keep"])
    }

    /// `.staging` is not a distribution, even with a `distro.json` in it, and no distribution
    /// can take its name.
    @Test func ignoresTheStagingDirectoryInEveryScan() throws {
        let staging = store.stagingDirectory(for: try DistroName("Ubuntu-24.04"))
        try store.createStagingDirectory(staging)
        try (try metadata("Ubuntu-24.04")).encoded().write(
            to: staging.appending(path: "distro.json"))
        try (try metadata("Ubuntu-24.04")).encoded().write(
            to: store.paths.stagingRoot.appending(path: "distro.json"))
        #expect(store.installed().isEmpty)
        #expect(store.defaultDistribution() == nil)
        #expect(!store.isInstalled(try DistroName("Ubuntu-24.04")))
        #expect(throws: MawError.self) { try DistroName(MawPaths.stagingRootName) }
        #expect(throws: MawError.self) { try DistroName(staging.lastPathComponent + "/..") }
        try install("Debian")
        #expect(store.installed().map(\.name.rawValue) == ["Debian"])
    }

    @Test func choosesTheDefaultDistribution() throws {
        #expect(store.defaultDistribution() == nil)
        try install("Zeta")
        try install("Alpha")
        // Nothing recorded yet: the first by name.
        #expect(store.defaultDistribution()?.rawValue == "Alpha")
        try store.setDefaultDistribution(try DistroName("Zeta"))
        #expect(store.defaultDistribution()?.rawValue == "Zeta")
        // A recorded default that is no longer installed is ignored.
        try store.setDefaultDistribution(try DistroName("Gone"))
        #expect(store.defaultDistribution()?.rawValue == "Alpha")
    }

    @Test func ignoresDirectoriesWithoutMetadata() throws {
        try FileManager.default.createDirectory(
            at: store.paths.distroDirectory(for: try DistroName("Broken")),
            withIntermediateDirectories: true)
        #expect(store.installed().isEmpty)
        #expect(store.defaultDistribution() == nil)
    }
}
