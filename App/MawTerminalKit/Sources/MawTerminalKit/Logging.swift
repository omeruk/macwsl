import os

// The project's logging subsystem, shared with the daemon and the CLI (CLAUDE.md).
extension Logger {
    static let app = Logger(subsystem: "dev.maw", category: "terminal-app")
    static let session = Logger(subsystem: "dev.maw", category: "terminal-session")
    static let settings = Logger(subsystem: "dev.maw", category: "terminal-settings")
}
