#if os(macOS)
    import os

    /// Virtualization.framework wrappers. VM configuration and lifecycle arrive in phase 03.
    extension Logger {
        static let virtualization = Logger(subsystem: "dev.maw", category: "virtualization")
    }
#endif
