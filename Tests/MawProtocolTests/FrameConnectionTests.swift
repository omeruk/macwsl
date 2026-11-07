import CMawSystem
import Testing

@testable import MawProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// `FrameConnection` on a socket pair.
@Suite struct FrameConnectionTests {
    /// The agent sends `exited` and closes the connection while the client may still be
    /// sending input. A send that meets the close fails with EPIPE, or on macOS with ENOTCONN
    /// when it races the close; both mean that the peer has closed, and the frame it sent
    /// before closing is still read. The race takes many rounds to meet: on macOS, about one
    /// send in eight that races a close fails with ENOTCONN.
    @Test(.timeLimit(.minutes(1)))
    func reportsAPeerThatClosesDuringASendAsClosed() async throws {
        let chunk = [UInt8](repeating: UInt8(ascii: "y"), count: 64)
        // On a thread of its own: each round waits for the peer's frame. Returns what went
        // wrong, if anything; a send that fails otherwise than `closed` ends the rounds.
        let problems = try await runOnDedicatedThread { () throws -> [String] in
            var problems: [String] = []
            for round in 0..<500 {
                let (host, peer) = try HandshakeTests.socketPair()
                let connection = try FrameConnection(host)
                startDetachedThread {
                    guard let agent = try? FrameConnection(peer) else { return }
                    agent.enqueue(.control(.exited(.exited(code: 0))))
                    try? agent.flush(until: .now + .seconds(5))
                    peer.close()
                }
                var failure: ConnectionError?
                while failure == nil {
                    if connection.pendingOutputCount < 4096 {
                        chunk.withUnsafeBytes { connection.enqueueData($0, type: .stdin) }
                    }
                    do throws(ConnectionError) {
                        try connection.flush()
                    } catch {
                        failure = error
                    }
                }
                guard failure == .closed else {
                    return problems + ["round \(round): the send failed with \(failure!)"]
                }
                connection.discardPendingOutput()
                let received = Result { () throws(ConnectionError) in
                    try connection.receiveControl(until: .now + .seconds(5), expecting: "exited")
                }
                if (try? received.get()) != .exited(.exited(code: 0)) {
                    problems.append("round \(round): received \(received)")
                }
            }
            return problems
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    /// On macOS, SIGPIPE cannot be suppressed on a socket whose peer has already closed:
    /// `SO_NOSIGPIPE` and `F_SETNOSIGPIPE` fail with EINVAL. A connection made from such a
    /// socket reports `closed` instead of writing, which would raise SIGPIPE, and still reads
    /// what the peer sent before it closed. In a process of its own that does not ignore
    /// SIGPIPE, as an app does not, so that a write ends that process instead of the test run.
    @Test func neitherWritesNorRaisesSIGPIPEWhenThePeerClosedFirst() async {
        await #expect(processExitsWith: .success) {
            signal(SIGPIPE, SIG_DFL)
            // `socketpair`, not `maw_socketpair`, which suppresses SIGPIPE while both ends are
            // open.
            var fds: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { exit(10) }
            let peer = try FrameConnection(OwnedDescriptor(fds[1]))
            peer.enqueue(.control(.exited(.exited(code: 0))))
            try peer.flush(until: .now + .seconds(5))
            peer.descriptor.close()

            let connection = try FrameConnection(OwnedDescriptor(fds[0]))
            connection.enqueue(.version())
            do throws(ConnectionError) {
                try connection.flush()
                exit(11)
            } catch .closed {
            } catch {
                exit(12)
            }
            let message = try connection.receiveControl(
                until: .now + .seconds(5), expecting: "exited")
            guard message == .exited(.exited(code: 0)) else { exit(13) }
        }
    }
}
