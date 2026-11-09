import Foundation
import RegexBuilder
import Testing

/// The session core (`DistributionSession` in MawClient), which the terminal app's Linux tabs
/// use, against the test daemon on the test distribution, through the integration probe. The
/// tests use the shared test distribution and change neither the default nor `state.json`.
@Suite(
    .tags(.integration),
    .enabled(
        if: MawIntegration.isEnabled,
        "Integration tests boot a real virtual machine; run scripts/integration-test.sh."),
    .serialized,
    .timeLimit(.minutes(10))
)
struct SessionCoreIntegrationTests {
    let maw: MawIntegration

    init() throws {
        maw = try MawIntegration()
    }

    @Test func showsTheLoginShellsPrompt() async throws {
        let probe = try await started()
        defer { probe.stop() }
        #expect(try await probe.send("close") == "closed hung-up", "\(probe.transcript)")
    }

    @Test func echoesInput() async throws {
        let probe = try await started()
        defer { probe.stop() }
        #expect(try await probe.send(#"send echo maw-$((6*7))\r"#) == "sent 18")
        let echoed = await maw.eventually(within: .seconds(10)) {
            probe.terminal.contains("echo maw-$((6*7))\r\n")
                && probe.terminal.contains("maw-42\r\n")
        }
        #expect(echoed, "\(probe.transcript)")
        #expect(try await probe.send("close") == "closed hung-up", "\(probe.transcript)")
    }

    /// Before a command's output, bash ends bracketed paste mode (`ESC [ ? 2004 l`) and
    /// returns the cursor, so that the output's first line follows a carriage return.
    @Test func resizesTheGuestsTerminal() async throws {
        let probe = try await started()
        defer { probe.stop() }
        #expect(try await probe.send(#"send stty size\r"#) == "sent 10")
        let initial = await maw.eventually(within: .seconds(10)) {
            probe.terminal.contains(Self.line("24 80"))
        }
        #expect(initial, "\(probe.transcript)")

        #expect(try await probe.send("resize 40 132") == "resized")
        #expect(try await probe.send(#"send stty size\r"#) == "sent 10")
        let resized = await maw.eventually(within: .seconds(10)) {
            probe.terminal.contains(Self.line("40 132"))
        }
        #expect(resized, "\(probe.transcript)")
        #expect(try await probe.send("close") == "closed hung-up", "\(probe.transcript)")
    }

    /// Closing hangs up the guest's shell, which exits, and releases the session's lease.
    @Test func closingEndsTheGuestsShell() async throws {
        let probe = try await started()
        defer { probe.stop() }
        #expect(try await probe.send(#"send echo shell-$$\r"#) == "sent 14")
        var shell: Substring?
        let reported = await maw.eventually(within: .seconds(10)) {
            shell =
                probe.terminal.firstMatch(
                    of: /[\r\n]shell-(\d+)\r\n/.matchingSemantics(.unicodeScalar))?.output.1
            return shell != nil
        }
        let pid = try #require(shell, "\(reported) \(probe.transcript)")
        try await maw.waitForSessions(1)

        #expect(try await probe.send("close") == "closed hung-up", "\(probe.transcript)")
        let exited = await probe.process.waitForExit(timeout: .seconds(30))
        #expect(exited.status == 0, "\(probe.transcript)")
        let ended = await maw.eventually(within: .seconds(30)) {
            (try? await maw.session(["-e", "ps", "-p", String(pid)]))?.status == 1
        }
        #expect(ended, "the shell \(pid) still runs in the guest")
        // The lease is released: no session remains, or the idle machine has stopped.
        var row = ""
        let released = await maw.eventually(within: .seconds(30)) {
            row = (try? await maw.machineRow()) ?? "?"
            return row.isEmpty || row.hasSuffix(" 0")
        }
        #expect(released, "\(row)")
    }

    /// A whole line of output: after a line feed, or after the carriage return that follows
    /// bash's escape sequences, and ending in CR LF. It matches Unicode scalars, because a
    /// `String` holds CR LF as one `Character`, which the scalars `\r` and `\n` in a pattern of
    /// the default semantics do not match.
    static func line(_ text: String) -> Regex<Substring> {
        Regex {
            CharacterClass.anyOf("\r\n")
            text
            "\r\n"
        }.matchingSemantics(.unicodeScalar)
    }

    /// A probe whose session has started and shows the prompt of the test user's bash, which
    /// ends with "$ ".
    private func started() async throws -> IntegrationProbe {
        let probe = try IntegrationProbe(maw: maw)
        let started = try #require(await probe.result(1), "\(probe.transcript)")
        try #require(started.hasPrefix("started "), "\(probe.transcript)")
        try #require(
            await maw.eventually(within: .seconds(30)) { probe.terminal.contains("$ ") },
            "\(probe.transcript)")
        return probe
    }
}
