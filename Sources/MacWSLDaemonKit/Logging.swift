#if os(macOS)
    import os

    /// Daemon logic and the XPC interface. VM ownership arrives in phase 03.
    extension Logger {
        static let daemon = Logger(subsystem: "dev.macwsl", category: "daemon")
    }
#endif
