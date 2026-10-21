import Foundation

/// A working directory reported by OSC 7: `ESC ] 7 ; file://<host>/<path> BEL`.
public struct OSC7Location: Hashable, Sendable {
    /// The host name from the URL, or `nil` if it was empty.
    public var host: String?
    /// The absolute path, percent-decoded.
    public var path: String

    /// Parses the URL a shell sends with OSC 7. Accepts `file` URLs with an absolute path and
    /// an empty, `localhost`, or named host. Returns `nil` for anything else.
    public init?(parsing text: String) {
        guard let components = URLComponents(string: text),
            components.scheme?.lowercased() == "file"
        else { return nil }
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.path
        guard path.hasPrefix("/") else { return nil }
        let host = components.percentEncodedHost?.removingPercentEncoding ?? components.host
        self.host = (host?.isEmpty ?? true) ? nil : host
        self.path = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Whether the location refers to this Mac: no host, `localhost`, or one of `localNames`.
    public func isLocal(localNames: Set<String>) -> Bool {
        guard let host = host?.lowercased() else { return true }
        if host == "localhost" { return true }
        return localNames.contains { name in
            let name = name.lowercased()
            // Shells send either the full name or the first label (`mbp` for `mbp.local`).
            return host == name || host == name.split(separator: ".").first.map(String.init)
        }
    }
}

/// Decides where a session's working directory comes from, and when to poll for it.
///
/// OSC 7 is preferred whenever the shell reports it. A shell that never does, such as the stock
/// macOS zsh outside Terminal.app, gets its directory from `proc_pidinfo` instead, polled only
/// while the session is visible, at most once per `minimumInterval`, and only after its output
/// has been idle for `idleDelay`, so that busy output is not slowed down.
public struct WorkingDirectoryTracker: Hashable, Sendable {
    public static let minimumInterval: Duration = .seconds(1)
    public static let idleDelay: Duration = .milliseconds(300)

    public private(set) var directory: String?
    /// Whether the shell has reported OSC 7. From then on, polling stops.
    public private(set) var reportsOSC7 = false
    private var lastPoll: ContinuousClock.Instant?
    private var lastOutput: ContinuousClock.Instant?

    public init() {}

    /// Records an OSC 7 report. Returns `true` if the directory changed.
    @discardableResult
    public mutating func reported(_ path: String) -> Bool {
        reportsOSC7 = true
        return set(path)
    }

    /// Records that the session produced output at `now`.
    public mutating func outputArrived(at now: ContinuousClock.Instant) {
        lastOutput = now
    }

    /// Whether to poll the process's directory now.
    public func shouldPoll(at now: ContinuousClock.Instant, isVisible: Bool) -> Bool {
        guard isVisible, !reportsOSC7 else { return false }
        if let lastPoll, now - lastPoll < Self.minimumInterval { return false }
        if let lastOutput, now - lastOutput < Self.idleDelay { return false }
        return true
    }

    /// Records a poll result. A failed poll (`nil`) keeps the last known directory. Returns
    /// `true` if the directory changed.
    @discardableResult
    public mutating func polled(_ path: String?, at now: ContinuousClock.Instant) -> Bool {
        lastPoll = now
        guard !reportsOSC7, let path else { return false }
        return set(path)
    }

    private mutating func set(_ path: String) -> Bool {
        guard path != directory else { return false }
        directory = path
        return true
    }
}

/// Formats a directory for titles: the home directory as `~`, as shells do.
public func abbreviatingHome(_ path: String, home: String = NSHomeDirectory()) -> String {
    guard !home.isEmpty else { return path }
    if path == home { return "~" }
    let prefix = home.hasSuffix("/") ? home : home + "/"
    return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
}
