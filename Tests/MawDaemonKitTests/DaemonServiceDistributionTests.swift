import Foundation
import MawClient
import MawCore
import MawDaemonKit
import MawXPC
import Testing

/// A distribution store in a directory of its own, removed with it.
final class TemporaryStore: Sendable {
    let home: URL
    let store: DistributionStore

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(
            path: "maw-service-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = DistributionStore(
            paths: MawPaths(homeDirectory: home), daemonLabel: try DaemonLabel("dev.maw.mawd"))
        try FileManager.default.createDirectory(
            at: store.paths.distrosDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    /// Installs `name` as the installer leaves it: `distros/<name>/distro.json`.
    func install(_ name: String) throws {
        let staging = store.stagingDirectory(for: try DistroName(name))
        try store.createStagingDirectory(staging)
        try store.commit(
            staging: staging,
            metadata: DistroMetadata(
                name: try DistroName(name), catalogEntry: try DistroName("Ubuntu-24.04"),
                release: "24.04.5", imageSHA256: String(repeating: "a", count: 64),
                createdAt: Date(timeIntervalSince1970: 0), defaultUser: "ayse",
                diskSize: 1 << 30, macAddress: "02:00:00:00:00:01"))
    }

    /// The default that `state.json` records, as written.
    func recordedDefault() throws -> String? {
        guard FileManager.default.fileExists(atPath: store.paths.stateFile.path) else {
            return nil
        }
        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: store.paths.stateFile))
        return (object as? [String: Any])?["defaultDistribution"] as? String
    }
}

/// `listDistributions`, `setDefault`, and `terminate`, against a store in a temporary
/// directory and fake machines.
extension DaemonServiceTests {
    static func name(_ name: String) -> DistroName {
        try! DistroName(name)
    }

    static func entry(_ name: String, _ state: DistributionState) -> DistributionEntry {
        DistributionEntry(name: Self.name(name), state: state)
    }

    @Test func listsNothingAndResolvesNoNameWithoutAStore() async throws {
        let daemon = Daemon()
        let client = try await daemon.connect()
        defer { client.close() }
        #expect(
            try await client.listDistributions()
                == DistributionList(distributions: [], defaultDistribution: nil))
        await #expect(throws: MawError.distributionNotInstalled(Self.name("Ubuntu-24.04"))) {
            try await client.setDefault(Self.name("Ubuntu-24.04"))
        }
        await #expect(throws: MawError.distributionNotInstalled(Self.name("Ubuntu-24.04"))) {
            try await client.terminate(Self.name("Ubuntu-24.04"))
        }
    }

    @Test func listsNothingWithNothingInstalled() async throws {
        let distros = try TemporaryStore()
        let daemon = Daemon(store: distros.store)
        let client = try await daemon.connect()
        defer { client.close() }
        #expect(
            try await client.listDistributions()
                == DistributionList(distributions: [], defaultDistribution: nil))
    }

    @Test func listsEachDistributionByNameWithItsState() async throws {
        let distros = try TemporaryStore()
        for name in ["Zeta", "Ubuntu-24.04", "Alpha"] {
            try distros.install(name)
        }
        let daemon = Daemon(
            factory: FakeFactory { index in (nil, index == 2) }, store: distros.store)
        let client = try await daemon.connect()
        defer { client.close() }

        // A session named in another case runs on the stored name's machine.
        let session = try await client.openSession(on: .distribution(Self.name("ubuntu-24.04")))
        #expect(session.info.machine == .distribution(Self.name("Ubuntu-24.04")))
        // The initramfs machine is not a distribution and is not listed.
        _ = try await client.openSession(on: .initramfs)
        let starting = Task { try await daemon.registry.start(.distribution(Self.name("Zeta"))) }
        try await eventually("Zeta waits to start") {
            daemon.factory.machines.count == 3
                && daemon.factory.machines[2].isWaitingToStart
        }

        #expect(
            try await client.listDistributions()
                == DistributionList(
                    distributions: [
                        Self.entry("Alpha", .stopped), Self.entry("Ubuntu-24.04", .running),
                        Self.entry("Zeta", .starting),
                    ],
                    defaultDistribution: Self.name("Alpha")))
        daemon.factory.machines[2].finishStart()
        try await starting.value
        #expect(daemon.factory.machines.allSatisfy { $0.startCalls == 1 })
    }

    @Test func setsTheDefaultUnderItsStoredSpelling() async throws {
        let distros = try TemporaryStore()
        try distros.install("Alpha")
        try distros.install("Zeta")
        let daemon = Daemon(store: distros.store)
        let client = try await daemon.connect()
        defer { client.close() }
        #expect(try await client.listDistributions().defaultDistribution == Self.name("Alpha"))

        #expect(try await client.setDefault(Self.name("zETA")) == Self.name("Zeta"))
        #expect(try distros.recordedDefault() == "Zeta")
        #expect(try await client.listDistributions().defaultDistribution == Self.name("Zeta"))
        #expect(daemon.factory.machines.isEmpty, "Setting the default started a machine.")

        // A session without -d opens the new default.
        let session = try await client.openSession(on: nil)
        #expect(session.info.machine == .distribution(Self.name("Zeta")))
    }

    @Test func listsTheFirstByNameWhenTheRecordedDefaultIsGone() async throws {
        let distros = try TemporaryStore()
        try distros.install("Zeta")
        try distros.install("Alpha")
        try distros.store.setDefaultDistribution(Self.name("Gone"))
        let daemon = Daemon(store: distros.store)
        let client = try await daemon.connect()
        defer { client.close() }
        #expect(
            try await client.listDistributions()
                == DistributionList(
                    distributions: [Self.entry("Alpha", .stopped), Self.entry("Zeta", .stopped)],
                    defaultDistribution: Self.name("Alpha")))
    }

    @Test func refusesANameThatIsNotInstalled() async throws {
        let distros = try TemporaryStore()
        try distros.install("Alpha")
        // A distribution that is being installed is not installed yet.
        let staging = distros.store.stagingDirectory(for: Self.name("Staged"))
        try distros.store.createStagingDirectory(staging)
        let daemon = Daemon(store: distros.store)
        let client = try await daemon.connect()
        defer { client.close() }

        for name in ["Debian", "Ubuntu", "Staged"] {
            await #expect(throws: MawError.distributionNotInstalled(Self.name(name))) {
                try await client.setDefault(Self.name(name))
            }
            await #expect(throws: MawError.distributionNotInstalled(Self.name(name))) {
                try await client.terminate(Self.name(name))
            }
        }
        #expect(try distros.recordedDefault() == nil)
        #expect(daemon.factory.machines.isEmpty)
        #expect(FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func terminateEndsTheSessionsOfOneDistributionWithTheReason() async throws {
        let distros = try TemporaryStore()
        try distros.install("Alpha")
        try distros.install("Ubuntu-24.04")
        let daemon = Daemon(store: distros.store)
        let user = try await daemon.connect()
        defer { user.close() }
        let session = try await user.openSession(on: .distribution(Self.name("Ubuntu-24.04")))
        let other = try await daemon.connect()
        defer { other.close() }
        _ = try await other.openSession(on: .distribution(Self.name("Alpha")))

        let admin = try await daemon.connect()
        defer { admin.close() }
        #expect(
            try await admin.terminate(Self.name("UBUNTU-24.04"))
                == TerminateSummary(wasRunning: true, endedSessions: 1))
        for await event in user.events {
            #expect(
                event
                    == .sessionEnded(
                        SessionEnded(
                            sessionID: session.info.sessionID,
                            machine: .distribution(Self.name("Ubuntu-24.04")),
                            reason: "maw --terminate was run")))
            break
        }
        #expect(
            try await admin.listDistributions().distributions
                == [Self.entry("Alpha", .running), Self.entry("Ubuntu-24.04", .stopped)])
        let status = try await admin.status()
        #expect(status.machines.map(\.sessionCount) == [1])
    }

    @Test func terminateOfAStoppedDistributionStartsNothing() async throws {
        let distros = try TemporaryStore()
        try distros.install("Ubuntu-24.04")
        let daemon = Daemon(store: distros.store)
        let client = try await daemon.connect()
        defer { client.close() }
        #expect(
            try await client.terminate(Self.name("ubuntu-24.04"))
                == TerminateSummary(wasRunning: false, endedSessions: 0))
        #expect(daemon.factory.machines.isEmpty)
        #expect(try await client.status().machines.isEmpty)
    }
}
