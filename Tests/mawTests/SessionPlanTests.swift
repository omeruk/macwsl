import Darwin
import MawCore
import MawProtocol
import Testing

@testable import maw

@Suite struct SessionPlanTests {
    /// A Mac whose home directory is `/Users/alice` and whose current directory is a project
    /// in it.
    static let mac = MacDirectories.fixed(current: "/Users/alice/Projects/app")

    private func plan(_ arguments: String..., mac: MacDirectories = SessionPlanTests.mac) throws
        -> SessionPlan
    {
        try plan(arguments, mac: mac)
    }

    private func plan(_ arguments: [String], mac: MacDirectories) throws -> SessionPlan {
        try #require(
            try SessionPlan(
                Maw.parse(ArgumentNormalizer.normalize(arguments)).resolveAction(), mac: mac))
    }

    /// An action without a session has no plan, rather than a trap.
    @Test(arguments: [["--list"], ["--shutdown"], ["--export", "Ubuntu-24.04", "u.tar"]])
    func hasNoPlanForAnActionWithoutASession(_ arguments: [String]) throws {
        #expect(
            try SessionPlan(Maw.parse(ArgumentNormalizer.normalize(arguments)).resolveAction())
                == nil)
    }

    // MARK: Actions to sessions

    @Test func opensALoginShell() throws {
        #expect(
            try plan()
                == SessionPlan(
                    machine: nil, program: .loginShell, workingDirectory: "/mnt/mac/Projects/app",
                    fallsBackToHome: true))
    }

    @Test func runsACommandThroughTheUsersShell() throws {
        #expect(try plan("uname", "-a").program == .shellCommand("uname -a"))
        #expect(try plan("--", "uname", "-a").program == .shellCommand("uname -a"))
    }

    @Test func runsACommandDirectlyWithExec() throws {
        #expect(try plan("-e", "sh", "-c", "exit 3").program == .argv(["sh", "-c", "exit 3"]))
    }

    @Test func runsInTheAbsoluteLinuxDirectoryThatItIsGiven() throws {
        #expect(try plan("--cd", "/tmp", "-e", "pwd").workingDirectory == "/tmp")
        #expect(try plan("--cd", "/root").workingDirectory == "/root")
        #expect(try plan("--cd", "/tmp").fallsBackToHome == false)
    }

    @Test func runsInTheLinuxHomeDirectoryForAQuotedTilde() throws {
        let home = try plan("--cd", "~", "-e", "pwd")
        #expect(home.workingDirectory == nil)
        #expect(home.notice == nil)
        #expect(try plan("--cd", "~/src", "-e", "pwd").workingDirectory == "~/src")
    }

    /// The Mac's shell expands an unquoted `~`, so `--cd ~` arrives as the Mac home directory.
    @Test func translatesAMacPathUnderTheHomeDirectory() throws {
        #expect(try plan("--cd", "/Users/alice").workingDirectory == "/mnt/mac")
        #expect(
            try plan("--cd", "/Users/alice/My Projects/ç").workingDirectory
                == "/mnt/mac/My Projects/ç")
        #expect(try plan("--cd", "/Users/alice/x").fallsBackToHome == false)
    }

    @Test func resolvesARelativePathAgainstTheCurrentDirectory() throws {
        #expect(
            try plan("--cd", "src", "-e", "pwd").workingDirectory == "/mnt/mac/Projects/app/src")
        #expect(try plan("--cd", "..").workingDirectory == "/mnt/mac/Projects")
        #expect(try plan("--cd", ".").workingDirectory == "/mnt/mac/Projects/app")
    }

    @Test(arguments: ["/Users/alice2", "/Volumes/USB", "/private/tmp", "/Users/bob/x"])
    func refusesAMacPathOutsideTheHomeDirectory(_ directory: String) throws {
        #expect(throws: MawError.directoryNotShared(directory)) {
            try plan("--cd", directory, "-e", "pwd")
        }
    }

    @Test func refusesARelativePathThatLeavesTheHomeDirectory() throws {
        #expect(throws: MawError.directoryNotShared("/Users")) {
            try plan("--cd", "../../..")
        }
        #expect(throws: MawError.directoryNotShared("/tmp/x")) {
            try plan("--cd", "x", mac: .fixed(current: "/tmp"))
        }
        #expect(throws: MawError.currentDirectoryUnreadable(reason: "No such file or directory")) {
            try plan("--cd", "x", mac: .fixed(currentError: ENOENT))
        }
    }

    // MARK: The working directory without --cd

    @Test func startsInTheTranslatedCurrentDirectory() throws {
        for arguments in [["-e", "pwd"], ["pwd"], ["--", "pwd"], []] {
            let session = try plan(arguments, mac: Self.mac)
            #expect(session.workingDirectory == "/mnt/mac/Projects/app")
            #expect(session.fallsBackToHome)
            #expect(session.notice == nil)
        }
        let home = try plan("-e", "pwd", mac: .fixed(current: "/Users/alice"))
        #expect(home.workingDirectory == "/mnt/mac")
    }

    @Test func comparesTheResolvedDirectories() throws {
        // The home directory is reached through a link; getcwd reports the resolved path.
        let linked = MacDirectories.fixed(
            current: "/Volumes/Data/alice/src", home: "/Users/alice",
            links: ["/Users/alice": "/Volumes/Data/alice"])
        #expect(try plan("-e", "pwd", mac: linked).workingDirectory == "/mnt/mac/src")
        #expect(
            try plan("--cd", "/Users/alice/src", mac: linked).workingDirectory == "/mnt/mac/src")
    }

    @Test func startsInTheLinuxHomeDirectoryOutsideTheMacHomeDirectory() throws {
        for current in ["/tmp", "/Volumes/USB", "/Users/alice2"] {
            for arguments in [["-e", "pwd"], ["pwd"], []] {
                let session = try plan(arguments, mac: .fixed(current: current))
                #expect(session.workingDirectory == nil)
                #expect(!session.fallsBackToHome)
                #expect(
                    session.notice
                        == "maw: \(current) is not shared with Linux; starting in the home directory."
                )
            }
        }
        #expect(
            try plan("-e", "pwd", mac: .fixed(current: "/Volumes/USB")).notice!.count <= 80)
    }

    @Test func startsInTheLinuxHomeDirectoryWhenTheCurrentDirectoryIsGone() throws {
        let gone = try plan("-e", "pwd", mac: .fixed(currentError: ENOENT))
        #expect(gone.workingDirectory == nil)
        #expect(
            gone.notice
                == "maw: the current directory no longer exists; starting in the home directory.")
        #expect(gone.notice!.count <= 80)
        let unreadable = try plan("-e", "pwd", mac: .fixed(currentError: EACCES))
        #expect(
            unreadable.notice
                == "maw: the current directory cannot be read (Permission denied); starting in the"
                + " home directory.")
    }

    @Test func saysWhyTheGuestFellBack() {
        func line(_ fallback: WorkingDirectoryFallback) -> String {
            WorkingDirectory.fallbackLine(
                fallback, directory: "/mnt/mac/src", distribution: "Ubuntu-24.04")
        }
        #expect(
            line(.shareNotMounted)
                == "maw: /mnt/mac is not mounted in Ubuntu-24.04; starting in the home directory."
                + " ~/Library/Logs/maw/Ubuntu-24.04.log says why.")
        #expect(
            line(.notFound)
                == "maw: /mnt/mac/src does not exist in Linux; starting in the home directory.")
        #expect(
            line(.permissionDenied)
                == "maw: /mnt/mac/src cannot be entered (permission denied); starting in the home"
                + " directory.")
        #expect(line(.notADirectory).hasPrefix("maw: /mnt/mac/src is not a directory in Linux;"))
        #expect(line(.other).hasPrefix("maw: /mnt/mac/src cannot be entered in Linux;"))
    }

    @Test func runsAsTheRequestedUser() throws {
        #expect(try plan("-u", "root", "-e", "id", "-u").user == "root")
        #expect(try plan("-e", "id").user == nil)
    }

    @Test func runsOnTheNamedDistributionOrTheDefault() throws {
        #expect(
            try plan("-d", "Ubuntu", "uname").machine == .distribution(try DistroName("Ubuntu")))
        // The daemon resolves the default distribution, and reports when none is installed.
        #expect(try plan("uname").machine == nil)
    }

    // MARK: The shell command line

    @Test func joinsArgumentsWithSingleSpaces() {
        #expect(SessionPlan.shellCommand(["ls", "-la", "/"]) == .shellCommand("ls -la /"))
    }

    @Test func keepsSpacesInsideAnArgumentButNotItsBoundaries() {
        // The Mac's shell removed the quotes of `maw echo "a  b"`; the guest's shell splits
        // the joined line again, as wsl.exe's does.
        #expect(SessionPlan.shellCommand(["echo", "a  b"]) == .shellCommand("echo a  b"))
    }

    @Test func passesQuotesToTheGuestShell() {
        // `maw echo "'a  b'"` keeps the inner quotes, so the guest's shell keeps the spaces.
        #expect(SessionPlan.shellCommand(["echo", "'a  b'"]) == .shellCommand("echo 'a  b'"))
        #expect(
            SessionPlan.shellCommand(["sh", "-c", "'exit 3'"])
                == .shellCommand("sh -c 'exit 3'"))
    }

    @Test func turnsEmptyArgumentsIntoSpaces() {
        #expect(SessionPlan.shellCommand(["echo", "", "x"]) == .shellCommand("echo  x"))
        #expect(SessionPlan.shellCommand([""]) == .shellCommand(""))
    }

    @Test func passesShellSyntaxThrough() {
        #expect(
            SessionPlan.shellCommand(["echo", "$HOME", "|", "wc", "-c"])
                == .shellCommand("echo $HOME | wc -c"))
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

extension MacDirectories {
    /// A Mac with fixed answers: `links` maps a path to what `realpath` resolves it to; every
    /// other path resolves to itself.
    static func fixed(
        current: String? = nil, currentError: Int32 = ENOENT, home: String = "/Users/alice",
        links: [String: String] = [:]
    ) -> MacDirectories {
        MacDirectories(
            current: {
                current.map { .path($0) } ?? .failed(errno: currentError)
            },
            home: home,
            resolve: { path in
                links.first { path == $0.key || path.hasPrefix($0.key + "/") }.map {
                    $0.value + path.dropFirst($0.key.count)
                } ?? path
            })
    }
}
