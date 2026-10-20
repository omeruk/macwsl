import ArgumentParser
import Darwin
import Foundation
import MacWSLCore
import Testing

@testable import macwsld

@Suite struct DebugBootParsingTests {
    private func parse(_ arguments: String...) throws -> DebugBoot {
        let command = try MacWSLD.parseAsRoot(["debug-boot"] + arguments)
        return try #require(command as? DebugBoot)
    }

    private func failure(_ arguments: String...) -> String? {
        do {
            _ = try MacWSLD.parseAsRoot(["debug-boot"] + arguments)
            return nil
        } catch {
            #expect(MacWSLD.exitCode(for: error) == .validationFailure)
            return MacWSLD.message(for: error)
        }
    }

    @Test func hasNoOverridesByDefault() throws {
        let command = try parse()
        #expect(command.kernelDirectory == nil)
        #expect(command.kernelDirectoryURL == MacWSLPaths().kernelDirectory)
        #expect(command.cmdline == nil)
        #expect(command.cpus == nil)
        #expect(command.memory == nil)
        #expect(command.disks.isEmpty)
        #expect(command.createDiskSize == nil)
        #expect(command.interactive == false)
        #expect(command.timeout == nil)
    }

    @Test func parsesEveryOption() throws {
        let command = try parse(
            "--kernel-dir", "/tmp/kernel", "--cmdline", "macwsl.test=poweroff", "--cpus", "2",
            "--memory", "512M", "--disk", "a.img", "--disk", "b.img", "--create-disk", "4G",
            "--timeout", "30")
        #expect(command.kernelDirectoryURL.path(percentEncoded: false) == "/tmp/kernel/")
        #expect(command.cmdline == "macwsl.test=poweroff")
        #expect(command.cpus == 2)
        #expect(command.memory == .mebibytes(512))
        #expect(command.disks == ["a.img", "b.img"])
        #expect(command.createDiskSize == .gibibytes(4))
        #expect(command.timeout == 30)
    }

    @Test func parsesInteractive() throws {
        #expect(try parse("--interactive").interactive)
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

    @Test func keepsThePlaceholderBehaviorWithoutASubcommand() throws {
        #expect(try MacWSLD.parseAsRoot([]) is MacWSLD)
    }
}

@Suite struct DebugBootBehaviorTests {
    @Test func requiresATerminalOnStandardInput() throws {
        let pipe = Pipe()
        #expect(throws: MacWSLError.notATerminal(stream: "standard input")) {
            try Terminal.requireTerminals(
                input: pipe.fileHandleForReading.fileDescriptor,
                output: pipe.fileHandleForWriting.fileDescriptor)
        }
    }

    @Test func requiresATerminalOnStandardOutput() throws {
        var primary: Int32 = -1
        var secondary: Int32 = -1
        try #require(openpty(&primary, &secondary, nil, nil, nil) == 0)
        defer {
            close(primary)
            close(secondary)
        }
        let pipe = Pipe()
        #expect(throws: MacWSLError.notATerminal(stream: "standard output")) {
            try Terminal.requireTerminals(
                input: secondary, output: pipe.fileHandleForWriting.fileDescriptor)
        }
        #expect(throws: Never.self) {
            try Terminal.requireTerminals(input: secondary, output: secondary)
        }
    }

    @Test(arguments: [
        ("macwsl-initramfs c1abd31 kernel=6.18.57-macwsl", true),
        ("macwsl-initramfs 0.1.0-3-gabc kernel=6.19.1-macwsl", true),
        ("macwsl-initramfs: poweroff", false),
        ("Run /init as init process", false),
        ("macwsl-initramfs c1abd31", false),
    ])
    func recognizesTheBanner(line: String, isBanner: Bool) {
        #expect(DebugBoot.isBanner(line) == isBanner)
    }

    @Test func describesStopOutcomes() {
        #expect(
            DebugBoot.describe(.clean(after: .milliseconds(412))) == "shutdown: clean after 412 ms")
        #expect(
            DebugBoot.describe(.forced(after: .milliseconds(5_012)))
                == "shutdown: forced after 5012 ms (the guest did not power off when asked)")
    }
}
