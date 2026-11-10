import Darwin
import Foundation
import MawClient
import MawCore
import MawProtocol
import Observation
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
///
/// It is observable, so that views that show `displayName` follow it from `linux` to the
/// distribution's name once the default distribution has opened.
@MainActor @Observable
public final class LinuxSession: TerminalSession {
    typealias Ending = DistributionSession.Ending
    typealias MakeCore =
        @MainActor (MawProtocol.TerminalSize, @escaping GuestAgentClient.OutputHandler) ->
        any LinuxSessionCore

    /// What a tab opens instead of a session that could not open, and the dim notice that
    /// says why, in lines that end in a line feed.
    public struct Fallback {
        public var replacement: any TerminalSession
        public var notice: String?

        public init(replacement: any TerminalSession, notice: String?) {
            self.replacement = replacement
            self.notice = notice
        }
    }

    /// Chooses the fallback for the error that ended the opening, or `nil` to show the error.
    public typealias FallBack = @MainActor (MawError) -> Fallback?

    public let id = UUID()
    @ObservationIgnored public weak var delegate: (any TerminalSessionDelegate)?
    @ObservationIgnored public private(set) var isRunning = false
    /// The distribution's stored name, or `linux` while the default one has not opened yet.
    public private(set) var displayName: String

    @ObservationIgnored private let makeCore: MakeCore
    @ObservationIgnored private let fallback: FallBack?
    @ObservationIgnored private let openingNotice: (@MainActor (String) -> String)?
    /// The distribution's stored name once the session has opened.
    @ObservationIgnored private var openedName: String?
    @ObservationIgnored private var core: (any LinuxSessionCore)?
    @ObservationIgnored private var pump: OutputPump<Ending>?
    @ObservationIgnored private var size = TerminalSize.default
    @ObservationIgnored private var tracker = WorkingDirectoryTracker()

    /// - Parameters:
    ///   - distribution: The distribution, or `nil` for the default one, which the daemon
    ///     resolves when the session opens.
    ///   - environment: The app's environment, whose valid `LC_ALL`, `LC_CTYPE`, or `LANG` the
    ///     guest uses if it has it (`ShellLocale.inherited`).
    ///   - locale: The Mac's language and region, for the guest's locale otherwise.
    ///   - openingNotice: The notice the pane shows, given the stored name, once the session
    ///     has opened and before its output.
    ///   - fallback: What the tab opens instead when the session cannot open.
    public convenience init(
        distribution: DistroName?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        locale: Locale = .current, openingNotice: (@MainActor (String) -> String)? = nil,
        fallback: FallBack? = nil
    ) {
        self.init(
            name: distribution?.rawValue, openingNotice: openingNotice, fallback: fallback,
            makeCore: Self.daemonCore(
                distribution: distribution, environment: environment, locale: locale))
    }

    init(
        name: String?, openingNotice: (@MainActor (String) -> String)? = nil,
        fallback: FallBack? = nil, makeCore: @escaping MakeCore
    ) {
        displayName = name ?? "linux"
        self.openingNotice = openingNotice
        self.fallback = fallback
        self.makeCore = makeCore
    }

    /// The core that opens `distribution`, or the default one for `nil`, through the daemon.
    static func daemonCore(
        distribution: DistroName?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        locale: Locale = .current
    ) -> MakeCore {
        let guestLocale = guestLocale(environment: environment, locale: locale)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return { terminal, output in
            DistributionSession(
                distribution: distribution, terminal: terminal, locale: guestLocale,
                programVersion: version, output: output)
        }
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
        Task { pump.finish(await core.waitForEnding()) }
        // Output waits until the session has opened, so that the opening notice comes first.
        // The pump holds it meanwhile; the core delivers output only after the shell started.
        Task { [weak self] in
            if let name = await core.openShell(), let self, self.core === core {
                self.opened(name)
            }
            let ending = await pump.deliver { bytes in
                if let self { self.delegate?.session(self, didReceive: bytes) }
            }
            if let ending, let self, self.core === core {
                self.ended(ending)
            }
        }
    }

    private func opened(_ name: String) {
        displayName = name
        openedName = name
        if let openingNotice {
            delegate?.session(self, didNotice: openingNotice(name))
        }
    }

    /// The distribution that the session opened, by its stored name, so that a split opens
    /// the same one even after the default changes.
    public var splitProfile: Profile? {
        openedName.map(Profile.distribution)
    }

    private func ended(_ ending: Ending) {
        isRunning = false
        switch ending {
        case .exited(let status):
            delegate?.session(self, didTerminateWith: Self.terminationStatus(status))
        case .failed(let error):
            Logger.session.info("A Linux session failed: \(error.description, privacy: .public)")
            if let chosen = fallback?(error) {
                delegate?.session(self, didFallBackTo: chosen.replacement, notice: chosen.notice)
            } else {
                delegate?.session(
                    self,
                    didFailWith: .failed(
                        message: error.description, suggestion: Self.suggestion(for: error)))
            }
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

    /// The status with the signal renumbered from Linux to this Mac.
    static func terminationStatus(_ status: ExitStatus) -> TerminationStatus {
        switch status {
        case .exited(let code): .exited(code)
        case .signaled(let number):
            Signal(linuxNumber: number).map { .signaled($0.localNumber) } ?? .unknown
        }
    }

    // MARK: Errors in the pane

    /// Why a tab opens the local shell instead, in lines that end in a line feed. Only when no
    /// distribution or no daemon is installed: in every other case a user expects Linux, so the
    /// pane shows the error instead, and never runs a command on the Mac by mistake.
    static func fallbackNotice(for error: MawError) -> String? {
        switch error {
        case .noDistributionInstalled:
            "No Linux distribution is installed, so this tab opened the local shell.\n"
        case .daemonNotInstalled: runtimeErrorText(error)
        default: nil
        }
    }

    /// maw's suggested fix, or the app's own where maw's names a step that does not apply in a
    /// pane: running a command again, where Enter starts a new session; a command's option; a
    /// user that the app never names; or signing `maw` rather than the app.
    static func suggestion(for error: MawError) -> String? {
        switch error {
        case .clientSignatureRejected, .daemonVersionMismatch:
            "Build the app and the daemon from the same commit, the app with Xcode, which signs "
                + "it as dev.maw.app, then run mawd install from that build."
        case .virtualizationEntitlementMissing:
            "Sign the daemon with scripts/sign-dev.sh and run mawd install, so that launchd "
                + "starts the signed build. Then press Enter to start a new session."
        case .machineStopped:
            "Press Enter to start a new session, which starts the virtual machine again."
        case .launchctlTimedOut:
            "launchd did not answer in time. Press Enter to try again; if it still does not "
                + "finish, log out and back in, which restarts your launchd session."
        case .diskImageInUse:
            "A virtual machine of a daemon that stopped may still be exiting; press Enter in a "
                + "moment to try again. Otherwise another process runs it."
        case .sessionDialBackFailed, .sessionDialBackMissing:
            "Press Enter to try again. If it fails again, restart the virtual machines with "
                + "maw --shutdown; the console log in ~/Library/Logs/maw has the agent's warning "
                + "or the connections that were refused."
        case .sessionDialBackBusy:
            "Wait for other sessions to start, then press Enter to try again."
        case .userNotFound(let user, let distribution):
            "Sessions run as the default user, [user] default in /etc/maw.conf. Create the "
                + "user with maw -d \(distribution) -u root -e adduser \(user), or name another "
                + "one there."
        case .guestCommandNotFound:
            "The default user's login shell, which /etc/passwd names, or runuser is missing in "
                + "the distribution. Install it, or give the user another shell with usermod -s, "
                + "as root through maw -d <name> -u root."
        case .diskImageNotFound:
            "Restore the distribution's disk image from a backup, or remove the distribution "
                + "as the README explains and install it again with maw --install."
        default: error.recoverySuggestion
        }
    }
}
