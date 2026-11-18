import CMawSystem
import MawAgentKit
import MawCore
import MawProtocol
import Testing

/// The deadline of each step of a scripted side on a thread of its own, and the agent's and its
/// client's timeouts in `TestAgent`. It is only a bound, so that a side whose counterpart stops
/// leaves no thread behind; it is longer than any stall of the cooperative pool, during which
/// its clock runs on while the side under test, which needs the pool, cannot answer
/// (docs/known-limitations.md).
let peerDeadline = Duration.seconds(60)

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

    /// `dialBack` opens the connection that a `dialBack` request asks for; by default the
    /// dial fails, as it does without a host. `processDirectory` stands in for `/proc`, which
    /// macOS does not have.
    init(
        maximumConnections: Int = 64, system: GuestSystem = .testing(),
        processDirectory: String = "/nonexistent/proc",
        dialBack: @escaping @Sendable () throws(DialBackError) -> OwnedDescriptor = {
            () throws(DialBackError) -> OwnedDescriptor in
            throw .connectFailed(SystemError("connect", code: ECONNREFUSED))
        }
    ) {
        let requests = powerOffRequests
        server = AgentServer(
            configuration: AgentConfiguration(
                maximumConnections: maximumConnections, requestTimeout: peerDeadline,
                system: system, dialBack: dialBack, processDirectory: processDirectory
            ) {
                requests.increment()
            })
    }

    var client: GuestAgentClient {
        GuestAgentClient(replyTimeout: peerDeadline) { [self] () throws(MawError) in
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
    ///
    /// Without `timeout`, it waits for at most 500 sleeps of 20 ms, counted instead of read from
    /// a clock: a stall of the cooperative pool delays the sleeps as much as the output, so it
    /// cannot use the wait up (docs/known-limitations.md). With `timeout`, it waits for that much
    /// real time, for the tests of the latency group, which assert it and run one at a time.
    func waitForOutput(containing text: String, timeout: Duration? = nil) async -> Bool {
        if let timeout {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if standardOutput.contains(text) {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return standardOutput.contains(text)
        }
        for _ in 0..<500 {
            if standardOutput.contains(text) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return standardOutput.contains(text)
    }
}

/// An output handler that blocks until `release()`, as a write to a standard output that
/// nobody reads does, and discards what it receives.
final class UnreadOutput: @unchecked Sendable {
    private let lock = ConditionLock()
    private var entered = false
    private var released = false

    var handler: GuestAgentClient.OutputHandler {
        { [self] _, _ in
            lock.withLock {
                entered = true
                while !released {
                    lock.wait()
                }
            }
        }
    }

    /// Waits until the handler has received output and blocked, for at most 1,000 sleeps of
    /// 10 ms, counted instead of read from a clock (`TestAgent.waitForOutput`). Returns whether
    /// it did.
    func waitUntilBlocked() async -> Bool {
        for _ in 0..<1_000 {
            if lock.withLock({ entered }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return lock.withLock { entered }
    }

    func release() {
        lock.withLock {
            released = true
            lock.broadcast()
        }
    }
}

/// Writes lines of `y` to a process's standard input on a thread of its own, as `yes` does,
/// until the process ends.
final class InputFlood: @unchecked Sendable {
    private let lock = ConditionLock()
    private var written = 0

    init(_ process: GuestProcess) {
        startDetachedThread { [self] in
            let chunk = [UInt8](repeating: 0, count: 32 << 10).enumerated().map {
                $0.offset % 2 == 0 ? UInt8(ascii: "y") : UInt8(ascii: "\n")
            }
            while process.write(chunk) {
                lock.withLock { written += chunk.count }
            }
        }
    }

    /// Waits until the writer has been blocked for 300 ms, and returns the bytes it queued.
    func waitUntilBlocked() async -> Int {
        var last = -1
        while true {
            let current = lock.withLock { written }
            if current == last {
                return current
            }
            last = current
            try? await Task.sleep(for: .milliseconds(300))
        }
    }
}

/// The process's exit status, or `nil` if it has not ended within `timeout`. A task group
/// would wait for `waitForExit`, which does not end on cancellation.
func exitStatus(of process: GuestProcess, within timeout: Duration) async
    -> MawProtocol.ExitStatus?
{
    let settled = OnceFlag()
    return await withCheckedContinuation { continuation in
        Task.detached {
            let status = try? await process.waitForExit()
            if settled.set() { continuation.resume(returning: status) }
        }
        Task.detached {
            try? await Task.sleep(for: timeout)
            if settled.set() { continuation.resume(returning: nil) }
        }
    }
}

/// True for the first caller of `set` only.
final class OnceFlag: @unchecked Sendable {
    private let lock = ConditionLock()
    private var isSet = false

    func set() -> Bool {
        lock.withLock {
            defer { isSet = true }
            return !isSet
        }
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

extension GuestSystem {
    /// A guest whose files are `files`, by path. By default its only account is root, which is
    /// the user running the tests, so that sessions need no switch of identity; its home is
    /// /tmp.
    static func testing(
        files: [String: String] = [:], directories: Set<String> = ["/tmp"],
        executables: Set<String> = [], locales: [String] = ["C.utf8"],
        initSystem: InitSystem = .busybox
    ) -> GuestSystem {
        let uid = getuid()
        let gid = getgid()
        var files = files
        if files["/etc/passwd"] == nil {
            files["/etc/passwd"] = "root:x:\(uid):\(gid):root:/tmp:/bin/sh\n"
        }
        if files["/etc/group"] == nil {
            files["/etc/group"] = "root:x:\(gid):\n"
        }
        let fixedFiles = files
        return GuestSystem(
            readFile: { fixedFiles[$0] },
            isDirectory: { directories.contains($0) },
            isExecutable: { executables.contains($0) },
            exists: { fixedFiles[$0] != nil || directories.contains($0) },
            availableLocales: { locales },
            initSystem: { initSystem },
            currentUserID: UInt32(uid))
    }
}
