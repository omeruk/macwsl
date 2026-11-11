import Foundation
import Testing

@testable import MawTerminalKit

/// Runs real processes on a pseudo-terminal. `/bin/sh` stands in for the login shell.
@MainActor
@Suite struct LocalShellSessionTests {
    @MainActor
    final class Recorder: TerminalSessionDelegate {
        var output: [UInt8] = []
        var titles: [String] = []
        var directories: [String] = []
        var status: TerminationStatus?
        var failure: TerminalSessionError?

        var text: String { String(decoding: output, as: UTF8.self) }

        func session(_ session: any TerminalSession, didReceive bytes: ArraySlice<UInt8>) {
            output += bytes
        }

        func session(_ session: any TerminalSession, didChangeTitle title: String) {
            titles.append(title)
        }

        func session(_ session: any TerminalSession, didChangeWorkingDirectory directory: String) {
            directories.append(directory)
        }

        func session(_ session: any TerminalSession, didTerminateWith status: TerminationStatus) {
            self.status = status
        }

        func session(_ session: any TerminalSession, didFailWith error: TerminalSessionError) {
            failure = error
        }

        func session(
            _ session: any TerminalSession, didFallBackTo replacement: any TerminalSession,
            notice: String?
        ) {}

        func session(_ session: any TerminalSession, didNotice notice: String) {}
    }

    func start(_ recorder: Recorder, size: TerminalSize = .default) throws -> LocalShellSession {
        let session = LocalShellSession(shell: "/bin/sh", startDirectory: "/tmp")
        session.delegate = recorder
        try session.start(size: size)
        return session
    }

    @Test func runsCommandsAndReportsTheExitStatus() async throws {
        let recorder = Recorder()
        let session = try start(recorder)
        session.send(ArraySlice("echo maw-$((40 + 2)); exit 3\n".utf8))
        #expect(await waitUntil(seconds: 5) { recorder.status != nil })
        #expect(recorder.text.contains("maw-42"))
        #expect(recorder.status == .exited(3))
        #expect(!session.isRunning)
    }

    @Test func startsInTheGivenDirectoryAsALoginShellWithTheTerminalsIdentity() async throws {
        let recorder = Recorder()
        let session = try start(recorder)
        session.send(ArraySlice(#"echo "[$(pwd -P)|$0|$TERM|$TERM_PROGRAM]"; exit\#n"#.utf8))
        #expect(await waitUntil(seconds: 5) { recorder.status != nil })
        let tmp = canonicalPath("/tmp")
        #expect(recorder.text.contains("[\(tmp)|-sh|xterm-256color|maw]"), "\(recorder.text)")
    }

    @Test func passesTheWindowSize() async throws {
        let recorder = Recorder()
        let session = try start(recorder, size: TerminalSize(columns: 101, rows: 33))
        session.send(ArraySlice("stty size\n".utf8))
        #expect(await waitUntil(seconds: 5) { recorder.text.contains("33 101") })
        session.resize(to: TerminalSize(columns: 120, rows: 40))
        session.send(ArraySlice("stty size; exit\n".utf8))
        #expect(await waitUntil(seconds: 5) { recorder.text.contains("40 120") })
    }

    @Test func reportsAForegroundProcess() async throws {
        let recorder = Recorder()
        let session = try start(recorder)
        #expect(await waitUntil(seconds: 5) { !recorder.output.isEmpty })
        #expect(session.foreground == .none)
        session.send(ArraySlice("sleep 30\n".utf8))
        #expect(await waitUntil(seconds: 5) { session.foreground != .none })
        #expect(session.foreground == .program(name: "sleep"))
        #expect(
            await session.foregroundProgram(within: .milliseconds(500)) == .program(name: "sleep"))
        session.send([0x03])
        #expect(await waitUntil(seconds: 5) { session.foreground == .none })
        #expect(await session.foregroundProgram(within: .milliseconds(500)) == .none)
        session.terminate()
    }

    // MARK: The pseudo-terminal and job control

    /// Waits until the shell has printed its first output, its prompt.
    func waitForOutput(_ recorder: Recorder) async -> Bool {
        await waitUntil(seconds: 5) { !recorder.output.isEmpty }
    }

    /// The shells that the job-control tests run: `/bin/sh`, which is bash, and `/bin/zsh`,
    /// the default login shell on macOS. bash makes its terminal its controlling terminal
    /// itself when it starts and has none, so only zsh shows whether the session gave it one.
    enum Shell: String, CaseIterable, Sendable {
        case sh = "/bin/sh"
        case zsh = "/bin/zsh"
    }

    /// Starts `shell` in /tmp and waits until it is ready for input.
    func start(_ shell: Shell, _ recorder: Recorder) async throws -> LocalShellSession {
        switch shell {
        case .sh:
            let session = try start(recorder)
            #expect(await waitForOutput(recorder))
            return session
        case .zsh:
            let session = try startZsh(recorder, environment: finderLikeEnvironment())
            #expect(await waitForPrompt(recorder), "\(recorder.text)")
            return session
        }
    }

    @Test(arguments: Shell.allCases)
    func theShellsControllingTerminalIsThePseudoTerminal(_ shell: Shell) async throws {
        let recorder = Recorder()
        let session = try await start(shell, recorder)
        // `ps -o tty=` names the controlling terminal, and `??` if there is none.
        // printf builds the markers, so that the terminal's echo of the typed line, which
        // may wrap anywhere, never matches them.
        session.send(
            ArraySlice(#"printf '%s=%s|%s=%s|\n' tty "$(tty)" ctty "$(ps -o tty= -p $$)"\#n"#.utf8)
        )
        let pattern = /tty=\/dev\/(ttys\d+)\|ctty=\s*(\S*?)\s*\|/
        #expect(await waitUntil(seconds: 5) { recorder.text.firstMatch(of: pattern) != nil })
        let match = try #require(recorder.text.firstMatch(of: pattern), "\(recorder.text)")
        #expect(match.output.1 == match.output.2, "\(recorder.text)")
        session.terminate()
    }

    /// Seen from outside while the shell waits at its prompt: `ps` names the pseudo-terminal as
    /// the shell's terminal, and the terminal's foreground group is the shell's own group.
    @Test(arguments: Shell.allCases)
    func atThePromptTheShellsGroupHasTheTerminal(_ shell: Shell) async throws {
        let recorder = Recorder()
        let session = try await start(shell, recorder)
        session.send(ArraySlice(#"printf '%s=%s|%s=%s|\n' tty "$(tty)" pid $$\#n"#.utf8))
        let pattern = /tty=\/dev\/(ttys\d+)\|pid=(\d+)\|/
        #expect(await waitUntil(seconds: 5) { recorder.text.firstMatch(of: pattern) != nil })
        let match = try #require(recorder.text.firstMatch(of: pattern), "\(recorder.text)")
        let pid = try #require(pid_t(match.output.2))
        // Waits until the shell is idle at its prompt again.
        try await Task.sleep(for: .milliseconds(300))
        let fields = try Self.processStatus(pid, "tty=,pgid=,tpgid=")
        #expect(fields == [String(match.output.1), "\(pid)", "\(pid)"], "\(fields)")
        session.terminate()
    }

    /// The fields of `ps -o <format> -p <pid>`, split at white space.
    static func processStatus(_ pid: pid_t, _ format: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-o", format, "-p", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    @Test(arguments: Shell.allCases)
    func controlCInterruptsTheForegroundProgram(_ shell: Shell) async throws {
        let recorder = Recorder()
        let session = try await start(shell, recorder)
        session.send(ArraySlice("sleep 30\n".utf8))
        #expect(await waitUntil(seconds: 5) { session.foreground != .none })
        session.send([0x03])
        #expect(await waitUntil(seconds: 5) { session.foreground == .none })
        session.send(ArraySlice("echo after-$((40 + 2))\n".utf8))
        #expect(await waitUntil(seconds: 5) { recorder.text.contains("after-42") })
        session.terminate()
    }

    @Test(arguments: Shell.allCases)
    func controlZSuspendsTheForegroundProgramAndFgResumesIt(_ shell: Shell) async throws {
        let recorder = Recorder()
        let session = try await start(shell, recorder)
        session.send(ArraySlice("sleep 30\n".utf8))
        #expect(await waitUntil(seconds: 5) { session.foreground == .program(name: "sleep") })
        session.send([0x1A])
        #expect(await waitUntil(seconds: 5) { session.foreground == .none })
        // bash reports "Stopped", zsh "suspended".
        #expect(
            await waitUntil(seconds: 5) {
                recorder.text.contains("Stopped") || recorder.text.contains("suspended")
            }, "\(recorder.text)")
        session.send(ArraySlice("fg\n".utf8))
        #expect(await waitUntil(seconds: 5) { session.foreground == .program(name: "sleep") })
        session.send([0x03])
        #expect(await waitUntil(seconds: 5) { session.foreground == .none })
        session.send(ArraySlice("echo resumed-$((40 + 2))\n".utf8))
        #expect(await waitUntil(seconds: 5) { recorder.text.contains("resumed-42") })
        session.terminate()
    }

    @Test(arguments: Shell.allCases)
    func closingSendsTheShellSIGHUP(_ shell: Shell) async throws {
        let recorder = Recorder()
        let session = try await start(shell, recorder)
        let marker = FileManager.default.temporaryDirectory
            .appending(path: "maw-hup-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: marker) }
        session.send(
            ArraySlice("trap 'echo hup > \(marker); exit 0' HUP; echo trap-$((1 + 1))\n".utf8))
        #expect(await waitUntil(seconds: 5) { recorder.text.contains("trap-2\r\n") })
        session.terminate()
        #expect(await waitUntil(seconds: 5) { FileManager.default.fileExists(atPath: marker) })
        #expect((try? String(contentsOfFile: marker, encoding: .utf8)) == "hup\n")
    }

    /// An app may itself ignore SIGINT and SIGPIPE, as a background command of a shell does,
    /// and block signals on the thread that starts the shell. The shell must start with every
    /// signal at its default and none blocked, or Ctrl-C would not reach its programs.
    @Test(arguments: Shell.allCases)
    func theShellStartsWithDefaultSignalsWhateverTheAppIgnoresOrBlocks(_ shell: Shell)
        async throws
    {
        let recorder = Recorder()
        let session: LocalShellSession
        do {
            let previousInterrupt = signal(SIGINT, SIG_IGN)
            let previousPipe = signal(SIGPIPE, SIG_IGN)
            var blocked = sigset_t()
            sigemptyset(&blocked)
            sigaddset(&blocked, SIGINT)
            var previousMask = sigset_t()
            pthread_sigmask(SIG_BLOCK, &blocked, &previousMask)
            defer {
                pthread_sigmask(SIG_SETMASK, &previousMask, nil)
                signal(SIGPIPE, previousPipe)
                signal(SIGINT, previousInterrupt)
            }
            session = try await start(shell, recorder)
        }
        session.send(ArraySlice(#"printf '%s=%s=\n' mask "$(ps -o sigmask= -p $$)"\#n"#.utf8))
        let pattern = /mask=\s*(\S+)\s*=/
        #expect(await waitUntil(seconds: 5) { recorder.text.firstMatch(of: pattern) != nil })
        #expect(recorder.text.firstMatch(of: pattern)?.output.1 == "0", "\(recorder.text)")
        session.send(ArraySlice("sleep 30\n".utf8))
        #expect(await waitUntil(seconds: 5) { session.foreground == .program(name: "sleep") })
        session.send([0x03])
        #expect(await waitUntil(seconds: 5) { session.foreground == .none })
        session.terminate()
    }

    /// Starts `shell`, ignores SIGHUP in it, runs `then`, and returns the shell's process.
    func startIgnoringSIGHUP(_ shell: Shell, _ recorder: Recorder, then command: String)
        async throws -> (LocalShellSession, pid_t)
    {
        let session = try await start(shell, recorder)
        session.send(ArraySlice("trap '' HUP; printf 'p%s=%s=\\n' id $$; \(command)\n".utf8))
        let pattern = /pid=(\d+)=/
        #expect(await waitUntil(seconds: 5) { recorder.text.firstMatch(of: pattern) != nil })
        let pid = recorder.text.firstMatch(of: pattern).flatMap { pid_t($0.output.1) } ?? 0
        #expect(pid > 0, "\(recorder.text)")
        return (session, pid)
    }

    /// Whether `pid` still exists, as a running process or as a zombie that nobody reaped.
    func exists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    @Test(arguments: Shell.allCases)
    func aShellIgnoringSIGHUPEndsWhenTheTerminalHangsUp(_ shell: Shell) async throws {
        let recorder = Recorder()
        let (session, pid) = try await startIgnoringSIGHUP(shell, recorder, then: "true")
        let started = ContinuousClock.now
        session.terminate()
        #expect(ContinuousClock.now - started < .milliseconds(500))
        #expect(!session.isRunning)
        // The hung-up terminal gives the shell an end of input, and the session reaps it.
        #expect(await waitUntil(seconds: 5) { !exists(pid) })
    }

    @Test(arguments: Shell.allCases)
    func aProgramIgnoringSIGHUPIsReapedOnceItExits(_ shell: Shell) async throws {
        let recorder = Recorder()
        // The shell becomes `sleep`, which keeps ignoring SIGHUP and never reads the terminal.
        let (session, pid) = try await startIgnoringSIGHUP(shell, recorder, then: "exec sleep 2")
        let started = ContinuousClock.now
        session.terminate()
        #expect(ContinuousClock.now - started < .milliseconds(500))
        // Closing waits for nothing: the main actor runs on while the program lives.
        try await Task.sleep(for: .milliseconds(500))
        #expect(exists(pid))
        #expect(await waitUntil(seconds: 5) { !exists(pid) })
    }

    /// A paste that the program does not read fills the terminal's input, and the input thread
    /// waits for room. Closing ends that wait and closes the input's descriptor too, so that the
    /// terminal hangs up and the program's next write fails, although it ignores SIGHUP.
    @Test func closingHangsUpTheTerminalWhileAPasteWaitsForRoom() async throws {
        let recorder = Recorder()
        let result = FileManager.default.temporaryDirectory
            .appending(path: "maw-hang-up-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: result) }
        let program =
            #"open(my $f, ">", $ARGV[0]); sleep 2; "#
            + #"print $f (defined(syswrite(STDOUT, "x")) ? "wrote" : "failed"); close($f)"#
        let (session, _) = try await startIgnoringSIGHUP(
            .sh, recorder, then: "exec /usr/bin/perl -e '\(program)' \(result.path)")
        // Lines that the program never reads, more than the terminal's input holds.
        session.send(ArraySlice(String(repeating: "echo unread\n", count: 10_000).utf8))
        try await Task.sleep(for: .milliseconds(300))
        session.terminate()
        var written = ""
        let finished = await waitUntil(seconds: 10) {
            written = (try? String(contentsOf: result, encoding: .utf8)) ?? ""
            return !written.isEmpty
        }
        #expect(finished && written == "failed", "\(written)")
    }

    @Test func theExitStatusReachesThePane() async throws {
        let pane = PaneController(
            profile: .localShell("/bin/sh"),
            session: LocalShellSession(shell: "/bin/sh", startDirectory: "/tmp"))
        pane.startIfNeeded()
        pane.send("exit 3\n")
        #expect(await waitUntil(seconds: 5) { pane.termination != nil })
        #expect(pane.termination == .exited(3))
        let terminal = pane.terminalView.getTerminal()
        let text = String(decoding: terminal.getBufferAsData(), as: UTF8.self)
        #expect(text.contains("[exited with status 3]\n[↩ new session]"), "\(text)")
    }

    @Test(arguments: Shell.allCases)
    func aDescriptorWithoutCloseOnExecIsNotInherited(_ shell: Shell) async throws {
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        // A number well above the test process's own, as an app's descriptor would be.
        let leaked = fcntl(ends[0], F_DUPFD, 200)
        defer {
            close(leaked)
            close(ends[0])
            close(ends[1])
        }
        #expect(leaked >= 200)
        #expect(fcntl(leaked, F_GETFD) & FD_CLOEXEC == 0)

        let recorder = Recorder()
        let session = try await start(shell, recorder)
        let probe =
            "for fd in 1 \(leaked); do if [ -e /dev/fd/$fd ]; then echo fd-$fd-open; "
            + "else echo fd-$fd-closed; fi; done; exit\n"
        session.send(ArraySlice(probe.utf8))
        #expect(await waitUntil(seconds: 5) { recorder.status != nil })
        #expect(recorder.text.contains("fd-1-open\r\n"), "\(recorder.text)")
        #expect(recorder.text.contains("fd-\(leaked)-closed\r\n"), "\(recorder.text)")
    }

    @Test func pollsTheWorkingDirectoryWithoutOSC7() async throws {
        let recorder = Recorder()
        let session = try start(recorder)
        session.send(ArraySlice("cd /usr/bin\n".utf8))
        let usrBin = canonicalPath("/usr/bin")
        #expect(
            await waitUntil(seconds: 5) {
                session.refresh(isVisible: true)
                return session.workingDirectory == usrBin
            })
        #expect(recorder.directories.last == usrBin)
        session.terminate()
    }

    @Test func prefersOSC7() async throws {
        let recorder = Recorder()
        let session = try start(recorder)
        session.terminalReportedWorkingDirectory("file:///Users/someone/project")
        #expect(session.workingDirectory == "/Users/someone/project")
        session.refresh(isVisible: true)
        #expect(session.workingDirectory == "/Users/someone/project")
        // A report from another host does not describe this Mac's file system.
        session.terminalReportedWorkingDirectory("file://far-away-host.example/elsewhere")
        #expect(session.workingDirectory == "/Users/someone/project")
        session.terminate()
    }

    /// The text of a pane's terminal, once it contains `expected`.
    func paneText(_ pane: PaneController, contains expected: String) async -> String {
        let terminal = pane.terminalView.getTerminal()
        var text = ""
        _ = await waitUntil(seconds: 5) {
            text = String(decoding: terminal.getBufferAsData(), as: UTF8.self)
            return text.contains(expected)
        }
        return text
    }

    @Test func aShellThatCannotBeExecutedReachesThePaneAsOnMain() async {
        // Not executable: refused before the start, with the suggestion, as main does.
        let refused = PaneController(
            profile: .localShell("/etc/hosts"), session: LocalShellSession(shell: "/etc/hosts"))
        refused.startIfNeeded()
        #expect(refused.failure == .programNotFound(path: "/etc/hosts"))
        let text = await paneText(refused, contains: "Choose another shell")
        #expect(text.contains("/etc/hosts does not exist or is not executable"), "\(text)")
    }

    @Test func aShellThatExecveRefusesReachesThePaneAsAStartFailure() async throws {
        // Executable, but no program: execve fails in the child, which reports it.
        let file = FileManager.default.temporaryDirectory
            .appending(path: "maw-not-a-program-\(UUID().uuidString)")
        try Data("not a program\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(chmod(file.path, 0o755) == 0)
        let pane = PaneController(
            profile: .localShell(file.path), session: LocalShellSession(shell: file.path))
        pane.startIfNeeded()
        let reason = "\(file.path) could not be executed: \(String(cString: strerror(ENOEXEC)))"
        #expect(pane.failure == .startFailed(reason: reason))
        let text = await paneText(pane, contains: "Press Enter to try again")
        let unwrapped = text.replacingOccurrences(of: "\n", with: "")
        #expect(unwrapped.contains("maw: The session could not start: "), "\(text)")
        #expect(unwrapped.contains("could not be executed"), "\(text)")
        #expect(!pane.isRunning)
    }

    @Test func aStartDirectoryThatDoesNotExistIsIgnoredAsOnMain() async throws {
        let recorder = Recorder()
        let session = LocalShellSession(shell: "/bin/sh", startDirectory: "/nonexistent-maw")
        session.delegate = recorder
        try session.start(size: .default)
        session.send(ArraySlice(#"printf '%s=[%s]\n' dir "$(pwd -P)"; exit\#n"#.utf8))
        #expect(await waitUntil(seconds: 5) { recorder.status != nil })
        // The shell starts where the app is, as forkpty's child did.
        let here = canonicalPath(FileManager.default.currentDirectoryPath)
        #expect(recorder.text.contains("dir=[\(here)]"), "\(recorder.text)")
        #expect(recorder.status == .exited(0))
    }

    @Test func refusesAMissingShell() {
        let session = LocalShellSession(shell: "/nonexistent/shell")
        #expect(throws: TerminalSessionError.programNotFound(path: "/nonexistent/shell")) {
            try session.start(size: .default)
        }
    }

    /// The prompt the test `.zshrc` sets, so that tests can tell when zsh is ready for input.
    static let prompt = "maw-ready> "

    /// The app's environment as the Finder or Xcode starts it, without locale variables, and with
    /// a `ZDOTDIR` of its own, so that the user's zsh startup files do not run. Its `.zshrc` only
    /// sets a known prompt.
    func finderLikeEnvironment() throws -> [String: String] {
        let zdotdir = FileManager.default.temporaryDirectory
            .appending(path: "maw-zdotdir-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        try Data("PROMPT='\(Self.prompt)'\n".utf8).write(to: zdotdir.appending(path: ".zshrc"))
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            key != "LANG" && !key.hasPrefix("LC_")
        }
        environment["ZDOTDIR"] = zdotdir.path
        return environment
    }

    func startZsh(_ recorder: Recorder, environment: [String: String]) throws -> LocalShellSession {
        // English with the region Turkey: the reported case, whose obvious locale does not exist.
        let session = LocalShellSession(
            shell: "/bin/zsh", startDirectory: "/tmp", baseEnvironment: environment,
            locale: Locale(identifier: "en_TR"))
        session.delegate = recorder
        try session.start(size: .default)
        return session
    }

    /// Waits until zsh shows its prompt, so that typed input reaches its line editor rather than
    /// the terminal driver's echo, then clears what was recorded so far.
    func waitForPrompt(_ recorder: Recorder) async -> Bool {
        let ready = await waitUntil(seconds: 5) { recorder.text.contains(Self.prompt) }
        recorder.output.removeAll()
        return ready
    }

    @Test func theShellGetsAUTF8CharacterType() async throws {
        let recorder = Recorder()
        let session = try startZsh(recorder, environment: finderLikeEnvironment())
        #expect(await waitForPrompt(recorder), "\(recorder.text)")
        session.send(ArraySlice("print -r -- \"charmap:$(locale charmap)\"\r".utf8))
        #expect(
            await waitUntil(seconds: 5) { recorder.text.contains("charmap:UTF-8") },
            "\(recorder.text)")
        session.terminate()
    }

    /// Turkish letters typed at the prompt, before Return. A shell in a single-byte locale
    /// echoes each byte separately, for example `ö` as `Ã¶` or `<00B6>`.
    static let typed = "echo şğüöçı ŞĞÜÖÇİ"

    @Test func multibyteCharactersTypedAtTheZshPromptEchoIntact() async throws {
        let recorder = Recorder()
        let session = try startZsh(recorder, environment: finderLikeEnvironment())
        #expect(await waitForPrompt(recorder), "\(recorder.text)")
        session.send(ArraySlice(Self.typed.utf8))
        #expect(
            await waitUntil(seconds: 5) { recorder.text.contains(Self.typed) },
            "\(recorder.text)")
        #expect(!recorder.text.contains("<00"))
        session.send(ArraySlice("\r".utf8))
        #expect(await waitUntil(seconds: 5) { recorder.text.contains("\r\nşğüöçı ŞĞÜÖÇİ\r\n") })
        session.terminate()
    }

    /// The control for the test above: in the C locale, which is valid and therefore kept, zsh
    /// mangles the same input, so the check above does detect the defect.
    @Test func theEchoCheckDetectsASingleByteLocale() async throws {
        let recorder = Recorder()
        var environment = try finderLikeEnvironment()
        environment["LC_ALL"] = "C"
        let session = try startZsh(recorder, environment: environment)
        #expect(await waitForPrompt(recorder), "\(recorder.text)")
        session.send(ArraySlice(Self.typed.utf8))
        try await Task.sleep(for: .seconds(1))
        #expect(!recorder.output.isEmpty)
        #expect(!recorder.text.contains(Self.typed), "\(recorder.text)")
        session.terminate()
    }

    @Test func environmentDropsAppOnlyVariables() {
        let environment = LocalShellSession.environment(
            from: ["HOME": "/Users/x", "DYLD_LIBRARY_PATH": "/x", "LANG": "de_DE.UTF-8"],
            locale: Locale(identifier: "en_TR"))
        #expect(environment.contains("HOME=/Users/x"))
        #expect(environment.contains("LANG=de_DE.UTF-8"))
        #expect(environment.contains("TERM=xterm-256color"))
        #expect(environment.contains("COLORTERM=truecolor"))
        #expect(!environment.contains { $0.hasPrefix("DYLD_") })
    }
}
