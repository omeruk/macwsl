import Foundation
import MawXPC
import Testing

@Suite struct DaemonLockTests {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "maw-lock-\(UUID().uuidString)/dev.maw.mawd.lock")

    @Test func isNotHeldWithoutAFile() {
        #expect(!DaemonLock.isHeld(at: url))
    }

    @Test func isHeldWhileTheLockExists() throws {
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var lock = try DaemonLock.acquire(at: url)
        #expect(lock != nil)
        #expect(DaemonLock.isHeld(at: url))
        #expect(try DaemonLock.acquire(at: url) == nil, "A second holder must be refused.")

        lock = nil
        #expect(!DaemonLock.isHeld(at: url))
        #expect(try DaemonLock.acquire(at: url) != nil)
    }
}
