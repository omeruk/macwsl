import CMawSystem
import MawAgentKit
import MawCore
import MawProtocol
import Testing

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The agent's server code, reached by the agent client through socket pairs: everything but
/// the vsock transport.
final class TestAgent: Sendable {
    let server: AgentServer
    let powerOffRequests = Counter()

    init(maximumConnections: Int = 64) {
        let requests = powerOffRequests
        server = AgentServer(
            configuration: AgentConfiguration(maximumConnections: maximumConnections) {
                requests.increment()
            })
    }

    var client: GuestAgentClient {
        GuestAgentClient(replyTimeout: .seconds(10)) { [self] () throws(MawError) in
            try connect()
        }
    }

    /// Opens a connection that the server serves on a thread of its own.
    func connect() throws(MawError) -> OwnedDescriptor {
        var fds: [Int32] = [-1, -1]
        let error = maw_socketpair(&fds)
        guard error == 0 else {
            throw .guestAgentUnavailable(reason: "socketpair failed with errno \(error)")
        }
        server.serveOnNewThread(OwnedDescriptor(fds[1]))
        return OwnedDescriptor(fds[0])
    }
}

/// Output from a guest process, kept per stream.
final class Output: @unchecked Sendable {
    private let lock = ConditionLock()
    private var stdout: [UInt8] = []
    private var stderr: [UInt8] = []

    var handler: GuestAgentClient.OutputHandler {
        { [self] stream, bytes in
            lock.withLock {
                switch stream {
                case .stdout: stdout.append(contentsOf: bytes)
                case .stderr: stderr.append(contentsOf: bytes)
                }
            }
        }
    }

    var standardOutput: String { lock.withLock { String(decoding: stdout, as: UTF8.self) } }
    var standardError: String { lock.withLock { String(decoding: stderr, as: UTF8.self) } }
    var standardOutputBytes: [UInt8] { lock.withLock { stdout } }

    /// Waits until standard output contains `text`. Returns whether it did.
    func waitForOutput(containing text: String, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if standardOutput.contains(text) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return standardOutput.contains(text)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = ConditionLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int { lock.withLock { count } }
}
