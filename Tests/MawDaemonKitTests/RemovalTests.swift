import Darwin
import Foundation
import MawClient
import MawCore
import MawDaemonKit
import MawXPC
import Testing

/// `checkUnregister` and `unregister`, against a store and a log directory in a temporary
/// directory and fake machines.
extension DaemonServiceTests {
    @Test func removesAStoppedDistribution() async throws {
        let distros = try TemporaryStore()
        try distros.install("Alpha")
        try distros.install("Zeta")
        let daemon = Daemon(store: distros.store)
        let client = try await daemon.connect()
        defer { client.close() }

        #expect(try await client.checkUnregister(Self.name("zeta")) == Self.name("Zeta"))
        #expect(
            try await client.unregister(Self.name("ZETA"))
                == UnregisterSummary(name: Self.name("Zeta"), newDefault: nil, endedSessions: 0))
        #expect(
            !FileManager.default.fileExists(
                atPath: distros.store.paths.distroDirectory(for: Self.name("Zeta")).path))
        #expect(try distros.stagingEntries().isEmpty)
        #expect(
            try await client.listDistributions()
                == DistributionList(
                    distributions: [Self.entry("Alpha", .stopped)],
                    defaultDistribution: Self.name("Alpha")))
        #expect(daemon.factory.machines.isEmpty, "The removal started a machine.")
        #expect(daemon.lines.count(containing: "Zeta: removal requested by process") == 1)
        #expect(daemon.lines.count(containing: "Zeta: removed for process") == 1)
    }

    /// A session on the removed distribution ends with the removal as its reason.
    @Test func stopsARunningDistributionAndEndsItsSessions() async throws {
        let distros = try TemporaryStore()
        try distros.install("Ubuntu-24.04")
        try distros.install("Zeta")
        let daemon = Daemon(store: distros.store)
        let user = try await daemon.connect()
        defer { user.close() }
        let session = try await user.openSession(on: .distribution(Self.name("Zeta")))

        let admin = try await daemon.connect()
        defer { admin.close() }
        #expect(
            try await admin.unregister(Self.name("Zeta"))
                == UnregisterSummary(name: Self.name("Zeta"), newDefault: nil, endedSessions: 1))
        for await event in user.events {
            #expect(
                event
                    == .sessionEnded(
                        SessionEnded(
                            sessionID: session.info.sessionID,
                            machine: .distribution(Self.name("Zeta")),
                            reason: "maw --unregister was run")))
            break
        }
        #expect(daemon.factory.machines.map(\.stopCalls) == [1])
        #expect(try await admin.status().machines.isEmpty)
        #expect(daemon.lines.count(containing: "its machine was stopped and 1 session ended") == 1)
    }

    /// The default that `state.json` records is cleared, and the reply names the new effective
    /// default.
    @Test func namesTheNewDefaultWhenTheDefaultIsRemoved() async throws {
        let distros = try TemporaryStore()
        try distros.install("Alpha")
        try distros.install("Zeta")
        try distros.store.setDefaultDistribution(Self.name("Zeta"))
        let daemon = Daemon(store: distros.store)
        let client = try await daemon.connect()
        defer { client.close() }

        #expect(try await client.unregister(Self.name("zeta")).newDefault == Self.name("Alpha"))
        #expect(try distros.recordedDefault() == nil)
        #expect(try await client.unregister(Self.name("Alpha")).newDefault == nil)
        #expect(
            try await client.listDistributions()
                == DistributionList(distributions: [], defaultDistribution: nil))
    }

    /// When nothing is recorded, the first installed one by name is the default; removing it
    /// makes the next one the default.
    @Test func namesTheNextDistributionWhenTheEffectiveDefaultIsRemoved() async throws {
        let distros = try TemporaryStore()
        try distros.install("Alpha")
        try distros.install("Beta")
        try distros.install("Gamma")
        let daemon = Daemon(store: distros.store)
        let client = try await daemon.connect()
        defer { client.close() }
        #expect(try await client.unregister(Self.name("Beta")).newDefault == nil)
        #expect(try await client.unregister(Self.name("Alpha")).newDefault == Self.name("Gamma"))
        #expect(try distros.recordedDefault() == nil)
    }

    /// The distribution's three logs go, and every other log stays, the daemon's own and
    /// other distributions' included.
    @Test func deletesTheLogsOfTheRemovedDistributionOnly() async throws {
        let distros = try TemporaryStore()
        try distros.install("Copy")
        try distros.install("Copy-2")
        let logs = distros.home.appending(path: "logs", directoryHint: .isDirectory)
        let removed = MawPaths.distributionLogFiles(for: Self.name("Copy"), in: logs)
        let kept =
            MawPaths.distributionLogFiles(for: Self.name("Copy-2"), in: logs) + [
                logs.appending(path: "mawd.log"), logs.appending(path: "initramfs.log"),
                logs.appending(path: "install-Copy.log"),
            ]
        for file in removed + kept {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("log\n".utf8).write(to: file)
        }
        let daemon = Daemon(store: distros.store, logDirectory: logs)
        let client = try await daemon.connect()
        defer { client.close() }

        _ = try await client.unregister(Self.name("copy"))
        for file in removed {
            #expect(!FileManager.default.fileExists(atPath: file.path), "\(file.path)")
        }
        for file in kept {
            #expect(FileManager.default.fileExists(atPath: file.path), "\(file.path)")
        }
    }

    /// Only installed distributions are removed: a directory without `distro.json` stays, as
    /// `distributionDirectoryExists` promises.
    @Test func refusesANameThatIsNotInstalledAndChangesNothing() async throws {
        let distros = try TemporaryStore()
        try distros.install("Alpha")
        let leftover = distros.store.paths.distroDirectory(for: Self.name("Partial"))
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: leftover.appending(path: "disk.img"))
        let daemon = Daemon(store: distros.store)
        let client = try await daemon.connect()
        defer { client.close() }

        for name in ["Partial", "Debian"] {
            await #expect(throws: MawError.distributionNotInstalled(Self.name(name))) {
                try await client.checkUnregister(Self.name(name))
            }
            await #expect(throws: MawError.distributionNotInstalled(Self.name(name))) {
                try await client.unregister(Self.name(name))
            }
        }
        #expect(FileManager.default.fileExists(atPath: leftover.appending(path: "disk.img").path))
        #expect(
            try await client.listDistributions().distributions == [Self.entry("Alpha", .stopped)])
    }

    /// While a removal stops the machine, every request that names the distribution fails with
    /// an error that names the removal, and nothing waits or starts a machine.
    @Test func refusesEveryRequestThatNamesADistributionBeingRemoved() async throws {
        let distros = try TemporaryStore()
        try distros.install("Copy")
        let daemon = Daemon(factory: FakeFactory(holdsStop: true), store: distros.store)
        let user = try await daemon.connect()
        defer { user.close() }
        _ = try await user.openSession(on: .distribution(Self.name("Copy")))
        let admin = try await daemon.connect()
        defer { admin.close() }
        let removal = Task { try await admin.unregister(Self.name("Copy")) }
        try await eventually("the removal stops the machine") {
            daemon.factory.machines.first?.isWaitingToStop == true
        }

        let other = try await daemon.connect()
        defer { other.close() }
        let busy = MawError.distributionBusy(Self.name("Copy"), operation: .removal)
        await #expect(throws: busy) { try await other.checkUnregister(Self.name("copy")) }
        await #expect(throws: busy) { try await other.unregister(Self.name("Copy")) }
        await #expect(throws: busy) { try await other.setDefault(Self.name("Copy")) }
        await #expect(throws: busy) { try await other.terminate(Self.name("COPY")) }
        await #expect(throws: busy) {
            _ = try await other.openSession(on: .distribution(Self.name("Copy")))
        }
        // Without -d, the default distribution is the one being removed.
        await #expect(throws: busy) { _ = try await other.openSession(on: nil) }

        daemon.factory.machines[0].finishStop()
        #expect(try await removal.value.endedSessions == 1)
        #expect(daemon.factory.machines.count == 1, "A request started a machine.")
        await #expect(throws: MawError.distributionNotInstalled(Self.name("Copy"))) {
            try await other.unregister(Self.name("Copy"))
        }
    }

    /// A removal that cannot move the directory deletes nothing and leaves the distribution
    /// installed.
    @Test func reportsARemovalThatCannotMoveTheDirectory() async throws {
        let distros = try TemporaryStore()
        try distros.install("Copy")
        // The staging directory cannot be created where a file is.
        try FileManager.default.removeItem(at: distros.store.paths.stagingRoot)
        try Data().write(to: distros.store.paths.stagingRoot)
        let daemon = Daemon(store: distros.store)
        let client = try await daemon.connect()
        defer { client.close() }

        await #expect {
            try await client.unregister(Self.name("Copy"))
        } throws: { error in
            guard case .removalFailed(let name, _) = error as? MawError else { return false }
            return name == Self.name("Copy")
        }
        #expect(
            try await client.listDistributions().distributions == [Self.entry("Copy", .stopped)])
        #expect(daemon.lines.count(containing: "Copy: removal for process") == 1)
        // The name is free again.
        try FileManager.default.removeItem(at: distros.store.paths.stagingRoot)
        _ = try await client.unregister(Self.name("Copy"))
    }
}

extension TemporaryStore {
    /// What this daemon's staging directory holds.
    func stagingEntries() throws -> [String] {
        let directory = store.stagingDirectory(for: try DistroName("x")).deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }
}

@Suite struct RemovalStoreTests {
    /// A removal moves the directory into the label's staging directory, from where a crash
    /// leaves it for the next start, which removes it.
    @Test func leavesAnInterruptedRemovalForTheNextStart() throws {
        let distros = try TemporaryStore()
        try distros.install("Copy")
        let moved = try distros.store.moveForRemoval(try DistroName("Copy"))
        #expect(moved.lastPathComponent.hasPrefix("Copy-"))
        #expect(moved.lastPathComponent.hasSuffix(DistributionStore.removalSuffix))
        #expect(FileManager.default.fileExists(atPath: moved.appending(path: "distro.json").path))
        #expect(!distros.store.isInstalled(try DistroName("Copy")))
        #expect(distros.store.installed().isEmpty)

        // The daemon stopped here. At its next start:
        #expect(distros.store.removeStagingLeftovers() == [moved.lastPathComponent])
        #expect(try distros.stagingEntries().isEmpty)
    }

    /// Another label's staging directory, which another daemon owns, is never touched.
    @Test func leavesAnotherDaemonsRemovalAlone() throws {
        let distros = try TemporaryStore()
        try distros.install("Copy")
        let other = DistributionStore(
            paths: distros.store.paths, daemonLabel: try DaemonLabel("dev.maw.mawd.other"))
        let moved = try other.moveForRemoval(try DistroName("Copy"))
        #expect(distros.store.removeStagingLeftovers().isEmpty)
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(other.removeStagingLeftovers() == [moved.lastPathComponent])
    }

    /// A symbolic link in place of the distribution's directory is moved and removed as a link;
    /// what it points to stays.
    @Test func movesALinkAsALink() throws {
        let distros = try TemporaryStore()
        let target = distros.home.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: target.appending(path: "disk.img"))
        try FileManager.default.createSymbolicLink(
            at: distros.store.paths.distroDirectory(for: try DistroName("Linked")),
            withDestinationURL: target)
        let moved = try distros.store.moveForRemoval(try DistroName("Linked"))
        distros.store.removeStagingDirectory(moved)
        #expect(try distros.stagingEntries().isEmpty)
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "disk.img").path))
    }

    @Test func clearsTheDefaultOnlyWhenItNamesTheDistribution() throws {
        let distros = try TemporaryStore()
        try distros.store.setDefaultDistribution(try DistroName("Alpha"))
        #expect(try !distros.store.clearDefaultDistribution(ifItNames: try DistroName("Zeta")))
        #expect(try distros.recordedDefault() == "Alpha")
        #expect(try distros.store.clearDefaultDistribution(ifItNames: try DistroName("ALPHA")))
        #expect(try distros.recordedDefault() == nil)
    }
}
