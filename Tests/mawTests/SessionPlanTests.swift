import MawCore
import Testing

@testable import maw

@Suite struct SessionPlanTests {
    private func plan(_ arguments: String...) throws -> SessionPlan {
        try SessionPlan(Maw.parse(ArgumentNormalizer.normalize(arguments)).resolveAction())
    }

    // MARK: Actions to sessions

    @Test func opensALoginShell() throws {
        #expect(
            try plan()
                == SessionPlan(machine: .initramfs, argv: ["/bin/sh", "-l"], workingDirectory: "/"))
    }

    @Test func runsACommandThroughTheShell() throws {
        #expect(try plan("uname", "-a").argv == ["/bin/sh", "-c", "uname -a"])
        #expect(try plan("--", "uname", "-a").argv == ["/bin/sh", "-c", "uname -a"])
    }

    @Test func runsACommandDirectlyWithExec() throws {
        #expect(try plan("-e", "sh", "-c", "exit 3").argv == ["sh", "-c", "exit 3"])
    }

    @Test func runsInTheRootDirectoryByDefault() throws {
        #expect(try plan("-e", "pwd").workingDirectory == "/")
    }

    @Test func runsInAnAbsoluteLinuxDirectory() throws {
        #expect(try plan("--cd", "/tmp", "-e", "pwd").workingDirectory == "/tmp")
        #expect(try plan("--cd", "/root").workingDirectory == "/root")
    }

    @Test(arguments: [
        "projects", "./src", "~", "~/src", "/Users/me", "/Volumes/Data/x", "/private/tmp",
    ])
    func refusesADirectoryItCannotTranslateYet(_ directory: String) throws {
        #expect(throws: MawError.unsupportedDirectory(directory)) {
            try plan("--cd", directory, "-e", "pwd")
        }
    }

    @Test func refusesAUser() throws {
        #expect(throws: MawError.notImplemented(feature: "--user (-u)", phase: "05")) {
            try plan("-u", "root")
        }
    }

    @Test func refusesADistributionThatIsNotInstalled() throws {
        #expect(throws: MawError.distributionNotInstalled(try DistroName("Ubuntu"))) {
            try plan("-d", "Ubuntu", "uname")
        }
    }

    @Test func runsOnTheInitramfsMachineWithoutADistribution() throws {
        #expect(try MachineResolver.machine(for: nil) == .initramfs)
    }

    // MARK: The shell command line

    @Test func joinsArgumentsWithSingleSpaces() {
        #expect(SessionPlan.shellCommand(["ls", "-la", "/"]) == ["/bin/sh", "-c", "ls -la /"])
    }

    @Test func keepsSpacesInsideAnArgumentButNotItsBoundaries() {
        // The Mac's shell removed the quotes of `maw echo "a  b"`; the guest's shell splits
        // the joined line again, as wsl.exe's does.
        #expect(SessionPlan.shellCommand(["echo", "a  b"]) == ["/bin/sh", "-c", "echo a  b"])
    }

    @Test func passesQuotesToTheGuestShell() {
        // `maw echo "'a  b'"` keeps the inner quotes, so the guest's shell keeps the spaces.
        #expect(SessionPlan.shellCommand(["echo", "'a  b'"]) == ["/bin/sh", "-c", "echo 'a  b'"])
        #expect(
            SessionPlan.shellCommand(["sh", "-c", "'exit 3'"])
                == ["/bin/sh", "-c", "sh -c 'exit 3'"])
    }

    @Test func turnsEmptyArgumentsIntoSpaces() {
        #expect(SessionPlan.shellCommand(["echo", "", "x"]) == ["/bin/sh", "-c", "echo  x"])
        #expect(SessionPlan.shellCommand([""]) == ["/bin/sh", "-c", ""])
    }

    @Test func passesShellSyntaxThrough() {
        #expect(
            SessionPlan.shellCommand(["echo", "$HOME", "|", "wc", "-c"])
                == ["/bin/sh", "-c", "echo $HOME | wc -c"])
    }

    // MARK: Terminal or pipes

    @Test func usesATerminalOnlyWhenBothStreamsAreTerminals() {
        #expect(SessionMode.select(inputIsTerminal: true, outputIsTerminal: true) == .terminal)
        #expect(SessionMode.select(inputIsTerminal: false, outputIsTerminal: true) == .pipes)
        #expect(SessionMode.select(inputIsTerminal: true, outputIsTerminal: false) == .pipes)
        #expect(SessionMode.select(inputIsTerminal: false, outputIsTerminal: false) == .pipes)
    }

    @Test func passesTermFromTheHost() {
        #expect(SessionMode.terminal.environment(host: ["TERM": "screen"]) == ["TERM": "screen"])
        #expect(SessionMode.pipes.environment(host: ["TERM": "screen"]) == ["TERM": "screen"])
        #expect(SessionMode.terminal.environment(host: [:]) == ["TERM": "xterm-256color"])
        #expect(SessionMode.pipes.environment(host: [:]) == [:])
        #expect(
            SessionMode.terminal.environment(host: ["LANG": "tr_TR.UTF-8"]).keys.sorted() == [
                "TERM"
            ])
    }
}
