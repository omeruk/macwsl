import Foundation

extension Profile {
    /// A new session of this profile, not yet started. The window asks the session layer for
    /// it, so that nothing outside `Session/` knows which kind of session a pane runs.
    ///
    /// - Parameter localShell: The local shell's profile, which a tab of the default
    ///   distribution opens instead when no distribution or no daemon is installed.
    @MainActor
    func makeSession(localShell: Profile) -> any TerminalSession {
        switch kind {
        case .localShell(let shell):
            LocalShellSession(shell: shell)
        case .defaultDistribution:
            LinuxSession(distribution: nil) { localShell.makeSession(localShell: localShell) }
        }
    }
}
