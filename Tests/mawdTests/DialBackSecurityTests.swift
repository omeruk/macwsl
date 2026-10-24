import Foundation
import MawProtocol
import MawTestSupport
import MawVirtualization
import Testing

/// Guest processes that dial the host's dial-back port themselves (docs/protocol.md). The host
/// refuses a dial from a source port of 1024 or above, which any process can bind, and any dial
/// while no session waits, before reading anything; it closes a dial whose nonce matches no
/// waiting session. Each refusal appears in the machine's console log without a nonce.
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled,
        "Integration tests boot a real virtual machine; run scripts/integration-test.sh."),
    .serialized,
    .timeLimit(.minutes(10))
)
struct DialBackSecurityTests {
    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    var distribution: String { maw.distribution }

    @Test func refusesDialsWithoutTheNonceOfAWaitingSession() async throws {
        // A machine of its own, so that the refusals below are the first that its gate
        // reports, and none is left out by the limit of five reports per ten seconds.
        #expect(try await maw.run(["--shutdown"]).status == 0)
        // In the home directory, which stays when the machine restarts between sessions.
        let script = "/home/\(maw.user)/.maw-test-dial-\(UUID().uuidString).py"
        let installed = try await maw.session(
            ["-e", "sh", "-c", "cat > \"$0\"", script], standardInput: Data(Self.dialer.utf8))
        try #require(installed.status == 0, "\(installed.standardError)")
        let logURL = maw.logDirectory.appending(path: "\(distribution).log")
        let logStart = try Data(contentsOf: logURL).count
        let port = String(AgentProtocol.dialBackPort)

        // A root process dials while a session waits for its connection. The dialer stops the
        // agent, so that the session's request stays unanswered until the dialer has sent its
        // own nonce, and then resumes it.
        let marker = "maw-test-\(UUID().uuidString)"
        let holder = try maw.start([
            "-d", distribution, "-u", "root", "-e", "python3", script, port, "hold", marker,
        ])
        defer { Self.kill(holder) }
        let agentStopped = await maw.eventually(within: .seconds(30)) {
            Self.log(logURL, from: logStart).contains("\(marker): agent stopped")
        }
        try #require(agentStopped, "\(holder.output)\(holder.standardError)")
        let waiting = try maw.start(["-d", distribution, "-e", "echo", "dialed"])
        defer { Self.kill(waiting) }
        let held = await holder.waitForExit(timeout: .seconds(60))
        #expect(held.status == 0, "\(held.output)\(held.standardError)")
        let nonce = try #require(
            held.lines.first { $0.hasPrefix("nonce ") }.map { String($0.dropFirst(6)) },
            "\(held.output)")
        try #require(nonce.count == 2 * AgentProtocol.dialBackNonceSize)
        #expect(
            held.lines.contains { $0.contains(": accepted; closed after the nonce") },
            "\(held.output)")
        // The session that was waiting still gets its own connection.
        let session = await waiting.waitForExit(timeout: .seconds(30))
        #expect(session.status == 0, "\(session.standardError)")
        #expect(session.output == "dialed\n")

        // An unprivileged process can bind no source port below 1024, and the host refuses a
        // dial from any other port.
        let unprivileged = try await maw.session(["-e", "python3", script, port, "unprivileged"])
        #expect(unprivileged.status == 0, "\(unprivileged.standardError)")
        #expect(unprivileged.lines.first != "uid 0", "\(unprivileged.output)")
        #expect(unprivileged.lines.contains("bind 1000: EACCES"), "\(unprivileged.output)")
        let highPort = try #require(
            unprivileged.lines.compactMap { line in
                line.firstMatch(of: /^dial from (\d+): refused/).flatMap { UInt32($0.1) }
            }.first, "\(unprivileged.output)")
        #expect(highPort >= 1024)

        // The host refuses a dial from a privileged port while no session waits.
        let root = try await maw.session([
            "-u", "root", "-e", "python3", script, port, "dial", "1000",
        ])
        #expect(root.status == 0, "\(root.standardError)")
        #expect(
            root.lines.contains { $0.hasPrefix("dial from 1000: refused") }, "\(root.output)")

        let after = try await maw.session(["-e", "echo", "still answering"])
        #expect(after.status == 0, "\(after.standardError)")
        #expect(after.output == "still answering\n")

        let log = Self.log(logURL, from: logStart)
        let refusals = DebugBootProcess.lines(of: log).filter { $0.contains(" dial-back: ") }
        for refusal in [
            DialBackGate.Refusal.unknownNonce, .unprivilegedSourcePort(highPort),
            .noPendingRequest,
        ] {
            #expect(
                refusals.contains { $0.hasSuffix("refused a dial-back connection: \(refusal)") },
                "\(refusals)")
        }
        #expect(!log.lowercased().contains(nonce), "The console log contains the nonce.")
        #expect(!refusals.contains { $0.contains(/[0-9A-Fa-f]{64}/) }, "\(refusals)")

        _ = try await maw.session(["-e", "rm", "-f", script])
    }

    // MARK: Helpers

    /// The console log from byte `start` on.
    static func log(_ url: URL, from start: Int) -> String {
        let data = (try? Data(contentsOf: url)) ?? Data()
        return String(decoding: data.dropFirst(start), as: UTF8.self)
    }

    static func kill(_ session: DebugBootProcess) {
        if session.isRunning {
            session.signal(SIGKILL)
        }
    }

    /// The guest-side dialer, for the guest's python3. It exists only in this test target.
    ///
    /// `python3 dial.py <port> unprivileged` binds port 1000 and dials from a port the kernel
    /// chooses; `dial <source port>` dials from that port; `hold <marker>` stops the agent,
    /// writes `<marker>: agent stopped` to the console, dials from privileged ports until the
    /// host admits a dial, and resumes the agent. Each dial sends a random nonce frame and
    /// prints what the host did.
    static let dialer = #"""
        import errno, os, random, signal, socket, sys, time

        HOST = 2
        PORT = int(sys.argv[1])
        NONCE_SIZE = 32

        def name(error):
            if isinstance(error, socket.timeout):
                return "timed out"
            return errno.errorcode.get(error.errno, str(error.errno))

        def local_port(sock):
            try:
                return sock.getsockname()[1]
            except OSError:
                return -1

        def bind(port):
            sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            try:
                sock.bind((socket.VMADDR_CID_ANY, port))
                return "bind %d: ok" % port
            except OSError as error:
                return "bind %d: %s" % (port, name(error))
            finally:
                sock.close()

        def dial(port, nonce):
            sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            sock.settimeout(5)
            try:
                if port is not None:
                    sock.bind((socket.VMADDR_CID_ANY, port))
                try:
                    sock.connect((HOST, PORT))
                except OSError as error:
                    return "dial from %d: refused (%s)" % (local_port(sock), name(error))
                source = local_port(sock)
                sock.sendall(len(nonce).to_bytes(4, "big") + bytes([4]) + nonce)
                try:
                    data = sock.recv(1)
                except socket.timeout:
                    return "dial from %d: accepted; still open 5 s after the nonce" % source
                except OSError as error:
                    return "dial from %d: accepted; closed after the nonce (%s)" % (
                        source, name(error))
                if data:
                    return "dial from %d: accepted; received data after the nonce" % source
                return "dial from %d: accepted; closed after the nonce" % source
            finally:
                sock.close()

        def agent():
            for entry in os.listdir("/proc"):
                if not entry.isdigit():
                    continue
                try:
                    if os.readlink("/proc/%s/exe" % entry) != "/run/maw/maw-agent":
                        continue
                    with open("/proc/%s/stat" % entry) as stat:
                        parent = int(stat.read().rsplit(")", 1)[1].split()[1])
                except (OSError, ValueError, IndexError):
                    continue
                if parent == 1:
                    return int(entry)
            sys.exit("the agent is not running")

        def hold(marker):
            nonce = os.urandom(NONCE_SIZE)
            pid = agent()
            outcomes = []
            os.kill(pid, signal.SIGSTOP)
            try:
                with open("/dev/console", "w") as console:
                    console.write("%s: agent stopped\n" % marker)
                time.sleep(1)
                deadline = time.monotonic() + 3
                while True:
                    outcomes.append(dial(random.randrange(600, 900), nonce))
                    if ": accepted" in outcomes[-1] or time.monotonic() > deadline:
                        break
                    time.sleep(0.5)
            finally:
                os.kill(pid, signal.SIGCONT)
            print("nonce " + nonce.hex())
            for outcome in outcomes:
                print(outcome)

        mode = sys.argv[2]
        if mode == "unprivileged":
            print("uid %d" % os.getuid())
            print(bind(1000))
            print(dial(None, os.urandom(NONCE_SIZE)))
        elif mode == "dial":
            print(dial(int(sys.argv[3]), os.urandom(NONCE_SIZE)))
        elif mode == "hold":
            hold(sys.argv[3])
        else:
            sys.exit("unknown mode " + mode)
        """#
}
