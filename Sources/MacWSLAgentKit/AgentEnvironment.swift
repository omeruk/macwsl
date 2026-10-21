#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// The environment of the processes the agent starts.
///
/// busybox `init` starts the agent with an almost empty environment, and the agent does not
/// pass its own on. Every session starts from `defaults`, and the request's variables are
/// applied on top.
public enum AgentEnvironment {
    public static let defaults: [String: String] = [
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME": "/root",
        "SHELL": "/bin/sh",
    ]

    /// `defaults` with `additions` applied on top.
    public static func merged(
        _ additions: [String: String], defaults: [String: String] = defaults
    ) -> [String: String] {
        defaults.merging(additions) { _, addition in addition }
    }
}

/// Facts about the system the agent runs on, for `info`.
enum SystemInfo {
    /// `uname -r`.
    static func kernelRelease() -> String {
        var names = utsname()
        guard uname(&names) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &names.release) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Time since boot, including time suspended where the platform counts it.
    static func uptimeMilliseconds() -> UInt64 {
        var time = timespec()
        #if os(Linux)
            let clock = CLOCK_BOOTTIME
        #else
            let clock = CLOCK_MONOTONIC
        #endif
        guard clock_gettime(clock, &time) == 0 else { return 0 }
        return UInt64(time.tv_sec) * 1_000 + UInt64(time.tv_nsec) / 1_000_000
    }
}
