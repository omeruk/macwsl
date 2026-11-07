import os

/// The command-line tool. It reports errors on standard error; the unified log keeps detail
/// that the message leaves out.
extension Logger {
    static let cli = Logger(subsystem: "dev.maw", category: "cli")
}
