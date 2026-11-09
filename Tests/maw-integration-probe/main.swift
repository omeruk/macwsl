// The integration tests' client of the test daemon. The test runner cannot connect to a daemon
// itself, because the daemon accepts only peers signed as maw's executables, so the tests run
// this probe as a subprocess. Only scripts/integration-test.sh signs it, with the identifier
// dev.maw.maw, and it refuses to run against any daemon but the test daemon.
//
// Usage: maw-integration-probe <distribution>
//
// It opens a session in <distribution> through the daemon and runs the login shell there on a
// pseudo-terminal of 24 rows and 80 columns, then prints `started <pid>` on standard output.
// The session's output goes to standard error, so that it never mixes with the results. Each
// line on standard input is a command, answered with one line on standard output:
//
//   foreground     none | program <process group> [<name>] | no-answer
//   send <text>    sent <bytes>; <text> may contain \\, \n, \r, \t, and \xHH
//   close          closed, after the session has hung up; then the probe exits
//
// The end of standard input closes the session as `close` does. A failure prints
// `failed <message>` and exits with status 1.

#if os(macOS)
    import Foundation
    import MawClient
    import MawCore
    import MawProtocol
    import MawXPC

    /// The only daemon the probe talks to: scripts/integration-test.sh registers it.
    let testDaemonLabel = "dev.maw.mawd.integration-test"

    func respond(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    func fail(_ message: String) -> Never {
        respond("failed \(message)")
        exit(1)
    }

    /// `text` with the escapes of `send` replaced by the bytes they stand for.
    func unescape(_ text: Substring) -> [UInt8]? {
        var bytes: [UInt8] = []
        var input = Array(text.utf8)[...]
        while let byte = input.popFirst() {
            guard byte == UInt8(ascii: "\\") else {
                bytes.append(byte)
                continue
            }
            switch input.popFirst() {
            case UInt8(ascii: "\\"): bytes.append(UInt8(ascii: "\\"))
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "x"):
                guard input.count >= 2,
                    let value = UInt8(String(decoding: input.prefix(2), as: UTF8.self), radix: 16)
                else { return nil }
                bytes.append(value)
                input = input.dropFirst(2)
            default:
                return nil
            }
        }
        return bytes
    }

    func describe(_ answer: ForegroundAnswer) -> String {
        switch answer {
        case .none: "none"
        case .program(let group, let name?): "program \(group) \(name)"
        case .program(let group, nil): "program \(group)"
        case .noAnswer: "no-answer"
        }
    }

    let arguments = CommandLine.arguments.dropFirst()
    guard arguments.count == 1, let distribution = try? DistroName(arguments.first ?? "") else {
        fail("usage: maw-integration-probe <distribution>")
    }
    guard ProcessInfo.processInfo.environment["MAW_DAEMON_LABEL"] == testDaemonLabel else {
        fail("MAW_DAEMON_LABEL must be \(testDaemonLabel); the probe talks only to the test daemon")
    }
    // The session's connection may close before a write; that must not end the probe.
    signal(SIGPIPE, SIG_IGN)

    let client: DaemonClient
    let process: GuestProcess
    do throws(MawError) {
        client = try await DaemonClient.connect(label: testDaemonLabel)
        let session = try await client.openSession(on: .distribution(distribution))
        let request = ExecRequest(
            program: .loginShell, environment: ["TERM": "xterm-256color"],
            terminal: TerminalSize(rows: 24, columns: 80))
        process = try await session.agentClient().exec(request) { _, bytes in
            FileHandle.standardError.write(Data(bytes))
        }
    } catch {
        fail(error.errorDescription ?? error.description)
    }
    respond("started \(process.pid)")

    do {
        commands: for try await line in FileHandle.standardInput.bytes.lines {
            let words = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            switch words.first {
            case "foreground" where words.count == 1:
                respond(describe(await process.foregroundProgram(within: .seconds(5))))
            case "send" where words.count == 2:
                guard let bytes = unescape(words[1]) else {
                    respond("error invalid escape in \(line)")
                    continue commands
                }
                process.write(bytes)
                respond("sent \(bytes.count)")
            case "close" where words.count == 1:
                break commands
            default:
                respond("error unknown command \(line)")
            }
        }
    } catch {
        // Standard input cannot be read; the session closes as at its end.
    }
    process.hangUp()
    _ = try? await process.waitForExit()
    client.close()
    respond("closed")
#endif
