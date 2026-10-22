import ArgumentParser
import Darwin
import Foundation
import MawCore
import MawProtocol
import Testing

@testable import mawd

@Suite struct DebugBootParsingTests {
    private func parse(_ arguments: String...) throws -> DebugBoot {
        let command = try Mawd.parseAsRoot(["debug-boot"] + arguments)
        return try #require(command as? DebugBoot)
    }

    private func failure(_ arguments: String...) -> String? {
        do {
            _ = try Mawd.parseAsRoot(["debug-boot"] + arguments)
            return nil
        } catch {
            #expect(Mawd.exitCode(for: error) == .validationFailure)
            return Mawd.message(for: error)
        }
    }

    @Test func hasNoOverridesByDefault() throws {
        let command = try parse()
        #expect(command.kernelDirectory == nil)
        #expect(command.kernelDirectoryURL == MawPaths().kernelDirectory)
        #expect(command.cmdline == nil)
        #expect(command.cpus == nil)
        #expect(command.memory == nil)
        #expect(command.disks.isEmpty)
        #expect(command.createDiskSize == nil)
        #expect(command.interactive == false)
        #expect(command.detachKey == nil)
        #expect(command.timeout == nil)
    }

    @Test func parsesEveryOption() throws {
        let command = try parse(
            "--kernel-dir", "/tmp/kernel", "--cmdline", "maw.test=poweroff", "--cpus", "2",
            "--memory", "512M", "--disk", "a.img", "--disk", "b.img", "--create-disk", "4G",
            "--timeout", "30")
        #expect(command.kernelDirectoryURL.path(percentEncoded: false) == "/tmp/kernel/")
        #expect(command.cmdline == "maw.test=poweroff")
        #expect(command.cpus == 2)
        #expect(command.memory == .mebibytes(512))
        #expect(command.disks == ["a.img", "b.img"])
        #expect(command.createDiskSize == .gibibytes(4))
        #expect(command.timeout == 30)
    }

    @Test func parsesInteractive() throws {
        let command = try parse("--interactive")
        #expect(command.interactive)
        #expect(command.detachKey == nil)
        #expect(try parse("--interactive", "--detach-key", "^Q").detachKey?.byte == 0x11)
    }

    @Test func rejectsADetachKeyWithoutATerminalSession() throws {
        #expect(failure("--detach-key", "^Q") == "--detach-key needs --interactive or --shell.")
        #expect(try parse("--shell", "--detach-key", "^Q").detachKey?.byte == 0x11)
    }

    @Test func parsesExec() throws {
        let command = try parse("--exec", "--", "sh", "-c", "exit 3")
        #expect(command.mode == .exec)
        #expect(command.command == ["sh", "-c", "exit 3"])
        #expect(command.repeatCount == nil)
        #expect(try parse("--exec", "--repeat", "100", "--", "true").repeatCount == 100)
    }

    @Test func parsesShell() throws {
        let command = try parse("--shell")
        #expect(command.mode == .shell)
        #expect(command.kernelArguments == nil)
    }

    @Test func selectsTheAttachedModeByDefault() throws {
        #expect(try parse().mode == .attached)
        #expect(try parse("--interactive").mode == .interactive)
    }

    @Test func addsTheDebugShellForInteractive() throws {
        #expect(try parse("--interactive").kernelArguments == "maw.debug=shell")
        #expect(
            try parse("--interactive", "--cmdline", "quiet").kernelArguments
                == "quiet maw.debug=shell")
        #expect(try parse("--cmdline", "quiet").kernelArguments == "quiet")
    }

    @Test func rejectsInvalidExecCombinations() {
        #expect(
            failure("--exec")
                == "--exec needs a command after --, for example --exec -- uname -a.")
        #expect(failure("--", "uname") == "A command after -- needs --exec.")
        #expect(failure("--shell", "--", "uname") == "A command after -- needs --exec.")
        #expect(
            failure("--exec", "--shell", "--", "true")
                == "--exec and --shell cannot be combined.")
        #expect(
            failure("--interactive", "--exec", "--", "true")
                == "--interactive and --exec cannot be combined.")
        #expect(
            failure("--exec", "--timeout", "5", "--", "true")
                == "--timeout cannot be combined with --exec.")
        #expect(failure("--repeat", "3") == "--repeat needs --exec.")
        #expect(failure("--exec", "--repeat", "0", "--", "true") == "--repeat must be at least 1.")
    }

    @Test func explainsAnInvalidDetachKey() {
        #expect(
            failure("--interactive", "--detach-key", "^[")
                == "The value '^[' is invalid for '--detach-key <key>': '^[' cannot be the detach "
                + "key: it is Escape, which starts arrow-key sequences.")
    }

    @Test func rejectsTimeoutWithInteractive() {
        #expect(
            failure("--interactive", "--timeout", "5")
                == "--timeout cannot be combined with --interactive.")
    }

    @Test func rejectsCreateDiskWithoutADisk() {
        #expect(failure("--create-disk", "1G") == "--create-disk needs at least one --disk.")
    }

    @Test func rejectsInvalidNumbers() {
        #expect(failure("--cpus", "0") == "--cpus must be at least 1.")
        #expect(failure("--timeout", "0") == "--timeout must be at least 1 second.")
    }

    @Test func explainsAnInvalidMemorySize() {
        #expect(
            failure("--memory", "4")
                == "The value '4' is invalid for '--memory <size>': '4' is not a valid size: it has no unit."
        )
    }

    @Test func listsItsSubcommands() {
        #expect(
            Mawd.configuration.subcommands.map { $0.configuration.commandName }
                == ["install", "uninstall", "serve", "debug-boot"])
    }
}

@Suite struct DebugBootBehaviorTests {
    @Test(arguments: [
        ("maw-initramfs c1abd31 kernel=6.18.57-maw", true),
        ("maw-initramfs 0.1.0-3-gabc kernel=6.19.1-maw", true),
        ("maw-initramfs: poweroff", false),
        ("Run /init as init process", false),
        ("maw-initramfs c1abd31", false),
    ])
    func recognizesTheBanner(line: String, isBanner: Bool) {
        #expect(DebugBoot.isBanner(line) == isBanner)
    }

    @Test func describesStopOutcomes() {
        #expect(
            DebugBoot.describe(.clean(after: .milliseconds(412), via: .agent))
                == "shutdown: clean after 412 ms via the guest agent")
        #expect(
            DebugBoot.describe(.clean(after: .milliseconds(90), via: .stopRequest))
                == "shutdown: clean after 90 ms via a stop request")
        #expect(
            DebugBoot.describe(.forced(after: .milliseconds(5_012)))
                == "shutdown: forced after 5012 ms (the guest did not power off when asked)")
    }

    @Test func describesLatency() {
        let durations: [Duration] = (1...100).map { .microseconds($0 * 100) }
        #expect(
            DebugBoot.describeLatency(durations, command: "true")
                == "exec: 100 runs of true: median 5.05 ms, p95 9.50 ms")
        #expect(
            DebugBoot.describeLatency([.milliseconds(3)], command: "true")
                == "exec: 1 run of true: median 3.00 ms, p95 3.00 ms")
    }

    @Test func passesTermAndLangToTheGuest() {
        let environment = DebugBoot.hostEnvironment(terminal: true)
        #expect(environment["TERM"] != nil)
        #expect(DebugBoot.hostEnvironment(terminal: false)["TERM"] == nil)
    }
}
