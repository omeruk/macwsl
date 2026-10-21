import Darwin
import Foundation
import SwiftTerm
import os

/// The user's login shell on this Mac, on a pseudo-terminal, through SwiftTerm's `LocalProcess`.
///
/// `LocalProcess` delivers output on the main queue in time-limited batches, and stops reading
/// from the pseudo-terminal while more than a few megabytes are waiting. A flood such as
/// `yes | head -n 2000000` therefore blocks the writer instead of the user interface.
@MainActor
public final class LocalShellSession: TerminalSession {
    public let id = UUID()
    public let shell: String
    public weak var delegate: (any TerminalSessionDelegate)?
    public private(set) var isRunning = false

    private var process: LocalProcess?
    private var size = TerminalSize.default
    private var tracker = WorkingDirectoryTracker()
    private let startDirectory: String
    private let baseEnvironment: [String: String]
    private let locale: Locale

    /// - Parameters:
    ///   - shell: The shell's path, such as `/bin/zsh`. It runs as a login shell.
    ///   - startDirectory: Where the shell starts. Defaults to the home directory.
    ///   - baseEnvironment: The environment the shell's is derived from: the app's own.
    ///   - locale: The user's locale, for choosing `LANG` when the environment has no valid one.
    public init(
        shell: String, startDirectory: String = NSHomeDirectory(),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        locale: Locale = .current
    ) {
        self.shell = shell
        self.startDirectory = startDirectory
        self.baseEnvironment = baseEnvironment
        self.locale = locale
    }

    public var displayName: String {
        (shell as NSString).lastPathComponent
    }

    public var workingDirectory: String? {
        tracker.directory
    }

    public func start(size: TerminalSize) throws(TerminalSessionError) {
        guard !isRunning else { return }
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            throw .programNotFound(path: shell)
        }
        self.size = size
        let process = LocalProcess(delegate: self, dispatchQueue: .main)
        self.process = process
        // A leading dash in argv[0] makes the shell a login shell, as Terminal.app starts it.
        process.startProcess(
            executable: shell, args: [],
            environment: Self.environment(from: baseEnvironment, locale: locale),
            execName: "-" + displayName, currentDirectory: startDirectory)
        guard process.running else {
            self.process = nil
            throw .startFailed(reason: "the pseudo-terminal for \(shell) could not be created")
        }
        isRunning = true
        Logger.session.info(
            "Started \(self.shell, privacy: .public) as process \(process.shellPid)")
    }

    public func send(_ bytes: ArraySlice<UInt8>) {
        process?.send(data: bytes)
    }

    public func resize(to size: TerminalSize) {
        guard size != self.size else { return }
        self.size = size
        guard let process, process.running else { return }
        var windowSize = Self.windowSize(size)
        _ = PseudoTerminalHelpers.setWinSize(
            masterPtyDescriptor: process.childfd, windowSize: &windowSize)
    }

    public func terminate() {
        guard let process, isRunning else { return }
        // SIGHUP, as when a terminal closes: the shell passes it on to its jobs.
        kill(process.shellPid, SIGHUP)
        process.terminate()
        isRunning = false
    }

    public var hasForegroundProcess: Bool {
        guard let group = foregroundProcessGroup, let process else { return false }
        return group != process.shellPid
    }

    public var foregroundProcessName: String? {
        guard let group = foregroundProcessGroup else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        let length = proc_name(group, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return Self.string(fromCString: buffer)
    }

    public func terminalReportedTitle(_ title: String) {
        delegate?.session(self, didChangeTitle: title)
    }

    public func terminalReportedWorkingDirectory(_ url: String) {
        guard let location = OSC7Location(parsing: url),
            location.isLocal(localNames: Self.localHostNames)
        else { return }
        if tracker.reported(location.path) {
            delegate?.session(self, didChangeWorkingDirectory: location.path)
        }
    }

    public func refresh(isVisible: Bool) {
        let now = ContinuousClock.now
        guard isRunning, tracker.shouldPoll(at: now, isVisible: isVisible) else { return }
        let pid = foregroundProcessGroup ?? process?.shellPid
        let directory = pid.flatMap(Self.workingDirectory(of:))
        if tracker.polled(directory, at: now), let directory {
            delegate?.session(self, didChangeWorkingDirectory: directory)
        }
    }

    // MARK: Process details

    /// The foreground process group of the terminal, which is the shell's own group while the
    /// shell waits at its prompt.
    private var foregroundProcessGroup: pid_t? {
        guard let process, process.running, process.childfd >= 0 else { return nil }
        let group = tcgetpgrp(process.childfd)
        return group > 0 ? group : nil
    }

    /// The current directory of `pid`, from `proc_pidinfo`. `nil` if the process is gone or
    /// belongs to another user.
    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    private static let localHostNames: Set<String> = {
        var names: Set<String> = [ProcessInfo.processInfo.hostName]
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            names.insert(string(fromCString: buffer))
        }
        return names
    }()

    /// The environment for the shell: the app's own, without variables that only make sense
    /// for the app process, plus the terminal's identity and a UTF-8 locale (`ShellLocale`).
    static func environment(from base: [String: String], locale: Locale) -> [String] {
        let dropped = ["DYLD_", "__XPC_", "XPC_", "OS_ACTIVITY_", "__CF", "NSZombie"]
        var environment = base.filter { key, _ in
            !dropped.contains { key.hasPrefix($0) }
        }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "maw"
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            environment["TERM_PROGRAM_VERSION"] = version
        }
        environment = ShellLocale.environment(environment, locale: locale)
        return environment.map { "\($0)=\($1)" }.sorted()
    }

    /// The text before the first NUL of a C string buffer.
    private static func string(fromCString buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func windowSize(_ size: TerminalSize) -> winsize {
        winsize(
            ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.columns),
            ws_xpixel: 0, ws_ypixel: 0)
    }
}

// LocalProcess calls its delegate on the queue it was given, which is the main queue. The
// conformance is isolated to the main actor and checked at run time.
extension LocalShellSession: @preconcurrency LocalProcessDelegate {
    public func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        guard source === process else { return }
        isRunning = false
        // LocalProcess passes the raw status from waitpid.
        let status = exitCode.map(TerminationStatus.init(waitStatus:)) ?? .unknown
        Logger.session.info(
            "\(self.shell, privacy: .public) \(status.description, privacy: .public)")
        delegate?.session(self, didTerminateWith: status)
    }

    public func dataReceived(slice: ArraySlice<UInt8>) {
        tracker.outputArrived(at: .now)
        delegate?.session(self, didReceive: slice)
    }

    public func getWindowSize() -> winsize {
        Self.windowSize(size)
    }
}
