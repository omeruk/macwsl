import Darwin
import Foundation
import MawClient
import MawCore
import MawProtocol
import MawXPC
import Testing

/// A session whose connection ends before the command's exit status, without a virtual
/// machine: a socket pair whose other end plays the agent, sends output frames, then nothing
/// more or part of a frame, and closes. The session runs through `SessionEnding`, which `maw`
/// and the terminal app share; `mawTests` checks how `maw` prints the errors.
///
/// A reset is not tested: a Unix-domain socket pair, the kind a session's connection is on
/// the host, reports a peer's close as end-of-file even with unread data or `SO_LINGER` 0, and
/// `FrameConnection` treats a reset as end-of-file anyway.
@Suite struct SessionEndingTests {
    static let machine = MachineID.distribution(try! DistroName("Ubuntu-24.04"))

    /// Case a: output frames, then part of a frame, then the end.
    @Test func reportsAnEndInTheMiddleOfAFrame() async throws {
        let cut = Array(Frame(type: .stdout, payload: Array("3\n".utf8)).encoded.prefix(6))
        let run = try await session(sendingOutput: ["1\n", "2\n"], thenPartialFrame: cut)
        #expect(run.output == "1\n2\n")
        #expect(run.result == .failure(.sessionConnectionEnded(distribution: "Ubuntu-24.04")))
    }

    /// Case b: output frames, then the end at a frame boundary, before the exit status.
    @Test func reportsAnEndAtAFrameBoundary() async throws {
        let run = try await session(sendingOutput: ["1\n", "2\n"])
        #expect(run.output == "1\n2\n")
        #expect(run.result == .failure(.sessionConnectionEnded(distribution: "Ubuntu-24.04")))
    }

    /// Case c: the daemon reports that the machine stopped. The error stays the machine-stopped
    /// one, which does not say that the command may still be running.
    @Test(arguments: [true, false])
    func keepsTheMachineStoppedError(cutInAFrame: Bool) async throws {
        let ended = SessionEnded(
            sessionID: 1, machine: Self.machine, reason: "maw --shutdown was run")
        let cut = Array(Frame(type: .stdout, payload: Array("3\n".utf8)).encoded.prefix(6))
        let run = try await session(
            sendingOutput: ["1\n"], thenPartialFrame: cutInAFrame ? cut : [],
            daemonEvent: .sessionEnded(ended))
        #expect(run.output == "1\n")
        #expect(
            run.result
                == .failure(
                    .machineStopped(machine: "Ubuntu-24.04", reason: "maw --shutdown was run")))
    }

    /// A command that exits is reported by its status, as before.
    @Test func returnsTheExitStatusOfACommandThatExits() async throws {
        let run = try await session(sendingOutput: ["1\n"], exitCode: 3)
        #expect(run.output == "1\n")
        #expect(run.result == .success(.exited(.exited(code: 3))))
        #expect(try run.result.get().shellStatus == 3)
    }

    @Test func mapsEachDaemonEventToItsError() {
        let ended = SessionEnded(
            sessionID: 1, machine: Self.machine, reason: "maw --terminate was run")
        #expect(
            SessionEnding.error(for: .sessionEnded(ended), machine: Self.machine)
                == .machineStopped(machine: "Ubuntu-24.04", reason: "maw --terminate was run"))
        #expect(
            SessionEnding.error(for: .connectionLost, machine: Self.machine)
                == .daemonConnectionLost(during: "the session on Ubuntu-24.04"))
    }

    @Test func reportsASignalAsTheShellWould() async throws {
        let (events, continuation) = AsyncStream.makeStream(of: DaemonClient.Event.self)
        defer { continuation.finish() }
        let outcome = try await SessionEnding.signal(15).outcome(
            events: EventRelay(events), machine: Self.machine)
        #expect(outcome == .signal(15))
        #expect(outcome.shellStatus == 143)
    }

    // MARK: Helpers

    struct Run {
        var output: String
        var result: Result<SessionEnding.Outcome, MawError>
    }

    /// Runs a session against a scripted agent that answers `exec`, sends `output` as stdout
    /// frames, then either the exit status or `partialFrame`, and closes its side. The daemon's
    /// event stream sends `daemonEvent` once the agent has closed, or nothing.
    private func session(
        sendingOutput output: [String], thenPartialFrame partialFrame: [UInt8] = [],
        exitCode: Int32? = nil, daemonEvent: DaemonClient.Event? = nil
    ) async throws -> Run {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let host = OwnedDescriptor(fds[0])
        let peer = OwnedDescriptor(fds[1])
        let (events, continuation) = AsyncStream.makeStream(of: DaemonClient.Event.self)
        let agentClosed = AsyncStream.makeStream(of: Void.self)
        Thread {
            defer {
                peer.close()
                agentClosed.continuation.finish()
            }
            guard let connection = try? FrameConnection(peer) else { return }
            _ = try? connection.exchangeVersions(until: .now + .seconds(5))
            _ = try? connection.receiveControl(until: .now + .seconds(5), expecting: "exec")
            connection.enqueue(.control(.started(pid: 7)))
            for text in output {
                connection.enqueue(Frame(type: .stdout, payload: Array(text.utf8)))
            }
            if let exitCode {
                connection.enqueue(.control(.exited(.exited(code: exitCode))))
            }
            try? connection.flush(until: .now + .seconds(5))
            if !partialFrame.isEmpty {
                _ = partialFrame.withUnsafeBytes {
                    Darwin.write(peer.rawValue, $0.baseAddress, $0.count)
                }
            }
            if exitCode != nil {
                // Waits for the client to close, as the agent does after `exited`.
                while (try? connection.receiveFrame(until: .now + .seconds(10))) != nil {}
            }
        }.start()
        Task {
            for await _ in agentClosed.stream {}
            if let daemonEvent {
                continuation.yield(daemonEvent)
            }
        }

        let received = Received()
        let client = GuestAgentClient(guestName: Self.machine.name) { () throws(MawError) in host }
        let process = try await client.exec(ExecRequest(argv: ["seq", "1", "inf"])) { _, bytes in
            received.append(bytes)
        }
        let relay = EventRelay(events)
        let ending = await SessionEnding.first(process: process, events: relay, signals: nil)
        let result: Result<SessionEnding.Outcome, MawError>
        do throws(MawError) {
            result = .success(try await ending.outcome(events: relay, machine: Self.machine))
        } catch {
            result = .failure(error)
        }
        continuation.finish()
        // The process has ended once its output has been delivered, whichever ending came first.
        _ = try? await process.waitForExit()
        return Run(output: received.text, result: result)
    }
}

/// `EventRelay` keeps the first event of a session for every waiter.
@Suite struct EventRelayTests {
    static let ended = DaemonClient.Event.sessionEnded(
        SessionEnded(
            sessionID: 1, machine: SessionEndingTests.machine, reason: "maw --shutdown was run"))

    @Test func keepsTheFirstEventForEveryLaterWaiter() async {
        let (events, continuation) = AsyncStream.makeStream(of: DaemonClient.Event.self)
        let relay = EventRelay(events)
        continuation.yield(Self.ended)
        continuation.yield(.connectionLost)
        #expect(await relay.next() == Self.ended)
        #expect(await relay.next() == Self.ended)
        continuation.finish()
        #expect(await relay.next(within: .seconds(10)) == Self.ended)
    }

    @Test func dropsInstallationProgress() async {
        let (events, continuation) = AsyncStream.makeStream(of: DaemonClient.Event.self)
        let relay = EventRelay(events)
        continuation.yield(.installProgress(.started(.download)))
        continuation.yield(.connectionLost)
        #expect(await relay.next() == .connectionLost)
        continuation.finish()
    }

    @Test func returnsNothingWhenTheStreamFinishesWithoutAnEvent() async {
        let (events, continuation) = AsyncStream.makeStream(of: DaemonClient.Event.self)
        let relay = EventRelay(events)
        continuation.finish()
        #expect(await relay.next() == nil)
    }

    @Test func returnsNothingWithinATimeoutWithoutAnEvent() async {
        let (events, continuation) = AsyncStream.makeStream(of: DaemonClient.Event.self)
        defer { continuation.finish() }
        let relay = EventRelay(events)
        #expect(await relay.next(within: .milliseconds(50)) == nil)
    }

    /// A waiter that is cancelled returns `nil` and does not take the event from the next one.
    @Test func keepsTheEventFromAWaiterThatIsCancelled() async throws {
        let (events, continuation) = AsyncStream.makeStream(of: DaemonClient.Event.self)
        let relay = EventRelay(events)
        let waiting = Task { await relay.next() }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        #expect(await waiting.value == nil)
        continuation.yield(Self.ended)
        #expect(await relay.next() == Self.ended)
        continuation.finish()
    }
}

/// Output collected from the output handler's thread.
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    func append(_ data: UnsafeRawBufferPointer) { lock.withLock { bytes += data } }
    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
}
