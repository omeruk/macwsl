import Darwin
import Foundation
import MawClient
import MawCore
import MawProtocol
import os

/// What `LinuxSession` needs from the core of a Linux session, `DistributionSession`, so that
/// tests can replace it.
protocol LinuxSessionCore: AnyObject, Sendable {
    /// Opens the session and starts the shell. Returns the stored name of the distribution it
    /// opened, or `nil` if it ended first.
    func openShell() async -> String?
    func send(_ bytes: some Collection<UInt8>)
    func resize(_ size: MawProtocol.TerminalSize)
    func foregroundProgram(within timeout: Duration) async -> ForegroundAnswer
    func hangUp()
    func waitForEnding() async -> DistributionSession.Ending
}

extension DistributionSession: LinuxSessionCore {
    func openShell() async -> String? {
        await open()?.info.machine.name
    }
}

/// A login shell in a Linux distribution, opened through the daemon.
///
/// The session holds its machine's lease from its start until it ends or the pane closes;
/// `terminate()` hangs up the guest's shell, which receives SIGHUP, and releases the lease.
/// Output reaches the delegate through an `OutputPump`, which blocks the core's reading thread
/// while it is full, so a flood slows the guest instead of the user interface.
@MainActor
public final class LinuxSession: TerminalSession {
    typealias Ending = DistributionSession.Ending
    typealias MakeCore =
        @MainActor (MawProtocol.TerminalSize, @escaping GuestAgentClient.OutputHandler) ->
        any LinuxSessionCore

    public let id = UUID()
    public weak var delegate: (any TerminalSessionDelegate)?
    public private(set) var isRunning = false
    /// The distribution's stored name, or `linux` while the default one has not opened yet.
    public private(set) var displayName: String

    private let makeCore: MakeCore
    private var core: (any LinuxSessionCore)?
    private var pump: OutputPump<Ending>?
    private var size = TerminalSize.default
    private var tracker = WorkingDirectoryTracker()

    /// - Parameters:
    ///   - distribution: The distribution, or `nil` for the default one, which the daemon
    ///     resolves when the session opens.
    ///   - environment: The app's environment, whose valid `LC_ALL`, `LC_CTYPE`, or `LANG` the
    ///     guest uses if it has it (`ShellLocale.inherited`).
    ///   - locale: The Mac's language and region, for the guest's locale otherwise.
    public convenience init(
        distribution: DistroName?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        locale: Locale = .current
    ) {
        let guestLocale = Self.guestLocale(environment: environment, locale: locale)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        self.init(name: distribution?.rawValue) { terminal, output in
            DistributionSession(
                distribution: distribution, terminal: terminal, locale: guestLocale,
                programVersion: version, output: output)
        }
    }

    init(name: String?, makeCore: @escaping MakeCore) {
        displayName = name ?? "linux"
        self.makeCore = makeCore
    }

    /// The locale the guest should use: the app's own if it is valid, as the local shell keeps
    /// it, and otherwise the Mac's language and region. The agent falls back to `C.UTF-8`
    /// where the distribution lacks it.
    static func guestLocale(environment: [String: String], locale: Locale) -> String? {
        ShellLocale.inherited(environment) ?? DistributionSession.preferredLocale(locale)
    }

    public var workingDirectory: String? {
        tracker.directory
    }

    public func start(size: TerminalSize) throws(TerminalSessionError) {
        guard core == nil else { return }
        self.size = size
        let pump = OutputPump<Ending>()
        let core = makeCore(Self.terminalSize(size)) { _, bytes in pump.write(bytes) }
        self.core = core
        self.pump = pump
        isRunning = true
        Task { [weak self] in
            if let name = await core.openShell() {
                self?.displayName = name
            }
            pump.finish(await core.waitForEnding())
        }
        Task { [weak self] in
            let ending = await pump.deliver { bytes in
                if let self { self.delegate?.session(self, didReceive: bytes) }
            }
            if let ending, let self, self.core === core {
                self.ended(ending)
            }
        }
    }

    private func ended(_ ending: Ending) {
        isRunning = false
        switch ending {
        case .exited(let status):
            delegate?.session(self, didTerminateWith: Self.terminationStatus(status))
        case .failed(let error):
            Logger.session.info("A Linux session failed: \(error.description, privacy: .public)")
            delegate?.session(self, didFailWith: TerminalSessionError(error))
        case .hungUp:
            break
        }
    }

    public func send(_ bytes: ArraySlice<UInt8>) {
        core?.send(bytes)
    }

    public func resize(to size: TerminalSize) {
        guard size != self.size else { return }
        self.size = size
        core?.resize(Self.terminalSize(size))
    }

    /// Hangs the guest's shell up and releases the lease. Returns at once.
    public func terminate() {
        guard isRunning, let core else { return }
        core.hangUp()
        pump?.close()
        isRunning = false
    }

    // Asked only through `foregroundProgram(within:)`, which waits for the guest.
    public var hasForegroundProcess: Bool { false }
    public var foregroundProcessName: String? { nil }

    public func foregroundProgram(within timeout: Duration) async -> ForegroundReport {
        guard isRunning, let core else { return .none }
        switch await core.foregroundProgram(within: timeout) {
        case .none: return .none
        case .program(_, let name): return .program(name: name)
        case .noAnswer: return .noAnswer
        }
    }

    public func terminalReportedTitle(_ title: String) {
        delegate?.session(self, didChangeTitle: title)
    }

    /// The only source of the directory: the guest's file system is not this Mac's, so the
    /// URL's host is not checked, and nothing is polled.
    public func terminalReportedWorkingDirectory(_ url: String) {
        guard let location = OSC7Location(parsing: url) else { return }
        if tracker.reported(location.path) {
            delegate?.session(self, didChangeWorkingDirectory: location.path)
        }
    }

    public func refresh(isVisible: Bool) {}

    // MARK: Conversions

    static func terminalSize(_ size: TerminalSize) -> MawProtocol.TerminalSize {
        MawProtocol.TerminalSize(
            rows: UInt16(clamping: size.rows), columns: UInt16(clamping: size.columns))
    }

    /// The status with the signal renumbered from Linux to this Mac, through its name.
    static func terminationStatus(_ status: ExitStatus) -> TerminationStatus {
        switch status {
        case .exited(let code):
            return .exited(code)
        case .signaled(let number):
            guard let name = Signal(linuxNumber: number)?.rawValue.lowercased() else {
                return .unknown
            }
            var names = sys_signame
            let host = withUnsafeBytes(of: &names) { table in
                table.bindMemory(to: UnsafePointer<CChar>?.self).firstIndex { entry in
                    entry.map { String(cString: $0) } == name
                }
            }
            return host.map { .signaled(Int32($0)) } ?? .unknown
        }
    }
}
