import Foundation
import MawClient
import MawCore
import MawXPC
import Testing

@testable import MawDaemonKit

/// `watchDistributions`, against a store in a temporary directory and fake machines.
extension DaemonServiceTests {
    @Test func speaksInterfaceVersion4() {
        #expect(DaemonInterface.version == 4)
    }

    @Test func watchesTheDistributions() async throws {
        let distros = try TemporaryStore()
        try distros.install("Ubuntu-24.04")
        let daemon = Daemon(store: distros.store)
        let watcher = try await daemon.connect()
        let first = try await watcher.watchDistributions(after: 0)
        #expect(first.distributions.map(\.state) == [.stopped])
        #expect(first.defaultDistribution == Self.name("Ubuntu-24.04"))

        // The reply is held until another client starts the machine.
        let next = Task { try await watcher.watchDistributions(after: first.sequence) }
        let other = try await daemon.connect()
        defer { other.close() }
        _ = try await other.openSession(on: nil)
        let changed = try await next.value
        #expect(changed.sequence > first.sequence)
        #expect(changed.distributions.first?.state != .stopped)

        // A change of the default wakes it as well.
        let latest = try await watcher.watchDistributions(after: 0)
        let third = Task { try await watcher.watchDistributions(after: latest.sequence) }
        try await Task.sleep(for: .milliseconds(20))
        try await other.setDefault(Self.name("ubuntu-24.04"))
        #expect(try await third.value.sequence > latest.sequence)

        watcher.close()
        try await eventually("the end of watching") {
            daemon.lines.count(containing: "stopped watching the distributions") == 1
        }
        let pid = getpid()
        #expect(
            daemon.lines.count(containing: "process \(pid) started watching the distributions") == 1
        )
        #expect(
            daemon.lines.count(containing: "process \(pid) stopped watching the distributions") == 1
        )
        #expect(await !daemon.sampler.hasTimer)
        // Watching took no lease: the session of the other client is the only one.
        #expect(await daemon.registry.status().first?.sessionCount == 1)
    }

    @Test func refusesASecondOutstandingWatch() async throws {
        let distros = try TemporaryStore()
        try distros.install("Ubuntu-24.04")
        let daemon = Daemon(store: distros.store)
        let watcher = try await daemon.connect()
        defer { watcher.close() }
        let first = try await watcher.watchDistributions(after: 0)
        let held = Task { try await watcher.watchDistributions(after: first.sequence) }
        try await Task.sleep(for: .milliseconds(20))
        await #expect(
            throws: MawError.daemonProtocolError(
                reason: "this connection already waits for a distribution snapshot")
        ) {
            try await watcher.watchDistributions(after: first.sequence)
        }
        held.cancel()
        watcher.close()
        _ = await held.result
        #expect(daemon.lines.count(containing: "started watching") == 1)
    }
}
