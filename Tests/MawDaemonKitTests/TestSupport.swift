import Darwin
import Foundation
import MawCore
import MawDaemonKit
import MawProtocol
import os

/// A clock that moves only when a test calls `advance(by:)`, so that timeouts of a minute
/// pass at once.
final class TestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let state = OSAllocatedUnfairLock(
        initialState: (
            now: Instant(offset: .zero), sleepers: [UUID: Sleeper](), endsSleepsAtOnce: false
        ))

    /// Whether a new sleep throws `CancellationError` at once, as a sleep does whose task is
    /// cancelled before its deadline.
    var endsSleepsAtOnce: Bool {
        get { state.withLock { $0.endsSleepsAtOnce } }
        set { state.withLock { $0.endsSleepsAtOnce = newValue } }
    }

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    /// The number of tasks sleeping on this clock.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow = state.withLock { state -> Bool in
                    if deadline <= state.now || Task.isCancelled || state.endsSleepsAtOnce {
                        return true
                    }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return false
                }
                if resumeNow {
                    if Task.isCancelled || endsSleepsAtOnce {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            state.withLock { $0.sleepers.removeValue(forKey: id) }?
                .continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock forward and wakes every sleeper whose deadline has passed.
    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let due = state.sleepers.filter { $0.value.deadline <= state.now }
            for id in due.keys { state.sleepers.removeValue(forKey: id) }
            return Array(due.values)
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}

/// Waits until `condition` holds, without depending on how long other tasks take. Fails
/// after 5 seconds of real time.
func eventually(
    _ description: String = "the condition", _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            throw TestFailure("\(description) did not become true within 5 seconds")
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(1))
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A machine that boots, and with `holdsStop` stops, when the test says so, and whose agent
/// connections are socket pairs.
final class FakeMachine: MachineHandle, @unchecked Sendable {
    let machine: MachineID
    let cpuCount = 2
    let memoryBytes: UInt64 = 1 << 30
    let kernelRelease: String? = "6.18.57-maw"
    let bootMilliseconds: UInt64? = 271
    let unexpectedStops: AsyncStream<String>

    private let lock = OSAllocatedUnfairLock(
        initialState: (
            startCalls: 0, stopCalls: 0, connections: 0,
            release: CheckedContinuation<Void, Never>?(nil),
            released: false,
            stopRelease: CheckedContinuation<Void, Never>?(nil),
            stopReleased: false
        ))
    private let startError: MawError?
    private let holdsStart: Bool
    private let holdsStop: Bool
    private let stopContinuation: AsyncStream<String>.Continuation

    init(
        machine: MachineID, startError: MawError? = nil, holdsStart: Bool = false,
        holdsStop: Bool = false
    ) {
        self.machine = machine
        self.startError = startError
        self.holdsStart = holdsStart
        self.holdsStop = holdsStop
        (unexpectedStops, stopContinuation) = AsyncStream.makeStream(of: String.self)
    }

    var startCalls: Int { lock.withLock { $0.startCalls } }
    var stopCalls: Int { lock.withLock { $0.stopCalls } }
    var connections: Int { lock.withLock { $0.connections } }
    var isWaitingToStart: Bool { lock.withLock { $0.release != nil } }
    var isWaitingToStop: Bool { lock.withLock { $0.stopRelease != nil } }

    func start() async throws(MawError) {
        lock.withLock { $0.startCalls += 1 }
        if holdsStart {
            await withCheckedContinuation { continuation in
                let releaseNow = lock.withLock { state -> Bool in
                    if state.released { return true }
                    state.release = continuation
                    return false
                }
                if releaseNow { continuation.resume() }
            }
        }
        if let startError {
            throw startError
        }
    }

    /// Lets a held start finish.
    func finishStart() {
        let continuation = lock.withLock { state -> CheckedContinuation<Void, Never>? in
            state.released = true
            defer { state.release = nil }
            return state.release
        }
        continuation?.resume()
    }

    func openSessionConnection() async throws(MawError) -> OwnedDescriptor {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw .guestAgentUnavailable(reason: "socketpair failed")
        }
        close(fds[1])
        lock.withLock { $0.connections += 1 }
        return OwnedDescriptor(fds[0])
    }

    /// 412 MiB in use of 2 GiB.
    static let defaultSample = GuestSample(
        memoryTotalBytes: 2 << 30, memoryAvailableBytes: (2 << 30) - (412 << 20),
        ipv4Address: "192.168.64.3")

    /// What `sample()` returns.
    let sampleResult = OSAllocatedUnfairLock(
        initialState: Result<GuestSample, MawError>.success(defaultSample))

    private let samples = OSAllocatedUnfairLock(
        initialState: (calls: 0, holds: false, held: [CheckedContinuation<Void, Never>]()))

    var sampleCalls: Int { samples.withLock { $0.calls } }

    /// Makes every `sample()` wait until `releaseSamples()`.
    func holdSamples() {
        samples.withLock { $0.holds = true }
    }

    func releaseSamples() {
        let held = samples.withLock { state in
            defer { state = (state.calls, false, []) }
            return state.held
        }
        for continuation in held {
            continuation.resume()
        }
    }

    func sample() async throws(MawError) -> GuestSample {
        await withCheckedContinuation { continuation in
            let resumeNow = samples.withLock { state -> Bool in
                state.calls += 1
                if !state.holds { return true }
                state.held.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return try sampleResult.withLock { $0 }.get()
    }

    func stop() async -> String {
        lock.withLock { $0.stopCalls += 1 }
        if holdsStop {
            await withCheckedContinuation { continuation in
                let releaseNow = lock.withLock { state -> Bool in
                    if state.stopReleased { return true }
                    state.stopRelease = continuation
                    return false
                }
                if releaseNow { continuation.resume() }
            }
        }
        stopContinuation.finish()
        return "stopped by the test"
    }

    /// Lets a held stop finish.
    func finishStop() {
        let continuation = lock.withLock { state -> CheckedContinuation<Void, Never>? in
            state.stopReleased = true
            defer { state.stopRelease = nil }
            return state.stopRelease
        }
        continuation?.resume()
    }

    /// Simulates the guest powering off or crashing.
    func crash(_ reason: String) {
        stopContinuation.yield(reason)
        stopContinuation.finish()
    }
}

/// Creates `FakeMachine`s and remembers them, newest last.
final class FakeFactory: Sendable {
    private let made = OSAllocatedUnfairLock(initialState: [FakeMachine]())
    private let configure: @Sendable (Int) -> (startError: MawError?, holdsStart: Bool)
    private let holdsStop: Bool

    /// - Parameter holdsStop: Whether every machine's stop waits for `finishStop()`.
    init(
        holdsStop: Bool = false,
        _ configure: @escaping @Sendable (Int) -> (startError: MawError?, holdsStart: Bool) = {
            _ in (nil, false)
        }
    ) {
        self.holdsStop = holdsStop
        self.configure = configure
    }

    var machines: [FakeMachine] { made.withLock { $0 } }

    var factory: MachineFactory {
        { [self] (machine: MachineID) throws(MawError) -> any MachineHandle in
            let index = made.withLock { $0.count }
            let (startError, holdsStart) = configure(index)
            let fake = FakeMachine(
                machine: machine, startError: startError, holdsStart: holdsStart,
                holdsStop: holdsStop)
            made.withLock { $0.append(fake) }
            return fake
        }
    }
}

/// Collects the leases that ended, with their reasons.
final class EndedLeases: Sendable {
    private let ended = OSAllocatedUnfairLock(initialState: [(Lease, String)]())

    var all: [(Lease, String)] { ended.withLock { $0 } }

    var handler: @Sendable (Lease, String) -> Void {
        { [ended] lease, reason in ended.withLock { $0.append((lease, reason)) } }
    }
}

/// Collects the daemon's log lines.
final class LogLines: Sendable {
    private let lines = OSAllocatedUnfairLock(initialState: [String]())

    var all: [String] { lines.withLock { $0 } }

    var log: DaemonLog {
        DaemonLog { [lines] line in lines.withLock { $0.append(line) } }
    }

    func count(containing text: String) -> Int {
        all.filter { $0.contains(text) }.count
    }
}
