import Foundation

extension Profile {
    /// A new session of this profile, not yet started. The window asks the session layer for
    /// it, so that nothing outside `Session/` knows which kind of session a pane runs.
    @MainActor
    func makeSession() -> any TerminalSession {
        switch kind {
        case .localShell(let shell):
            LocalShellSession(shell: shell)
        }
    }
}
