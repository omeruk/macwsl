#if os(macOS)
    import os

    extension Logger {
        static let xpc = Logger(subsystem: "dev.maw", category: "xpc")
    }
#endif
