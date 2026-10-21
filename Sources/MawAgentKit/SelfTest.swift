import CMawSystem
import MawCore
import MawProtocol

/// The agent's self-test, run by `/init` with `maw.test=agent` (the QEMU smoke test).
///
/// QEMU on the CI runner has no vsock, so the test connects the agent client to the agent's
/// session code through a `socketpair`. It exercises everything but the transport: the
/// handshake, `info`, pipe mode with `true`, and terminal mode with `tty`.
public enum SelfTest {
    /// Runs the checks. Returns a description of each failure; empty means success.
    public static func run() async -> [String] {
        let server = AgentServer(configuration: AgentConfiguration(powerOff: {}))
        let client = GuestAgentClient { () throws(MawError) -> OwnedDescriptor in
            var fds: [Int32] = [-1, -1]
            let error = maw_socketpair(&fds)
            guard error == 0 else {
                throw .guestAgentUnavailable(
                    reason: SystemError("socketpair", code: error).description)
            }
            server.serveOnNewThread(OwnedDescriptor(fds[1]))
            return OwnedDescriptor(fds[0])
        }

        var failures: [String] = []
        do {
            let info = try await client.info()
            if info.protocolVersion != ProtocolVersion.current {
                failures.append("info reports protocol version \(info.protocolVersion)")
            }
        } catch {
            failures.append("info: \(error)")
        }

        do {
            let process = try await client.exec(ExecRequest(argv: ["true"])) { _, _ in }
            process.closeInput()
            let status = try await process.waitForExit()
            if status != .exited(code: 0) {
                failures.append("true in pipe mode \(status)")
            }
        } catch {
            failures.append("true in pipe mode: \(error)")
        }

        do {
            let output = OutputCollector()
            let process = try await client.exec(
                ExecRequest(argv: ["tty"], terminal: TerminalSize(rows: 24, columns: 80))
            ) { _, bytes in
                output.append(bytes)
            }
            let status = try await process.waitForExit()
            let text = output.text
            if status != .exited(code: 0) {
                failures.append("tty in terminal mode \(status); output: \(text)")
            } else if !text.hasPrefix("/dev/") {
                failures.append("tty in terminal mode printed '\(text)'")
            }
        } catch {
            failures.append("tty in terminal mode: \(error)")
        }
        return failures
    }
}

/// Collects output from the client's I/O thread.
final class OutputCollector: @unchecked Sendable {
    private let lock = ConditionLock()
    private var bytes: [UInt8] = []

    func append(_ buffer: UnsafeRawBufferPointer) {
        lock.withLock { bytes.append(contentsOf: buffer) }
    }

    var text: String {
        lock.withLock { String(decoding: bytes, as: UTF8.self) }
    }
}
