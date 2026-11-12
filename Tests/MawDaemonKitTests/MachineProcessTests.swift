import Darwin
import Testing
import os

@testable import MawDaemonKit

/// The lookup of a machine's Virtualization process, against a fake process table.
@Suite struct MachineProcessTests {
    static let user: uid_t = 501
    static let disk = FileIdentity(device: 16_777_234, inode: 4_242)
    static let otherDisk = FileIdentity(device: 16_777_234, inode: 7_777)
    static let machinePath = MachineProcessFinder.executablePath

    @Test func findsTheOneProcessWithTheDiskImageOpen() {
        let table = FakeProcessTable([
            .init(id: 300, path: "/usr/sbin/cfprefsd", user: Self.user, files: [Self.disk]),
            .init(id: 400, path: Self.machinePath, user: Self.user, files: [Self.otherDisk]),
            .init(id: 500, path: Self.machinePath, user: Self.user, files: [Self.disk]),
        ])
        #expect(
            MachineProcessFinder.find(diskImage: Self.disk, user: Self.user, in: table)
                == ProcessIdentity(processID: 500, startTime: 5_000))
    }

    @Test func findsNothingWithoutAMatch() {
        let table = FakeProcessTable([
            .init(id: 400, path: Self.machinePath, user: Self.user, files: [Self.otherDisk])
        ])
        #expect(MachineProcessFinder.find(diskImage: Self.disk, user: Self.user, in: table) == nil)
        #expect(
            MachineProcessFinder.find(
                diskImage: Self.disk, user: Self.user, in: FakeProcessTable([])) == nil)
    }

    /// Two processes with the disk open cannot both run the machine; neither is chosen.
    @Test func findsNothingWhenTwoProcessesMatch() {
        let table = FakeProcessTable([
            .init(id: 400, path: Self.machinePath, user: Self.user, files: [Self.disk]),
            .init(id: 500, path: Self.machinePath, user: Self.user, files: [Self.disk]),
        ])
        #expect(MachineProcessFinder.find(diskImage: Self.disk, user: Self.user, in: table) == nil)
    }

    @Test func ignoresAnotherUsersProcessAndAnotherExecutable() {
        let table = FakeProcessTable([
            .init(id: 400, path: Self.machinePath, user: 502, files: [Self.disk]),
            .init(id: 500, path: Self.machinePath + "2", user: Self.user, files: [Self.disk]),
            .init(id: 600, path: nil, user: Self.user, files: [Self.disk]),
        ])
        #expect(MachineProcessFinder.find(diskImage: Self.disk, user: Self.user, in: table) == nil)
    }

    /// The open files are read only for processes that passed the filter by path and user.
    @Test func readsOpenFilesOnlyOfVirtualizationProcessesOfTheUser() {
        let table = FakeProcessTable([
            .init(id: 300, path: "/usr/sbin/cfprefsd", user: Self.user, files: [Self.disk]),
            .init(id: 400, path: Self.machinePath, user: 502, files: [Self.disk]),
            .init(id: 500, path: Self.machinePath, user: Self.user, files: [Self.disk]),
            .init(id: 600, path: Self.machinePath, user: Self.user, files: [Self.otherDisk]),
        ])
        _ = MachineProcessFinder.find(diskImage: Self.disk, user: Self.user, in: table)
        #expect(table.openFilesRead == [500, 600])
    }

    @Test func readsTheUsageOfTheSameProcessOnly() {
        let table = FakeProcessTable([
            .init(id: 500, path: Self.machinePath, user: Self.user, files: [Self.disk])
        ])
        let process = ProcessIdentity(processID: 500, startTime: 5_000)
        #expect(
            MachineProcessFinder.usage(of: process, in: table)
                == ProcessUsage(cpuNanoseconds: 500_000, footprintBytes: 5_000_000))
        // The process ID now names a process that started later.
        table.replace(
            .init(id: 500, path: Self.machinePath, user: Self.user, files: [], startTime: 9_000))
        #expect(MachineProcessFinder.usage(of: process, in: table) == nil)
        table.replace(nil, id: 500)
        #expect(MachineProcessFinder.usage(of: process, in: table) == nil)
    }

    /// At the run's first sample, then at each sample while nothing is found, at most 10 more
    /// times; then never again in that run, and reported once.
    @Test func retriesTenTimesThenGivesUpOnce() {
        var lookup = MachineProcessLookup()
        var calls = 0
        var outcomes: [MachineProcessLookup.Outcome] = []
        for _ in 0..<15 {
            outcomes.append(
                lookup.next {
                    calls += 1
                    return nil
                })
        }
        #expect(calls == 11)
        #expect(outcomes.prefix(10).allSatisfy { $0 == .notYet })
        #expect(outcomes[10] == .gaveUp)
        #expect(outcomes.dropFirst(11).allSatisfy { $0 == .givenUp })
    }

    @Test func keepsTheProcessOnceFound() {
        var lookup = MachineProcessLookup()
        let process = ProcessIdentity(processID: 500, startTime: 5_000)
        var calls = 0
        #expect(
            lookup.next {
                calls += 1
                return nil
            } == .notYet)
        #expect(
            lookup.next {
                calls += 1
                return process
            } == .found(process))
        #expect(
            lookup.next {
                calls += 1
                return nil
            } == .found(process))
        #expect(calls == 2)
    }

    /// The real table reads this test process: its executable, its user, and an open file.
    @Test func readsTheTestProcessThroughLibproc() throws {
        let table = DarwinProcessTable()
        let me = getpid()
        #expect(table.processIDs().contains(me))
        #expect(table.executablePath(of: me) != nil)
        let owner = try #require(table.owner(of: me))
        #expect(owner.user == getuid())
        let path = "/tmp/maw-process-\(me)-\(UInt64.random(in: 0...UInt64.max))"
        let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        try #require(descriptor >= 0)
        defer {
            close(descriptor)
            unlink(path)
        }
        let identity = try #require(FileIdentity(path: path))
        #expect(table.openFiles(of: me).contains(identity))
        let usage = try #require(
            MachineProcessFinder.usage(
                of: ProcessIdentity(processID: me, startTime: owner.startTime), in: table))
        #expect(usage.cpuNanoseconds > 0 && usage.footprintBytes > 0)
    }
}

/// A process table whose processes the test lists. It records whose open files were read.
final class FakeProcessTable: ProcessTable, Sendable {
    struct Process: Sendable {
        var id: pid_t
        var path: String?
        var user: uid_t
        var files: [FileIdentity]
        var startTime: UInt64?
    }

    private let state: OSAllocatedUnfairLock<(processes: [pid_t: Process], read: [pid_t])>

    init(_ processes: [Process]) {
        state = OSAllocatedUnfairLock(
            initialState: (Dictionary(uniqueKeysWithValues: processes.map { ($0.id, $0) }), []))
    }

    var openFilesRead: [pid_t] { state.withLock { $0.read } }

    func replace(_ process: Process?, id: pid_t? = nil) {
        state.withLock { $0.processes[process?.id ?? id ?? 0] = process }
    }

    func processIDs() -> [pid_t] { state.withLock { $0.processes.keys.sorted() } }

    func executablePath(of processID: pid_t) -> String? {
        state.withLock { $0.processes[processID]?.path }
    }

    func owner(of processID: pid_t) -> (user: uid_t, startTime: UInt64)? {
        state.withLock { state in
            state.processes[processID].map {
                ($0.user, $0.startTime ?? UInt64($0.id) * 10)
            }
        }
    }

    func openFiles(of processID: pid_t) -> [FileIdentity] {
        state.withLock {
            $0.read.append(processID)
            return $0.processes[processID]?.files ?? []
        }
    }

    func usage(of processID: pid_t) -> ProcessUsage? {
        state.withLock {
            $0.processes[processID].map {
                ProcessUsage(
                    cpuNanoseconds: UInt64($0.id) * 1_000, footprintBytes: UInt64($0.id) * 10_000)
            }
        }
    }
}
