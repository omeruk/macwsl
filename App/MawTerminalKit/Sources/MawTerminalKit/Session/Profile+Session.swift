import Foundation
import MawCore

extension Profile {
    /// Makes the core of a Linux session for a distribution, or for the default one with `nil`.
    typealias LinuxCores = @MainActor (DistroName?) -> LinuxSession.MakeCore

    /// A new session of this profile, not yet started. The window asks the session layer for
    /// it, so that nothing outside `Session/` knows which kind of session a pane runs.
    ///
    /// The fallbacks follow the opening's errors, so that ⌘T needs no list from the daemon:
    /// - A named distribution that is not installed opens the default distribution, whose
    ///   pane says which one it opened.
    /// - With no distribution or no daemon installed, a Linux tab opens the local shell and
    ///   says why.
    /// - Every other failure shows the error in the Linux pane, never the local shell.
    ///
    /// - Parameters:
    ///   - localShell: The local shell's profile, the fallback with nothing installed.
    ///   - cores: The cores of Linux sessions. Tests pass fake ones.
    @MainActor
    func makeSession(
        localShell: Profile,
        cores: @escaping LinuxCores = { LinuxSession.daemonCore(distribution: $0) }
    ) -> any TerminalSession {
        switch kind {
        case .localShell(let shell):
            return LocalShellSession(shell: shell)
        case .defaultDistribution:
            return Self.defaultDistributionSession(localShell: localShell, cores: cores)
        case .distribution(let name):
            let notice: @MainActor @Sendable (String) -> String = { stored in
                "\(name) is not installed. This tab opened \(stored), the default distribution.\n"
            }
            // A name that is not valid cannot be installed.
            guard let distribution = try? DistroName(name) else {
                return Self.defaultDistributionSession(
                    localShell: localShell, cores: cores, openingNotice: notice)
            }
            return LinuxSession(
                name: name,
                fallback: { error in
                    guard case .distributionNotInstalled = error else {
                        return Self.localShellFallback(for: error, localShell: localShell)
                    }
                    return LinuxSession.Fallback(
                        replacement: Self.defaultDistributionSession(
                            localShell: localShell, cores: cores, openingNotice: notice),
                        notice: nil)
                }, makeCore: cores(distribution))
        }
    }

    @MainActor
    private static func defaultDistributionSession(
        localShell: Profile, cores: @escaping LinuxCores,
        openingNotice: (@MainActor (String) -> String)? = nil
    ) -> LinuxSession {
        LinuxSession(
            name: nil, openingNotice: openingNotice,
            fallback: { localShellFallback(for: $0, localShell: localShell) },
            makeCore: cores(nil))
    }

    /// The local shell, when `error` says that no distribution or no daemon is installed.
    @MainActor
    private static func localShellFallback(for error: MawError, localShell: Profile)
        -> LinuxSession.Fallback?
    {
        guard let notice = LinuxSession.fallbackNotice(for: error) else { return nil }
        return LinuxSession.Fallback(
            replacement: localShell.makeSession(localShell: localShell), notice: notice)
    }
}
