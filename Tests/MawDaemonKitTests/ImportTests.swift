import Darwin
import Foundation
import MawCore
import MawXPC
import Testing

@testable import MawDaemonKit

/// `maw --import` in the daemon (docs/daemon.md, "Importing a distribution").
@Suite struct ImportTests {
    static let copy = try! DistroName("Copy")

    /// A daemon without an importer, as some unit tests wire it, says so.
    @Test func reportsADaemonWithoutImports() async throws {
        let distros = try TemporaryStore()
        let daemon = DaemonServiceTests.Daemon(store: distros.store)
        let client = try await daemon.connect()
        defer { client.close() }
        await #expect(
            throws: MawError.daemonProtocolError(reason: "this daemon was started without imports")
        ) {
            try await client.import(
                ImportRequest(name: Self.copy, user: nil, archive: "standard input"),
                from: STDIN_FILENO)
        }
    }
}
