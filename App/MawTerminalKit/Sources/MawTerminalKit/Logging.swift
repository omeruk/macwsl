import os

// The subsystem stays dev.macwsl until the project is renamed in a separate pull request.
extension Logger {
    static let app = Logger(subsystem: "dev.macwsl", category: "terminal-app")
    static let session = Logger(subsystem: "dev.macwsl", category: "terminal-session")
    static let settings = Logger(subsystem: "dev.macwsl", category: "terminal-settings")
}
