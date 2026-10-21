import ArgumentParser
import MawCore
import Testing

@testable import maw

/// Parses `arguments` exactly as `Maw.main()` does and returns the resolved action.
func action(_ arguments: String...) throws -> Action {
    try Maw.parse(ArgumentNormalizer.normalize(arguments)).resolveAction()
}

func distro(_ name: String) throws -> DistroName {
    try DistroName(name)
}

@Suite struct ParsingTests {
    // MARK: Shell and commands

    @Test func opensAShellWithNoArguments() throws {
        #expect(try action() == .shell(Session()))
    }

    @Test func opensAShellWithSessionOptions() throws {
        #expect(
            try action("-d", "Ubuntu", "-u", "root", "--cd", "~")
                == .shell(Session(distro: distro("Ubuntu"), user: "root", directory: "~")))
        #expect(
            try action("--distribution", "Ubuntu", "--user", "root")
                == .shell(Session(distro: distro("Ubuntu"), user: "root")))
    }

    @Test func runsACommandAfterTheTerminator() throws {
        #expect(try action("--", "ls", "-la") == .run(["ls", "-la"], Session()))
    }

    @Test func runsABareCommand() throws {
        #expect(try action("ls", "-la") == .run(["ls", "-la"], Session()))
    }

    @Test func runsABareCommandWithSessionOptions() throws {
        #expect(
            try action("-d", "Ubuntu", "-u", "root", "ls", "-la")
                == .run(["ls", "-la"], Session(distro: distro("Ubuntu"), user: "root")))
    }

    @Test func passesOptionLikeArgumentsToBareCommands() throws {
        #expect(
            try action("ls", "--shutdown", "-v") == .run(["ls", "--shutdown", "-v"], Session()))
    }

    @Test func execsACommandWithoutAShell() throws {
        #expect(try action("-e", "uname", "-a") == .exec(["uname", "-a"], Session()))
        #expect(try action("--exec", "uname") == .exec(["uname"], Session()))
    }

    @Test func keepsDashVAsAnArgumentToExec() throws {
        #expect(try action("-e", "grep", "-v", "foo") == .exec(["grep", "-v", "foo"], Session()))
    }

    @Test func keepsTerminatorsInsideAnExecCommand() throws {
        #expect(try action("-e", "ls", "--", "-x") == .exec(["ls", "--", "-x"], Session()))
        #expect(try action("-e", "--", "ls") == .exec(["ls"], Session()))
    }

    @Test func execsWithSessionOptions() throws {
        #expect(
            try action("-d", "Ubuntu", "--cd", "/tmp", "-e", "pwd")
                == .exec(["pwd"], Session(distro: distro("Ubuntu"), directory: "/tmp")))
    }

    // MARK: Install

    @Test func installsTheRecommendedDistribution() throws {
        #expect(try action("--install") == .install(nil))
    }

    @Test func installsANamedDistribution() throws {
        #expect(try action("--install", "Ubuntu-24.04") == .install(distro("Ubuntu-24.04")))
        #expect(try action("--install", "-d", "Ubuntu") == .install(distro("Ubuntu")))
        #expect(try action("-d", "Ubuntu", "--install") == .install(distro("Ubuntu")))
    }

    // MARK: List

    @Test(arguments: [["-l"], ["--list"]])
    func lists(_ arguments: [String]) throws {
        #expect(try action(arguments) == .list(.installed(verbose: false)))
    }

    @Test(arguments: [["-l", "-v"], ["--list", "--verbose"], ["-l", "--verbose"], ["-lv"]])
    func listsVerbosely(_ arguments: [String]) throws {
        #expect(try action(arguments) == .list(.installed(verbose: true)))
    }

    @Test(arguments: [["-l", "-o"], ["--list", "--online"]])
    func listsOnline(_ arguments: [String]) throws {
        #expect(try action(arguments) == .list(.online))
    }

    // MARK: Management

    @Test func setsTheDefault() throws {
        #expect(try action("-s", "Ubuntu") == .setDefault(distro("Ubuntu")))
        #expect(try action("--set-default", "Ubuntu") == .setDefault(distro("Ubuntu")))
    }

    @Test func terminates() throws {
        #expect(try action("-t", "Ubuntu") == .terminate(distro("Ubuntu")))
        #expect(try action("--terminate", "Ubuntu") == .terminate(distro("Ubuntu")))
    }

    @Test func shutsDown() throws {
        #expect(try action("--shutdown") == .shutdown)
    }

    @Test func exports() throws {
        #expect(
            try action("--export", "Ubuntu", "ubuntu.tar")
                == .export(distro("Ubuntu"), file: "ubuntu.tar"))
        #expect(try action("--export", "Ubuntu", "-") == .export(distro("Ubuntu"), file: "-"))
    }

    @Test func imports() throws {
        #expect(
            try action("--import", "Ubuntu", "ubuntu.tar")
                == .importDistro(distro("Ubuntu"), file: "ubuntu.tar"))
    }

    @Test func unregisters() throws {
        #expect(try action("--unregister", "Ubuntu") == .unregister(distro("Ubuntu")))
    }

    // MARK: General

    @Test func showsStatus() throws {
        #expect(try action("--status") == .status)
    }

    @Test(arguments: [["--version"], ["-v"]])
    func showsTheVersion(_ arguments: [String]) throws {
        #expect(try action(arguments) == .version)
    }

    // MARK: Running a stub

    @Test func everyActionReportsThatItIsNotImplemented() async throws {
        let command = try Maw.parse(ArgumentNormalizer.normalize(["-l", "-v"]))
        await #expect(throws: MawError.notImplemented(feature: "--list --verbose")) {
            try await command.run()
        }
        #expect(
            MawError.notImplemented(feature: "--list").errorDescription
                == "--list is not implemented yet")
    }
}

private func action(_ arguments: [String]) throws -> Action {
    try Maw.parse(ArgumentNormalizer.normalize(arguments)).resolveAction()
}
