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
        store = DistributionStore(paths: MawPaths(homeDirectory: home))
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
        let staging = store.paths.stagingDirectory(for: try DistroName(name), id: "test")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try store.commit(staging: staging, metadata: try metadata(name))
    }

    @Test func installsByRenamingTheStagingDirectory() throws {
        let name = try DistroName("Ubuntu-24.04")
        #expect(!store.isInstalled(name))
        try install("Ubuntu-24.04")
        #expect(store.isInstalled(name))
        #expect(try store.metadata(for: name) == (try metadata("Ubuntu-24.04")))
        #expect(store.installed().map(\.name) == [name])
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: store.paths.distrosDirectory.path(percentEncoded: false))
        #expect(leftovers == ["Ubuntu-24.04"])
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

    @Test func removesStagingLeftoversButNotActiveOnes() throws {
        let name = try DistroName("Ubuntu-24.04")
        let old = store.paths.stagingDirectory(for: name, id: "old")
        let active = store.paths.stagingDirectory(for: name, id: "active")
        for directory in [old, active] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        try install("Debian")
        let removed = store.removeStagingLeftovers(except: [active.standardizedFileURL])
        #expect(removed == [old.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: active.path(percentEncoded: false)))
        #expect(store.isInstalled(try DistroName("Debian")))
    }

    @Test func ignoresDirectoriesWithoutMetadata() throws {
        try FileManager.default.createDirectory(
            at: store.paths.distroDirectory(for: try DistroName("Broken")),
            withIntermediateDirectories: true)
        #expect(store.installed().isEmpty)
        #expect(store.defaultDistribution() == nil)
    }
}
