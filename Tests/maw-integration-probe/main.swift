// The integration tests' client of the test daemon. The test runner cannot connect to a daemon
// itself, because the daemon accepts only peers signed as maw's executables or the terminal app,
// so the tests run this probe as a subprocess. Only scripts/integration-test.sh signs it, with
// the identifier dev.maw.maw, and it refuses to run against any daemon but the test daemon.
//
// Usage: maw-integration-probe <distribution>
//        maw-integration-probe --watch
//
// With --watch, it opens no session: it prints `watching <time>` just before it connects, then
// repeats `watchDistributions` and prints each snapshot as `snapshot <time> <JSON>`, where <time> is `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` when the
// snapshot arrived, which the test runner can compare with its own readings. It exits at the end
// of standard input, and prints `failed <message>` and exits with status 1 if a request fails.
//
// It opens a session in <distribution> through the session core (`DistributionSession` in
// MawClient), which the terminal app uses, with a pseudo-terminal of 24 rows and 80 columns,
// then prints `started <pid>` on standard output. The session's output goes to standard error,
// so that it never mixes with the results. Each line on standard input is a command, answered
// with one line on standard output:
//
//   foreground                none | program <process group> [<name>] | no-answer
//   send <text>               sent <bytes>; <text> may contain \\, \n, \r, \t, and \xHH
//   resize <rows> <columns>   resized
//   close                     closed <ending>, once the session has hung up and ended; then the
//                             probe exits. <ending> is hung-up, exited <status>, or
//                             failed <message>.
//
// The measurements of the speed targets take their times inside the probe, around the operation,
// so that the pipes to the test runner add nothing. Times are in milliseconds, with three
// decimals:
//
//   prompt-time               prompt-time <ms> | prompt-time none: from just before the session
//                             opens to the output that first contains "$ ", the end of the test
//                             user's bash prompt; none while it has not arrived
//   foreground-time           foreground-time <ms> <answer>: one foreground request, as
//                             `foreground` answers it
//   echo-time <text>          echo-time <ms> | echo-time none: from sending <text>, with the
//                             escapes of `send`, to the first output that contains its last byte;
//                             none after 5 seconds
//
// The end of standard input closes the session as `close` does. A session that cannot open
// prints `failed <message>` and exits with status 1.

#if os(macOS)
    import Foundation
    import MawClient
    import MawCore
    import MawProtocol

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

    func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return String(format: "%.3f", Double(seconds) * 1e3 + Double(attoseconds) / 1e15)
    }

    /// The times that the measurements take from the session's output.
    final class Timings: @unchecked Sendable {
        private struct Echo {
            var byte: UInt8
            var sent: ContinuousClock.Instant
            var continuation: CheckedContinuation<Duration?, Never>
        }

        private let lock = NSLock()
        private let opened = ContinuousClock.now
        private var previous: UInt8 = 0
        private var prompt: Duration?
        private var echo: Echo?

        var promptTime: Duration? { lock.withLock { prompt } }

        func received(_ bytes: UnsafeRawBufferPointer) {
            let now = ContinuousClock.now
            let echoed: Echo? = lock.withLock {
                for byte in bytes where prompt == nil {
                    if previous == UInt8(ascii: "$") && byte == UInt8(ascii: " ") {
                        prompt = now - opened
                    }
                    previous = byte
                }
                guard let pending = echo, bytes.contains(pending.byte) else { return nil }
                echo = nil
                return pending
            }
            echoed?.continuation.resume(returning: now - (echoed?.sent ?? now))
        }

        /// Sends `bytes` through `send` and waits for an output that contains the last of them.
        func echoTime(of bytes: [UInt8], send: () -> Void) async -> Duration? {
            guard let last = bytes.last else { return nil }
            return await withCheckedContinuation { continuation in
                lock.withLock {
                    echo = Echo(byte: last, sent: ContinuousClock.now, continuation: continuation)
                }
                send()
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    let expired: Echo? = lock.withLock {
                        defer { echo = nil }
                        return echo
                    }
                    expired?.continuation.resume(returning: nil)
                }
            }
        }
    }

    func describe(_ ending: DistributionSession.Ending) -> String {
        switch ending {
        case .hungUp: "hung-up"
        case .exited(let status): "exited \(status)"
        case .failed(let error): "failed \(error.errorDescription ?? error.description)"
        }
    }

    /// `--watch`: prints every snapshot until the end of standard input.
    func watch() async -> Never {
        respond("watching \(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))")
        let client: DaemonClient
        do {
            client = try await DaemonClient.connect(label: testDaemonLabel)
        } catch {
            fail(error.errorDescription ?? error.description)
        }
        Task {
            _ = try? await FileHandle.standardInput.bytes.lines.reduce(0) { count, _ in count + 1 }
            client.close()
            exit(0)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var after: UInt64 = 0
        while true {
            do {
                let snapshot = try await client.watchDistributions(after: after)
                let time = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                after = snapshot.sequence
                respond(
                    "snapshot \(time) \(String(decoding: try encoder.encode(snapshot), as: UTF8.self))"
                )
            } catch {
                fail("\(error)")
            }
        }
    }

    guard ProcessInfo.processInfo.environment["MAW_DAEMON_LABEL"] == testDaemonLabel else {
        fail("MAW_DAEMON_LABEL must be \(testDaemonLabel); the probe talks only to the test daemon")
    }
    let arguments = CommandLine.arguments.dropFirst()
    if arguments == ["--watch"] {
        await watch()
    }
    guard arguments.count == 1, let distribution = try? DistroName(arguments.first ?? "") else {
        fail("usage: maw-integration-probe <distribution> | --watch")
    }
    // The session's connection may close before a write; that must not end the probe.
    signal(SIGPIPE, SIG_IGN)

    let timings = Timings()
    let session = DistributionSession(
        distribution: distribution, terminal: TerminalSize(rows: 24, columns: 80),
        connect: { () async throws(MawError) -> DaemonClient in
            try await DaemonClient.connect(label: testDaemonLabel)
        },
        output: { _, bytes in
            timings.received(bytes)
            FileHandle.standardError.write(Data(bytes))
        })
    guard let started = await session.open() else {
        fail(describe(await session.waitForEnding()))
    }
    respond("started \(started.processID)")

    do {
        commands: for try await line in FileHandle.standardInput.bytes.lines {
            let words = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            switch words.first {
            case "foreground" where words.count == 1:
                respond(describe(await session.foregroundProgram(within: .seconds(5))))
            case "send" where words.count == 2:
                guard let bytes = unescape(words[1]) else {
                    respond("error invalid escape in \(line)")
                    continue commands
                }
                session.send(bytes)
                respond("sent \(bytes.count)")
            case "resize" where words.count == 2:
                let size = words[1].split(separator: " ").compactMap { UInt16($0) }
                guard size.count == 2 else {
                    respond("error invalid size in \(line)")
                    continue commands
                }
                session.resize(TerminalSize(rows: size[0], columns: size[1]))
                respond("resized")
            case "prompt-time" where words.count == 1:
                respond("prompt-time \(timings.promptTime.map(milliseconds) ?? "none")")
            case "foreground-time" where words.count == 1:
                let started = ContinuousClock.now
                let answer = await session.foregroundProgram(within: .seconds(5))
                let elapsed = ContinuousClock.now - started
                respond("foreground-time \(milliseconds(elapsed)) \(describe(answer))")
            case "echo-time" where words.count == 2:
                guard let bytes = unescape(words[1]), !bytes.isEmpty else {
                    respond("error invalid escape in \(line)")
                    continue commands
                }
                let elapsed = await timings.echoTime(of: bytes) { session.send(bytes) }
                respond("echo-time \(elapsed.map(milliseconds) ?? "none")")
            case "close" where words.count == 1:
                break commands
            default:
                respond("error unknown command \(line)")
            }
        }
    } catch {
        // Standard input cannot be read; the session closes as at its end.
    }
    session.hangUp()
    respond("closed \(describe(await session.waitForEnding()))")
#endif
