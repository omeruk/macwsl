import Darwin
import Foundation
import Testing
import os

extension Tag {
    /// Tests that boot a real virtual machine. They need an Apple silicon Mac that is not itself
    /// a virtual machine, the guest files from scripts/fetch-guest.sh, and a signed macwsld.
    @Tag static var integration: Self
}

private let integrationEnabled = ProcessInfo.processInfo.environment["MACWSL_INTEGRATION"] == "1"

/// Boots the guest by running the signed `macwsld debug-boot` as a subprocess. The `swift test`
/// runner is not signed with the virtualization entitlement, so these tests cannot create a
/// virtual machine in-process. scripts/integration-test.sh builds and signs macwsld, then runs
/// them with MACWSL_INTEGRATION=1 and MACWSLD_PATH set.
@Suite(
    .tags(.integration),
    .enabled(
        if: integrationEnabled,
        "Integration tests boot a real virtual machine; run scripts/integration-test.sh."),
    .serialized
)
struct IntegrationTests {
    let macwsld: URL

    init() throws {
        let path = try #require(
            ProcessInfo.processInfo.environment["MACWSLD_PATH"],
            "MACWSLD_PATH must point to the signed macwsld; scripts/integration-test.sh sets it.")
        macwsld = URL(filePath: path)
        try #require(
            FileManager.default.isExecutableFile(atPath: path), "\(path) is not an executable.")
        try #require(
            Self.hasVirtualizationEntitlement(path),
            "\(path) is not signed with the virtualization entitlement. Run scripts/sign-dev.sh.")
    }

    @Test func bootsAndPowersOff() async throws {
        let run = try DebugBootProcess(
            macwsld, ["--cmdline", "macwsl.test=poweroff", "--timeout", "30"])
        let result = await run.waitForExit(timeout: .seconds(60))

        #expect(result.status == 0, "\(result.output)")
        #expect(result.lines.contains(where: Self.isBanner), "\(result.output)")
        #expect(
            result.lines.contains { $0.hasPrefix("boot: banner after ") && $0.hasSuffix(" ms") })
        #expect(result.lines.contains("macwsl-initramfs: poweroff"))
        let stoppedAfter = try #require(
            result.milliseconds(after: "debug-boot: vm: stopped after "))
        #expect(stoppedAfter < 10_000, "The VM took \(stoppedAfter) ms to stop.")
    }

    @Test func stopsARunningGuestAndLogsHow() async throws {
        let run = try DebugBootProcess(macwsld, ["--timeout", "120"])
        let bannerSeen = await run.waitForLine(where: Self.isBanner, timeout: .seconds(60))
        try #require(bannerSeen, "The banner did not appear: \(run.output)")

        run.signal(SIGTERM)
        let result = await run.waitForExit(timeout: .seconds(60))

        #expect(result.status == 128 + SIGTERM, "\(result.output)")
        let outcome = try #require(result.lines.first { $0.hasPrefix("debug-boot: shutdown: ") })
        #expect(outcome.contains("shutdown: clean") || outcome.contains("shutdown: forced"))

        // The console log records how the virtual machine was shut down.
        let logPath = try #require(
            result.lines.first { $0.hasPrefix("debug-boot: console log: ") }?
                .dropFirst("debug-boot: console log: ".count))
        let log = try String(contentsOfFile: String(logPath), encoding: .utf8)
        let lastShutdown = try #require(
            DebugBootProcess.lines(of: log).last {
                $0.hasPrefix("[macwsld] ") && $0.contains(" shutdown: ")
            })
        #expect(
            lastShutdown.contains("shutdown: clean") || lastShutdown.contains("shutdown: forced"))
    }

    @Test func attachesASparseDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "macwsl-integration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = directory.appending(path: "disk.img")

        let run = try DebugBootProcess(
            macwsld,
            [
                "--disk", disk.path(percentEncoded: false), "--create-disk", "64M",
                "--cmdline", "macwsl.test=lsblk macwsl.test=poweroff", "--timeout", "30",
            ])
        let result = await run.waitForExit(timeout: .seconds(60))

        #expect(result.status == 0, "\(result.output)")
        #expect(result.lines.contains("/dev/vda"), "\(result.output)")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: disk.path(percentEncoded: false))
        #expect((attributes[.size] as? UInt64) == 64 << 20)
    }

    @Test func refusesInteractiveModeWithoutATerminal() async throws {
        let run = try DebugBootProcess(macwsld, ["--interactive"])
        let result = await run.waitForExit(timeout: .seconds(30))

        #expect(result.status == 1)
        #expect(
            result.lines.first
                == "macwsl: --interactive needs a terminal, but standard input is not a terminal.")
        #expect(!result.output.contains("console log:"), "It must fail before preparing the VM.")
    }

    // MARK: Interactive sessions

    @Test func detachesWithTildeDotOnAnyKeyboardLayout() async throws {
        let session = try InteractiveSession(macwsld, [])
        #expect(
            await session.waitForOutput(
                containing: "type ~. at the start of a line or press Ctrl-]. Type ~? for help."))
        try #require(await session.waitForOutput(containing: "~ # "), "\(session.output)")

        session.type("uname -a\r")
        #expect(await session.waitForOutput(containing: "Linux (none) 6.18"))
        #expect(await session.waitForOutput(containing: "~ # ", count: 2))

        // "~." in the middle of a line is ordinary input: echoed once, printed once.
        session.type("echo a~.b\r")
        #expect(await session.waitForOutput(containing: "a~.b", count: 2))
        #expect(await session.waitForOutput(containing: "~ # ", count: 3))

        // "~~" at the start of a line sends a single "~".
        session.type("~~echo\r")
        #expect(await session.waitForOutput(containing: "~echo: not found"))
        #expect(await session.waitForOutput(containing: "~ # ", count: 4))

        session.type("~?")
        #expect(await session.waitForOutput(containing: "~.  stop the virtual machine and detach"))

        session.type("~.")
        let status = await session.waitForExit(timeout: .seconds(30))
        #expect(status == 0, "\(session.output)")
        #expect(session.output.contains("debug-boot: shutdown: "))
        #expect(session.terminalIsRestored, "The terminal attributes differ after the session.")
    }

    @Test func detachesWithTheDefaultDetachKey() async throws {
        let session = try InteractiveSession(macwsld, [])
        try #require(await session.waitForOutput(containing: "~ # "), "\(session.output)")

        // Ctrl-C goes to the guest's shell, which prints ^C and a new prompt.
        session.type([0x03])
        #expect(await session.waitForOutput(containing: "^C"))
        #expect(await session.waitForOutput(containing: "~ # ", count: 2))

        session.type([0x1D])
        let status = await session.waitForExit(timeout: .seconds(30))
        #expect(status == 0, "\(session.output)")
        #expect(session.terminalIsRestored, "The terminal attributes differ after the session.")
    }

    @Test func detachesWithAChosenDetachKey() async throws {
        let session = try InteractiveSession(macwsld, ["--detach-key", "^Q"])
        #expect(await session.waitForOutput(containing: "or press Ctrl-Q."))
        try #require(await session.waitForOutput(containing: "~ # "), "\(session.output)")

        // With another detach key, Ctrl-] is ordinary input.
        session.type([0x1D])
        try await Task.sleep(for: .seconds(1))
        #expect(session.isRunning, "Ctrl-] detached although the detach key is Ctrl-Q.")

        session.type([0x11])
        let status = await session.waitForExit(timeout: .seconds(30))
        #expect(status == 0, "\(session.output)")
        #expect(session.terminalIsRestored, "The terminal attributes differ after the session.")
    }

    static func isBanner(_ line: String) -> Bool {
        line.hasPrefix("macwsl-initramfs ") && line.contains(" kernel=")
    }

    static func hasVirtualizationEntitlement(_ path: String) -> Bool {
        let codesign = Process()
        codesign.executableURL = URL(filePath: "/usr/bin/codesign")
        codesign.arguments = ["--display", "--entitlements", "-", path]
        let output = Pipe()
        codesign.standardOutput = output
        codesign.standardError = output
        guard (try? codesign.run()) != nil else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        codesign.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains("com.apple.security.virtualization")
    }
}

/// `macwsld debug-boot` running as a subprocess. Standard output and standard error are
/// collected together, or separately with `separateStandardError`. Standard input is
/// `standardInput`, or end-of-file.
final class DebugBootProcess: @unchecked Sendable {
    struct Result {
        let status: Int32
        let output: String
        /// Standard error, when it is collected separately; otherwise empty.
        var standardError = ""
        /// The output's lines. The guest console ends lines with "\r\n", which Swift treats
        /// as a single Character, so lines are split on any newline character.
        var lines: [String] {
            DebugBootProcess.lines(of: output)
        }

        /// The number in a line of the form `<prefix><n> ms`.
        func milliseconds(after prefix: String) -> Int? {
            lines.first { $0.hasPrefix(prefix) }
                .flatMap { Int($0.dropFirst(prefix.count).split(separator: " ").first ?? "") }
        }
    }

    private let process = Process()
    private let collected = OSAllocatedUnfairLock(initialState: Data())
    private let collectedError = OSAllocatedUnfairLock(initialState: Data())

    init(
        _ macwsld: URL, _ arguments: [String], standardInput: Data? = nil,
        separateStandardError: Bool = false, environment: [String: String]? = nil
    ) throws {
        let pipe = Pipe()
        process.executableURL = macwsld
        process.arguments = ["debug-boot"] + arguments
        if let environment {
            process.environment = environment
        }
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [collected] handle in
            let data = handle.availableData
            collected.withLock { $0.append(data) }
        }
        if separateStandardError {
            let errorPipe = Pipe()
            process.standardError = errorPipe
            errorPipe.fileHandleForReading.readabilityHandler = { [collectedError] handle in
                let data = handle.availableData
                collectedError.withLock { $0.append(data) }
            }
        } else {
            process.standardError = pipe
        }
        let inputPipe = standardInput.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        try process.run()
        if let inputPipe, let standardInput {
            try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
            try inputPipe.fileHandleForWriting.close()
        }
    }

    var output: String {
        collected.withLock { String(decoding: $0, as: UTF8.self) }
    }

    var standardError: String {
        collectedError.withLock { String(decoding: $0, as: UTF8.self) }
    }

    func signal(_ number: Int32) {
        kill(process.processIdentifier, number)
    }

    /// Waits until a line of output satisfies `predicate`. Returns whether one did.
    func waitForLine(where predicate: (String) -> Bool, timeout: Duration) async -> Bool {
        await waitForLine(in: \.output, where: predicate, timeout: timeout)
    }

    /// Waits until a line of `stream` (`\.output` or `\.standardError`) satisfies `predicate`.
    func waitForLine(
        in stream: KeyPath<DebugBootProcess, String>, where predicate: (String) -> Bool,
        timeout: Duration
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if Self.lines(of: self[keyPath: stream]).contains(where: predicate) {
                return true
            }
            if !process.isRunning {
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return Self.lines(of: self[keyPath: stream]).contains(where: predicate)
    }

    /// Splits `text` into lines and removes ANSI escape sequences: the guest's busybox colors
    /// the output of `ls` on its console.
    static func lines(of text: String) -> [String] {
        text.replacing(/\u{1B}\[[0-9;]*[A-Za-z]/, with: "")
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
    }

    /// Waits for the process to exit. After `timeout`, kills it and reports status -1.
    func waitForExit(timeout: Duration) async -> Result {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return Result(status: -1, output: output + "\n[test] killed after the timeout\n")
        }
        // Collect output written just before the exit.
        try? await Task.sleep(for: .milliseconds(100))
        return Result(
            status: process.terminationStatus, output: output, standardError: standardError)
    }
}

/// `macwsld debug-boot --interactive` (or `--shell`) running on a pseudo-terminal, which the test
/// drives like a user at a keyboard: bytes written to the primary side arrive as typed input.
final class InteractiveSession: @unchecked Sendable {
    private let process = Process()
    private let primary: Int32
    private let secondary: Int32
    private let primaryHandle: FileHandle
    private let collected = OSAllocatedUnfairLock(initialState: Data())
    private let initialAttributes: termios

    init(
        _ macwsld: URL, _ arguments: [String], mode: String = "--interactive",
        rows: UInt16 = 0, columns: UInt16 = 0
    ) throws {
        var primary: Int32 = -1
        var secondary: Int32 = -1
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &secondary, nil, nil, &size) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.primary = primary
        self.secondary = secondary
        var attributes = termios()
        tcgetattr(secondary, &attributes)
        initialAttributes = attributes

        let terminal = FileHandle(fileDescriptor: secondary, closeOnDealloc: false)
        process.executableURL = macwsld
        process.arguments = ["debug-boot", mode] + arguments
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        primaryHandle = FileHandle(fileDescriptor: primary, closeOnDealloc: false)
        primaryHandle.readabilityHandler = { [collected] handle in
            let data = handle.availableData
            collected.withLock { $0.append(data) }
        }
        try process.run()
    }

    deinit {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        primaryHandle.readabilityHandler = nil
        close(primary)
        close(secondary)
    }

    var output: String {
        collected.withLock { String(decoding: $0, as: UTF8.self) }
    }

    var isRunning: Bool { process.isRunning }

    /// Changes the terminal's window size and sends SIGWINCH to debug-boot, as a terminal
    /// emulator does. The pseudo-terminal is not debug-boot's controlling terminal, so the
    /// kernel does not send the signal itself.
    func resize(rows: UInt16, columns: UInt16) {
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(primary, TIOCSWINSZ, &size)
        kill(process.processIdentifier, SIGWINCH)
    }

    func type(_ text: String) {
        type(Array(text.utf8))
    }

    func type(_ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { write(primary, $0.baseAddress, $0.count) }
    }

    /// Waits until `text` has appeared `count` times in the output. Returns whether it did.
    func waitForOutput(
        containing text: String, count: Int = 1, timeout: Duration = .seconds(30)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if output.components(separatedBy: text).count - 1 >= count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Waits for the process to exit and returns its status, or `nil` after `timeout`.
    func waitForExit(timeout: Duration) async -> Int32? {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return process.isRunning ? nil : process.terminationStatus
    }

    /// Whether the terminal's attributes are the same as before the session started.
    var terminalIsRestored: Bool {
        var current = termios()
        tcgetattr(secondary, &current)
        let initial = initialAttributes
        return current.c_iflag == initial.c_iflag && current.c_oflag == initial.c_oflag
            && current.c_cflag == initial.c_cflag && current.c_lflag == initial.c_lflag
            && current.c_ispeed == initial.c_ispeed && current.c_ospeed == initial.c_ospeed
            && withUnsafeBytes(of: current.c_cc) { currentCC in
                withUnsafeBytes(of: initial.c_cc) { currentCC.elementsEqual($0) }
            }
    }
}
