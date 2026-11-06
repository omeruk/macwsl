import Foundation
import Testing

@testable import MawXPC

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

    /// A process being started by another thread holds a copy of the lock's descriptor until
    /// its `execve`; `dup` stands in for that copy. Releasing the lock must still release it.
    @Test func isReleasedWhileACopyOfItsDescriptorRemains() throws {
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var lock = try DaemonLock.acquire(at: url)
        let copy = try #require(lock.map { dup($0.descriptor) })
        try #require(copy >= 0)
        defer { close(copy) }
        #expect(DaemonLock.isHeld(at: url))

        lock = nil
        #expect(!DaemonLock.isHeld(at: url))
        #expect(try DaemonLock.acquire(at: url) != nil)
    }

    /// Which daemons run, by label: only locks that are held count.
    @Test func listsTheLabelsWhoseLocksAreHeld() throws {
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(DaemonLock.labelsHeld(in: directory).isEmpty)
        let held = try DaemonLock.acquire(at: directory.appending(path: "dev.maw.mawd.lock"))
        let other = try DaemonLock.acquire(at: directory.appending(path: "dev.maw.other.lock"))
        var released = try DaemonLock.acquire(at: directory.appending(path: "dev.maw.gone.lock"))
        released = nil
        try Data().write(to: directory.appending(path: "state.json"))
        try Data().write(to: directory.appending(path: ".lock"))
        #expect(DaemonLock.labelsHeld(in: directory) == ["dev.maw.mawd", "dev.maw.other"])
        withExtendedLifetime((held, other, released)) {}
    }
}
