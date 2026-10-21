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
        #expect(!session.hasForegroundProcess)
        session.send(ArraySlice("sleep 30\n".utf8))
        #expect(await waitUntil(seconds: 5) { session.hasForegroundProcess })
        #expect(session.foregroundProcessName == "sleep")
        session.terminate()
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
