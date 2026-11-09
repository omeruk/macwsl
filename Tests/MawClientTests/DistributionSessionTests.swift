import Darwin
import Foundation
import MawClient
import MawCore
import MawProtocol
import MawXPC
import Testing

/// `DistributionSession` against a scripted daemon on an anonymous XPC listener, which hands
/// out one end of a socket pair for each session, and a scripted agent on the other end.
@Suite struct DistributionSessionTests {
    static let ubuntu = try! DistroName("Ubuntu-24.04")
    static let size = TerminalSize(rows: 24, columns: 80)

    // MARK: Opening

    @Test func opensALoginShellWithTheTerminalsEnvironment() async throws {
        let daemon = ScriptedDaemon()
        let agent = ScriptedAgent(daemon: daemon)
        let session = Self.session(daemon, locale: "tr_TR.UTF-8", programVersion: "1.2.3")
        defer { session.hangUp() }

        let started = try #require(await session.open())
        #expect(started.info.machine == .distribution(Self.ubuntu))
        #expect(started.processID == 7)
        #expect(daemon.requestedMachines == [nil], "nil asks for the default distribution")
        let request = try #require(agent.execRequest)
        #expect(request.program == .loginShell)
        #expect(request.user == nil)
        #expect(request.locale == "tr_TR.UTF-8")
        #expect(request.terminal == Self.size)
        #expect(
            request.environment == [
                "TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "maw",
                "TERM_PROGRAM_VERSION": "1.2.3",
            ])
        #expect(session.ending == nil)
    }

    @Test func opensANamedDistribution() async throws {
        let daemon = ScriptedDaemon()
        _ = ScriptedAgent(daemon: daemon)
        let session = Self.session(daemon, distribution: try DistroName("Debian-13"))
        defer { session.hangUp() }
        _ = try #require(await session.open())
        #expect(daemon.requestedMachines == [.distribution(try DistroName("Debian-13"))])
    }

    @Test func deliversOutputWithATitleUnchanged() async throws {
        let daemon = ScriptedDaemon()
        _ = ScriptedAgent(daemon: daemon, greeting: "\u{1B}]0;user@ubuntu: ~\u{07}user@ubuntu:~$ ")
        let output = SessionOutput()
        let session = Self.session(daemon, output: output)
        defer { session.hangUp() }
        _ = try #require(await session.open())
        #expect(await output.eventually { $0 == "\u{1B}]0;user@ubuntu: ~\u{07}user@ubuntu:~$ " })
    }

    // MARK: While open

    @Test func sendsInputThatTheShellEchoes() async throws {
        let daemon = ScriptedDaemon()
        let agent = ScriptedAgent(daemon: daemon)
        let output = SessionOutput()
        let session = Self.session(daemon, output: output)
        defer { session.hangUp() }
        _ = try #require(await session.open())

        session.send(Array("echo ü\r".utf8))
        #expect(await output.eventually { $0.hasSuffix("echo ü\r") })
        #expect(agent.input == Array("echo ü\r".utf8))
    }

    @Test func resizesTheGuestsTerminal() async throws {
        let daemon = ScriptedDaemon()
        let agent = ScriptedAgent(daemon: daemon)
        let session = Self.session(daemon)
        defer { session.hangUp() }
        _ = try #require(await session.open())

        session.resize(TerminalSize(rows: 40, columns: 132))
        #expect(await eventually { agent.resizes == [TerminalSize(rows: 40, columns: 132)] })
    }

    /// A resize and input that arrive while the shell starts reach it once it has started.
    @Test func keepsAResizeAndInputFromWhileTheShellStarts() async throws {
        let daemon = ScriptedDaemon()
        let agent = ScriptedAgent(daemon: daemon, holdsStart: true)
        let session = Self.session(daemon)
        defer { session.hangUp() }
        let opening = Task { await session.open() }
        try #require(await eventually { agent.execRequest != nil })

        session.resize(TerminalSize(rows: 50, columns: 100))
        session.send(Array("early".utf8))
        agent.releaseStart()
        _ = try #require(await opening.value)
        #expect(agent.execRequest?.terminal == Self.size)
        #expect(await eventually { agent.resizes == [TerminalSize(rows: 50, columns: 100)] })
        #expect(await eventually { agent.input == Array("early".utf8) })
    }

    @Test func reportsTheForegroundProgram() async throws {
        let daemon = ScriptedDaemon()
        _ = ScriptedAgent(
            daemon: daemon, foreground: .answer(ForegroundProcess(processGroup: 42, name: "sleep")))
        let session = Self.session(daemon)
        defer { session.hangUp() }
        #expect(await session.foregroundProgram(within: .seconds(10)) == .none, "before opening")
        _ = try #require(await session.open())

        #expect(
            await session.foregroundProgram(within: .seconds(10))
                == .program(processGroup: 42, name: "sleep"))
        session.hangUp()
        #expect(await session.foregroundProgram(within: .seconds(10)) == .none, "after the end")
    }

    @Test func reportsNoAnswerWhenTheAgentDoesNotAnswerInTime() async throws {
        let daemon = ScriptedDaemon()
        _ = ScriptedAgent(daemon: daemon, foreground: .ignore)
        let session = Self.session(daemon)
        defer { session.hangUp() }
        _ = try #require(await session.open())
        #expect(await session.foregroundProgram(within: .milliseconds(200)) == .noAnswer)
        #expect(session.ending == nil)
    }

    // MARK: Every way a session ends, each of which releases the lease

    @Test func endsWithTheShellsExitStatus() async throws {
        let daemon = ScriptedDaemon()
        let agent = ScriptedAgent(daemon: daemon)
        let output = SessionOutput()
        let session = Self.session(daemon, output: output)
        _ = try #require(await session.open())

        session.send(Array("exit 3\r".utf8))
        #expect(await session.waitForEnding() == .exited(.exited(code: 3)))
        #expect(output.text.hasSuffix("exit 3\r"), "the output arrives before the ending")
        #expect(await eventually { daemon.closedConnections == 1 }, "the lease is released")
        #expect(await eventually { agent.sawTheClose })
    }

    @Test func endsBecauseTheMachineStopped() async throws {
        let daemon = ScriptedDaemon()
        let agent = ScriptedAgent(daemon: daemon)
        let session = Self.session(daemon)
        _ = try #require(await session.open())

        daemon.endSessions(reason: "maw --terminate was run")
        #expect(
            await session.waitForEnding()
                == .failed(
                    .machineStopped(machine: "Ubuntu-24.04", reason: "maw --terminate was run")))
        #expect(await eventually { daemon.closedConnections == 1 }, "the lease is released")
        #expect(await eventually { agent.sawTheClose }, "the shell is hung up")
    }

    /// While the output handler blocks, the lease is released at once, and the ending is
    /// reported after the output before it.
    @Test func releasesTheLeaseWhileTheOutputHandlerBlocks() async throws {
        let daemon = ScriptedDaemon()
        _ = ScriptedAgent(daemon: daemon, greeting: "$ ")
        let gate = Gate()
        let output = SessionOutput()
        let session = DistributionSession(
            distribution: nil, terminal: Self.size, connect: daemon.connector,
            output: { stream, bytes in
                gate.wait()
                output.handler(stream, bytes)
            })
        _ = try #require(await session.open())

        daemon.endSessions(reason: "maw --terminate was run")
        #expect(await eventually { daemon.closedConnections == 1 }, "the lease is released")
        #expect(session.ending == nil)
        gate.open()
        #expect(
            await session.waitForEnding()
                == .failed(
                    .machineStopped(machine: "Ubuntu-24.04", reason: "maw --terminate was run")))
        #expect(output.text == "$ ")
    }

    @Test func endsWhenTheGuestConnectionEnds() async throws {
        let daemon = ScriptedDaemon()
        _ = ScriptedAgent(daemon: daemon)
        let session = Self.session(daemon)
        _ = try #require(await session.open())

        session.send(Array("drop\r".utf8))
        #expect(
            await session.waitForEnding()
                == .failed(.sessionConnectionEnded(distribution: "Ubuntu-24.04")))
        #expect(await eventually { daemon.closedConnections == 1 }, "the lease is released")
    }

    @Test func endsWhenTheDaemonGoesAway() async throws {
        let daemon = ScriptedDaemon()
        let agent = ScriptedAgent(daemon: daemon)
        let session = Self.session(daemon)
        _ = try #require(await session.open())

        daemon.dropConnections()
        #expect(
            await session.waitForEnding()
                == .failed(.daemonConnectionLost(during: "the session on Ubuntu-24.04")))
        #expect(await eventually { agent.sawTheClose }, "the shell is hung up")
    }

    @Test func endsAsClosedByTheUserOnHangUp() async throws {
        let daemon = ScriptedDaemon()
        let agent = ScriptedAgent(daemon: daemon)
        let session = Self.session(daemon)
        _ = try #require(await session.open())

        session.hangUp()
        #expect(await session.waitForEnding() == .hungUp)
        #expect(await eventually { daemon.closedConnections == 1 }, "the lease is released")
        #expect(await eventually { agent.sawTheClose }, "the shell is hung up")
        session.send(Array("ignored".utf8))
        session.hangUp()
        #expect(session.ending == .hungUp)
    }

    @Test func endsAsClosedByTheUserOnHangUpWhileTheDaemonOpensTheSession() async throws {
        let daemon = ScriptedDaemon(opening: .hold)
        let session = Self.session(daemon)
        let opening = Task { await session.open() }
        try #require(await eventually { daemon.requestedMachines.count == 1 })

        session.hangUp()
        #expect(await session.waitForEnding() == .hungUp)
        #expect(await opening.value == nil)
        #expect(await eventually { daemon.closedConnections == 1 }, "the lease is released")
    }

    @Test func endsAsClosedByTheUserOnHangUpWhileTheShellStarts() async throws {
        let daemon = ScriptedDaemon()
        let agent = ScriptedAgent(daemon: daemon, holdsStart: true)
        let session = Self.session(daemon)
        let opening = Task { await session.open() }
        try #require(await eventually { agent.execRequest != nil })

        session.hangUp()
        #expect(await session.waitForEnding() == .hungUp)
        #expect(await eventually { daemon.closedConnections == 1 }, "the lease is released")
        agent.releaseStart()
        #expect(await opening.value == nil)
        #expect(await eventually { agent.sawTheClose }, "the shell that started is hung up")
    }

    @Test func endsAsClosedByTheUserOnHangUpBeforeOpening() async {
        let daemon = ScriptedDaemon()
        let session = Self.session(daemon)
        session.hangUp()
        #expect(await session.open() == nil)
        #expect(session.ending == .hungUp)
        #expect(daemon.requestedMachines.isEmpty)
    }

    @Test func endsWithTheDaemonsErrorWhenTheSessionCannotOpen() async throws {
        let daemon = ScriptedDaemon(opening: .fail(.noDistributionInstalled))
        let session = Self.session(daemon)
        #expect(await session.open() == nil)
        #expect(session.ending == .failed(.noDistributionInstalled))
        #expect(await eventually { daemon.closedConnections == 1 }, "the lease is released")
    }

    @Test func endsWithTheErrorOfConnecting() async {
        let session = DistributionSession(
            distribution: nil, terminal: Self.size,
            connect: { () async throws(MawError) -> DaemonClient in
                throw .daemonNotInstalled(label: "dev.maw.mawd")
            },
            output: { _, _ in })
        #expect(await session.open() == nil)
        #expect(
            await session.waitForEnding() == .failed(.daemonNotInstalled(label: "dev.maw.mawd")))
    }

    @Test func asksForTheMacsLanguageAndRegion() {
        #expect(
            DistributionSession.preferredLocale(Locale(identifier: "tr_TR")) == "tr_TR.UTF-8")
        #expect(DistributionSession.preferredLocale(Locale(identifier: "tr")) == nil)
    }

    // MARK: Helpers

    static func session(
        _ daemon: ScriptedDaemon, distribution: DistroName? = nil, locale: String? = nil,
        programVersion: String? = nil, output: SessionOutput = SessionOutput()
    ) -> DistributionSession {
        DistributionSession(
            distribution: distribution, terminal: size, locale: locale,
            programVersion: programVersion, connect: daemon.connector,
            output: output.handler)
    }
}

/// The descriptor of a session that the daemon hands over.
@Suite struct SessionDescriptorTests {
    @Test func isClosedOnExec() async throws {
        let daemon = ScriptedDaemon()
        let client = try await daemon.connector()
        defer { client.close() }
        let session = try await client.openSession(on: nil)
        #expect(fcntl(session.agentConnection.rawValue, F_GETFD) & FD_CLOEXEC != 0)
    }

    /// A program that starts after a session has opened, without being given the session's
    /// descriptor, cannot write to it. The program starts as SwiftTerm starts a local shell:
    /// it inherits every descriptor that is not closed on exec. A duplicate without the flag is
    /// the control that shows that the program could write to an inherited one.
    @Test func isNotInheritedByAProgramStartedAfterIt() async throws {
        let daemon = ScriptedDaemon()
        let agentSides = daemon.agentSides
        let client = try await daemon.connector()
        defer { client.close() }
        let session = try await client.openSession(on: nil)
        let agentSide = try #require(await agentSides.first { _ in true })
        _ = fcntl(agentSide.rawValue, F_SETFL, fcntl(agentSide.rawValue, F_GETFL) | O_NONBLOCK)

        // The shell's status is not checked: before a builtin runs with a redirection, bash
        // saves the descriptor it redirects at the lowest free number from 10, which can be
        // the session's number in the child. Only what reaches the session counts.
        let descriptor = session.agentConnection.rawValue
        _ = try Self.runShell("exec >/dev/null 2>&1; printf x >&\(descriptor)")
        var byte: UInt8 = 0
        #expect(read(agentSide.rawValue, &byte, 1) == -1 && errno == EAGAIN)

        let inheritable = dup(descriptor)
        defer { close(inheritable) }
        try #require(try Self.runShell("printf y >&\(inheritable)") == 0)
        #expect(read(agentSide.rawValue, &byte, 1) == 1 && byte == UInt8(ascii: "y"))
    }

    /// Runs `command` with `/bin/sh` through `posix_spawn` without
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT`, and returns its wait status.
    static func runShell(_ command: String) throws -> Int32 {
        let argv = ["/bin/sh", "-c", command].map { strdup($0) } + [nil]
        defer {
            for argument in argv { free(argument) }
        }
        var pid: pid_t = 0
        try #require(posix_spawn(&pid, "/bin/sh", nil, nil, argv, environ) == 0)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return status
    }
}

// MARK: - The scripted daemon and agent

/// Plays the daemon on an anonymous listener. It answers `hello`, answers `openSession` as
/// `opening` says, with one end of a new socket pair, hands the other end to `agentSides`, and
/// counts the connections that its clients close.
final class ScriptedDaemon: @unchecked Sendable {
    enum Opening: Sendable {
        case open
        case fail(MawError)
        /// Keeps the request without answering it. (libxpc fails a request whose message is
        /// released without a reply.)
        case hold
    }

    let listener = XPCServiceListener.anonymous()
    let agentSides: AsyncStream<OwnedDescriptor>
    private let agentSidesContinuation: AsyncStream<OwnedDescriptor>.Continuation
    private let lock = NSLock()
    private var peers: [XPCConnection] = []
    private var closed = 0
    private var machines: [MachineID?] = []
    private var heldRequests: [XPCObject] = []
    private var task: Task<Void, Never>?

    init(opening: Opening = .open) {
        (agentSides, agentSidesContinuation) = AsyncStream.makeStream(of: OwnedDescriptor.self)
        task = Task { [self, listener] in
            await withTaskGroup(of: Void.self) { group in
                for await peer in listener.peers {
                    lock.withLock { peers.append(peer) }
                    group.addTask { await self.serve(peer, opening: opening) }
                }
            }
        }
        listener.activate()
    }

    deinit {
        listener.cancel()
        task?.cancel()
        agentSidesContinuation.finish()
    }

    var connector: DistributionSession.Connector {
        { [listener] () async throws(MawError) -> DaemonClient in
            try await DaemonClient.connect(
                over: XPCConnection(endpoint: listener.endpoint), label: "test")
        }
    }

    var closedConnections: Int { lock.withLock { closed } }
    var requestedMachines: [MachineID?] { lock.withLock { machines } }

    /// Reports to every client that the session's machine stopped.
    func endSessions(reason: String) {
        let event = DaemonEvent.sessionEnded(
            SessionEnded(
                sessionID: 1, machine: .distribution(DistributionSessionTests.ubuntu),
                reason: reason))
        for peer in lock.withLock({ peers }) {
            if let message = try? InterfaceCoding.encode(event) {
                peer.send(message)
            }
        }
    }

    /// Closes every client's connection, as a daemon that exits does.
    func dropConnections() {
        for peer in lock.withLock({ peers }) {
            peer.cancel()
        }
    }

    private func serve(_ peer: XPCConnection, opening: Opening) async {
        for await event in peer.events {
            guard case .message(let message) = event else {
                lock.withLock { closed += 1 }
                continue
            }
            guard
                let request = try? InterfaceCoding.decode(
                    DaemonRequest.self, from: message, as: .daemon)
            else { continue }
            switch request {
            case .hello:
                reply(
                    to: message, on: peer,
                    .welcome(
                        DaemonInfo(
                            version: MawVersion.current, processID: getpid(),
                            interfaceVersion: DaemonInterface.version)))
            case .openSession(let machine):
                lock.withLock { machines.append(machine) }
                let info = SessionInfo(
                    sessionID: 1, machine: machine ?? .distribution(DistributionSessionTests.ubuntu)
                )
                switch opening {
                case .open:
                    var fds: [Int32] = [-1, -1]
                    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { continue }
                    reply(to: message, on: peer, .sessionOpened(info), descriptor: fds[0])
                    close(fds[0])
                    agentSidesContinuation.yield(OwnedDescriptor(fds[1]))
                case .fail(let error):
                    reply(to: message, on: peer, .failure(error))
                case .hold:
                    lock.withLock { heldRequests.append(message) }
                }
            default:
                reply(
                    to: message, on: peer, .failure(.notImplemented(feature: "a test", phase: "")))
            }
        }
    }

    private func reply(
        to message: XPCObject, on peer: XPCConnection, _ reply: DaemonReply,
        descriptor: Int32? = nil
    ) {
        if let encoded = try? InterfaceCoding.encodeReply(
            to: message, reply, descriptor: descriptor)
        {
            peer.send(encoded)
        }
    }
}

/// Plays the agent on the agent's side of each session that a `ScriptedDaemon` opens: it
/// answers `exec` with `started` and the greeting, echoes input, records resizes, and answers
/// foreground queries as told. A line `exit <code>` ends the shell with that code, and a line
/// `drop` closes the connection without an exit status.
final class ScriptedAgent: @unchecked Sendable {
    enum Foreground {
        case answer(ForegroundProcess?)
        case ignore
    }

    private let lock = ConditionLock()
    private var request: ExecRequest?
    private var received: [UInt8] = []
    private var sizes: [TerminalSize] = []
    private var closed = false
    private var startIsHeld: Bool

    init(
        daemon: ScriptedDaemon, greeting: String = "", foreground: Foreground = .answer(nil),
        holdsStart: Bool = false
    ) {
        startIsHeld = holdsStart
        let sides = daemon.agentSides
        Task { [self] in
            for await side in sides {
                startDetachedThread { [self] in
                    serve(side, greeting: Array(greeting.utf8), foreground: foreground)
                }
            }
        }
    }

    var execRequest: ExecRequest? { lock.withLock { request } }
    var input: [UInt8] { lock.withLock { received } }
    var resizes: [TerminalSize] { lock.withLock { sizes } }
    var sawTheClose: Bool { lock.withLock { closed } }

    func releaseStart() {
        lock.withLock {
            startIsHeld = false
            lock.broadcast()
        }
    }

    private func serve(_ side: OwnedDescriptor, greeting: [UInt8], foreground: Foreground) {
        defer { lock.withLock { closed = true } }
        guard let connection = try? FrameConnection(side),
            (try? connection.exchangeVersions(until: .now + .seconds(5))) != nil,
            case .exec(let request) = try? connection.receiveControl(
                until: .now + .seconds(5), expecting: "exec")
        else { return }
        lock.withLock {
            self.request = request
            while startIsHeld {
                lock.wait()
            }
        }
        connection.enqueue(.control(.started(pid: 7)))
        if !greeting.isEmpty {
            connection.enqueue(Frame(type: .stdout, payload: greeting))
        }
        var line: [UInt8] = []
        while (try? connection.flush(until: .now + .seconds(5))) != nil,
            let frame = try? connection.receiveFrame(until: .now + .seconds(60))
        {
            switch frame.type {
            case .stdin:
                lock.withLock { received += frame.payload }
                connection.enqueue(.stdinConsumed(UInt32(frame.payload.count)))
                connection.enqueue(Frame(type: .stdout, payload: frame.payload))
                line += frame.payload
                while let end = line.firstIndex(of: 0x0D) {
                    let command = String(decoding: line[..<end], as: UTF8.self)
                    line.removeFirst(end + 1)
                    if command == "drop" {
                        try? connection.flush(until: .now + .seconds(5))
                        return
                    }
                    if command.hasPrefix("exit "), let code = Int32(command.dropFirst(5)) {
                        connection.enqueue(.control(.exited(.exited(code: code))))
                        try? connection.flush(until: .now + .seconds(5))
                        // As the agent does after `exited`: waits for the host to close.
                        while (try? connection.receiveFrame(until: .now + .seconds(60))) != nil {}
                        return
                    }
                }
            case .control:
                switch try? frame.controlMessage() {
                case .resize(let size):
                    lock.withLock { sizes.append(size) }
                case .foregroundQuery(let id):
                    if case .answer(let program) = foreground {
                        connection.enqueue(.control(.foregroundProgram(id: id, program: program)))
                    }
                default:
                    break
                }
            default:
                break
            }
        }
    }
}

/// Output collected from the output handler's thread.
final class SessionOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var handler: GuestAgentClient.OutputHandler {
        { [self] _, data in lock.withLock { bytes += data } }
    }

    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }

    /// Whether the output satisfies `condition` within 10 seconds.
    func eventually(_ condition: @escaping (String) -> Bool) async -> Bool {
        await MawClientTests.eventually { condition(self.text) }
    }
}

/// Whether `condition` holds within 10 seconds. The limit only keeps a broken test from
/// waiting for ever.
func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Blocks callers of `wait()` until `open()`.
final class Gate: @unchecked Sendable {
    private let lock = ConditionLock()
    private var isOpen = false

    func wait() {
        lock.withLock {
            while !isOpen {
                lock.wait()
            }
        }
    }

    func open() {
        lock.withLock {
            isOpen = true
            lock.broadcast()
        }
    }
}
