import Foundation
import MawCore
import Testing

@testable import MawAgentKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@Suite struct MawPathCommandTests {
    static let commandLine = "console=hvc0 maw.share=maw-mac maw.home=/Users/Ay%C5%9Fe%20%C3%96z"

    func run(
        _ arguments: [String], commandLine: String? = Self.commandLine,
        currentDirectory: String? = "/mnt/mac/src/app"
    ) -> MawPathCommand.Outcome {
        MawPathCommand.run(
            arguments, commandLine: { commandLine }, currentDirectory: { currentDirectory })
    }

    func output(_ text: String) -> MawPathCommand.Outcome {
        .init(status: 0, output: text + "\n", error: "")
    }

    @Test func translatesMacToLinuxByDefault() {
        #expect(run(["/Users/Ayşe Öz/Projects/app"]) == output("/mnt/mac/Projects/app"))
        #expect(run(["-u", "/Users/Ayşe Öz/Projects/app"]) == output("/mnt/mac/Projects/app"))
        #expect(run(["/Users/Ayşe Öz"]) == output("/mnt/mac"))
    }

    @Test func translatesLinuxToMac() {
        #expect(run(["-m", "/mnt/mac/Projects/app"]) == output("/Users/Ayşe Öz/Projects/app"))
        #expect(run(["-m", "/mnt/mac/a/../b/"]) == output("/Users/Ayşe Öz/b"))
    }

    @Test func resolvesARelativePathAgainstTheCurrentDirectoryWithA() {
        #expect(run(["-a", "-m", "."]) == output("/Users/Ayşe Öz/src/app"))
        #expect(run(["-am", "../lib"]) == output("/Users/Ayşe Öz/src/lib"))
        #expect(run(["-a", "lib"]) == output("/mnt/mac/src/app/lib"))
        #expect(run(["-a", "-u", "./lib/"]) == output("/mnt/mac/src/app/lib"))
    }

    @Test func givesARelativeResultForARelativePathWithoutA() {
        #expect(run(["src/./app/"]) == output("src/app"))
        #expect(run(["-m", "a/../../b"]) == output("../b"))
        #expect(run(["-m", "."]) == output("."))
    }

    @Test func failsForAPathThatTheOtherSideCannotSee() {
        let outside = run(["-m", "/home/ayse"])
        #expect(outside.status == 1)
        #expect(outside.output.isEmpty)
        #expect(
            outside.error == "mawpath: /home/ayse is not under /mnt/mac, so the Mac cannot see it\n"
        )
        let mac = run(["/Volumes/USB"])
        #expect(mac.status == 1)
        #expect(mac.error.hasPrefix("mawpath: /Volumes/USB is not under the Mac's home directory"))
        #expect(run(["-a", "-m", "."], currentDirectory: "/tmp").status == 1)
        #expect(run(["/Users/Ayşe Özkan"]).status == 1)
    }

    @Test func reportsAnUnknownHomeDirectory() {
        for commandLine in [nil, "console=hvc0", "maw.home=%ZZ", "maw.home=%C5", "maw.home=rel"] {
            let outcome = run(["/Users/a"], commandLine: commandLine)
            #expect(outcome.status == 1, "\(commandLine ?? "nil")")
            #expect(outcome.error.contains("the Mac's home directory is not known"))
        }
    }

    @Test func refusesWrongArguments() {
        for arguments in [[], ["a", "b"], ["-x", "a"], ["-u", "-m", "a"], ["-w", "a"], [""]] {
            let outcome = run(arguments)
            #expect(outcome.status == 64, "\(arguments)")
            #expect(outcome.error.hasPrefix("mawpath: "))
        }
        #expect(run(["--", "-dir"]).status == 0)
    }

    @Test func describesItsFlags() {
        let help = run(["--help"])
        #expect(help.status == 0)
        for flag in ["-u ", "-m ", "-a ", "-h, --help"] {
            #expect(help.output.contains(flag))
        }
        #expect(run(["-h"]) == help)
    }
}

@Suite struct AgentCommandTests {
    @Test func recognizesMawpathByTheLastComponentOfItsName() {
        #expect(AgentCommand(argv: ["mawpath", "-m", "."]) == .mawpath(["-m", "."]))
        #expect(AgentCommand(argv: ["/usr/local/bin/mawpath"]) == .mawpath([]))
        #expect(AgentCommand(argv: ["./mawpath", "--version"]) == .mawpath(["--version"]))
    }

    /// runuser -l names the helper `-maw-agent`, as a login shell; it is never mawpath.
    @Test func neverTakesTheHelpersLoginNameForMawpath() {
        #expect(
            AgentCommand(argv: ["-maw-agent", "login-shell", "/tmp", "exact", "/bin/sh"])
                == .loginShell(["/tmp", "exact", "/bin/sh"]))
        #expect(AgentCommand(argv: ["-mawpath", "x"]) == .usage(status: 64))
        #expect(AgentCommand(argv: ["/run/maw/mawpath-old"]) == .serve)
        #expect(AgentCommand(argv: ["mawpath/maw-agent"]) == .serve)
    }

    @Test func readsTheAgentsSubcommands() {
        #expect(AgentCommand(argv: ["/run/maw/maw-agent"]) == .serve)
        #expect(AgentCommand(argv: ["maw-agent", "--version"]) == .version)
        #expect(AgentCommand(argv: ["maw-agent", "self-test"]) == .selfTest)
        #expect(
            AgentCommand(argv: ["maw-agent", "mount-mac-share", "/sysroot", "maw-mac"])
                == .mountMacShare(root: "/sysroot", tag: "maw-mac"))
        #expect(
            AgentCommand(argv: ["maw-agent", "mount-mac-share", "/sysroot"]) == .usage(status: 64))
        #expect(AgentCommand(argv: ["maw-agent", "other"]) == .usage(status: 64))
        #expect(AgentCommand(argv: []) == .serve)
    }
}

/// The link `/usr/local/bin/mawpath`, made under a root laid out in a temporary directory.
@Suite struct MawPathLinkTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "maw-mawpath-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func path(_ relative: String) -> String {
        root.appending(path: relative).path(percentEncoded: false)
    }

    func makeBin() throws {
        try FileManager.default.createDirectory(
            atPath: path("usr/local/bin"), withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    @Test func createsTheLinkAndKeepsItAfterwards() throws {
        defer { cleanUp() }
        try makeBin()
        #expect(MawPathLink.install(root: root.path(percentEncoded: false)) == .created)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: path("usr/local/bin/mawpath"))
                == "/run/maw/maw-agent")
        #expect(MawPathLink.install(root: root.path(percentEncoded: false)) == .alreadyPresent)
        #expect(MawPathLink.consoleLine(.created) == nil)
    }

    @Test func leavesAnotherMawpathAsItIs() throws {
        defer { cleanUp() }
        try makeBin()
        try "#!/bin/sh\n".write(
            toFile: path("usr/local/bin/mawpath"), atomically: false, encoding: .utf8)
        let outcome = MawPathLink.install(root: root.path(percentEncoded: false))
        #expect(
            outcome
                == .refused(
                    "/usr/local/bin/mawpath exists and is not maw's link; it is left as it is"))
        #expect(
            try String(contentsOfFile: path("usr/local/bin/mawpath"), encoding: .utf8)
                == "#!/bin/sh\n")
        try FileManager.default.removeItem(atPath: path("usr/local/bin/mawpath"))
        try FileManager.default.createSymbolicLink(
            atPath: path("usr/local/bin/mawpath"), withDestinationPath: "/elsewhere")
        #expect(MawPathLink.install(root: root.path(percentEncoded: false)) == outcome)
    }

    @Test func refusesAMissingOrLinkedDirectory() throws {
        defer { cleanUp() }
        let rootPath = root.path(percentEncoded: false)
        try FileManager.default.createDirectory(
            atPath: path("usr/local"), withIntermediateDirectories: true)
        #expect(MawPathLink.install(root: rootPath) == .refused("/usr/local/bin does not exist"))
        try FileManager.default.createDirectory(
            atPath: path("elsewhere"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            atPath: path("usr/local/bin"), withDestinationPath: "../../elsewhere")
        #expect(
            MawPathLink.install(root: rootPath) == .refused("/usr/local/bin is a symbolic link"))
        #expect(!FileManager.default.fileExists(atPath: path("elsewhere/mawpath")))
        try FileManager.default.removeItem(atPath: path("usr"))
        try FileManager.default.createSymbolicLink(
            atPath: path("usr"), withDestinationPath: "elsewhere")
        #expect(MawPathLink.install(root: rootPath) == .refused("/usr is a symbolic link"))
        #expect(
            MawPathLink.consoleLine(.refused("/usr is a symbolic link"))
                == "maw-agent: mawpath is not on PATH: /usr is a symbolic link")
    }
}
