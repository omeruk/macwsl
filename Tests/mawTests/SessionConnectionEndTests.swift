import ArgumentParser
import Darwin
import Foundation
import MawClient
import MawCore
import MawProtocol
import MawXPC
import Testing

@testable import maw

/// A session whose connection ends before the command's exit status, without a virtual
/// machine: a socket pair whose other end plays the agent, sends output frames, then nothing
/// more or part of a frame, and closes. The session runs through `SessionRunner`'s ending
/// logic, and the error is rendered as `maw` prints it.
///
/// A reset is not tested: a Unix-domain socket pair, the kind a session's connection is on
/// the host, reports a peer's close as end-of-file even with unread data or `SO_LINGER` 0, and
/// `FrameConnection` treats a reset as end-of-file anyway.
@Suite struct SessionConnectionEndTests {
    static let machine = MachineID.distribution(try! DistroName("Ubuntu-24.04"))

    static let printed = """
        maw: The connection to the session in Ubuntu-24.04 ended unexpectedly.
        The output may be incomplete, and the command may still be running there.
        If the command is still running, find its process ID with
        maw -d Ubuntu-24.04 -e ps -ef and end it with maw -d Ubuntu-24.04 -e kill <ID>.
        maw --terminate Ubuntu-24.04 also ends it, and every other session there.

        """

    /// Case a: output frames, then part of a frame, then the end.
    @Test func reportsAnEndInTheMiddleOfAFrame() async throws {
        let cut = Array(Frame(type: .stdout, payload: Array("3\n".utf8)).encoded.prefix(6))
        let run = try await session(sendingOutput: ["1\n", "2\n"], thenPartialFrame: cut)
        #expect(run.output == "1\n2\n")
        try expectConnectionEnd(run.result)
    }

    /// Case b: output frames, then the end at a frame boundary, before the exit status.
    @Test func reportsAnEndAtAFrameBoundary() async throws {
        let run = try await session(sendingOutput: ["1\n", "2\n"])
        #expect(run.output == "1\n2\n")
        try expectConnectionEnd(run.result)
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
        let error = try #require(run.result.failure as? MawError)
        #expect(
            error == .machineStopped(machine: "Ubuntu-24.04", reason: "maw --shutdown was run"))
        let failure = try #require(Maw.failure(for: error))
        #expect(
            failure.output
                == "maw: The session ended because the virtual machine Ubuntu-24.04 stopped:\n"
                + "maw --shutdown was run.\nRun the command again to start a new virtual "
                + "machine.\n")
        #expect(!failure.output.contains("still be running"))
    }

    /// A command that exits is reported by its status, as before.
    @Test func returnsTheExitStatusOfACommandThatExits() async throws {
        let run = try await session(sendingOutput: ["1\n"], exitCode: 3)
        #expect(run.output == "1\n")
        #expect(try run.result.get() == 3)
    }

    // MARK: Helpers

    struct Run {
        var output: String
        var result: Result<Int32, any Error>
    }

    /// The new error, printed on standard error as `maw` prints it, with exit status 1, the
    /// status of every runtime error (`CommandFailure`).
    private func expectConnectionEnd(_ result: Result<Int32, any Error>) throws {
        let error = try #require(result.failure as? MawError)
        #expect(error == .sessionConnectionEnded(distribution: "Ubuntu-24.04"))
        let failure = try #require(Maw.failure(for: error))
        #expect(failure.output == Self.printed)
        #expect(failure.exitCode == ExitCode(1))
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
        let ending = await SessionRunner.firstEnding(process: process, events: relay, signals: nil)
        let result: Result<Int32, any Error>
        do {
            result = .success(
                try await SessionRunner.status(after: ending, events: relay, machine: Self.machine))
        } catch {
            result = .failure(error)
        }
        continuation.finish()
        // The process has ended once its output has been delivered, whichever ending came first.
        _ = try? await process.waitForExit()
        return Run(output: received.text, result: result)
    }
}

/// Output collected from the output handler's thread.
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    func append(_ data: UnsafeRawBufferPointer) { lock.withLock { bytes += data } }
    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
}

extension Result {
    fileprivate var failure: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}
