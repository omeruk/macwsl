#if os(macOS)
    import Foundation
    import os

    extension Logger {
        static let daemon = Logger(subsystem: "dev.maw", category: "daemon")
    }

    /// The daemon's log: every line goes to the unified log (subsystem `dev.maw`, category
    /// `daemon`) and, when the executable provides a sink, to `~/Library/Logs/maw/mawd.log`.
    ///
    /// The library never writes to standard error itself; `mawd serve` passes a sink that does,
    /// and launchd sends standard error to the log file.
    public struct DaemonLog: Sendable {
        public typealias Sink = @Sendable (String) -> Void

        private let sink: Sink?

        public init(sink: Sink? = nil) {
            self.sink = sink
        }

        public func notice(_ message: String) {
            Logger.daemon.notice("\(message, privacy: .public)")
            sink?(Self.line(message))
        }

        public func error(_ message: String) {
            Logger.daemon.error("\(message, privacy: .public)")
            sink?(Self.line("error: " + message))
        }

        /// `2026-10-22T09:41:07.123Z mawd: <message>`.
        static func line(_ message: String) -> String {
            let time = Date().formatted(
                .iso8601.year().month().day().time(includingFractionalSeconds: true))
            return "\(time) mawd: \(message)\n"
        }
    }
#endif
