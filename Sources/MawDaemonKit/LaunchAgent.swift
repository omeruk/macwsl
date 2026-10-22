#if os(macOS)
    import Foundation
    import MawCore
    import MawXPC

    /// The per-user LaunchAgent that runs `mawd serve` on demand. `mawd install` writes it to
    /// `~/Library/LaunchAgents/<label>.plist` (docs/decisions/0011-launchctl-registration.md).
    public struct LaunchAgent: Equatable, Sendable {
        /// The launchd label, which also names the Mach service.
        public var label: String
        /// The absolute path of the `mawd` executable.
        public var program: String
        /// Where `mawd.log` and the console logs go.
        public var logDirectory: URL
        /// For the integration tests: a shorter machine idle timeout, in seconds.
        public var machineIdleTimeout: Int?
        /// For the integration tests: a shorter daemon idle timeout, in seconds.
        public var daemonIdleTimeout: Int?
        /// Another image cache, for the integration tests. `nil` is
        /// `~/Library/Caches/maw/images`.
        public var imageCacheDirectory: URL?

        public init(
            label: String = DaemonInterface.defaultLabel, program: String,
            logDirectory: URL = MawPaths().logsDirectory, machineIdleTimeout: Int? = nil,
            daemonIdleTimeout: Int? = nil, imageCacheDirectory: URL? = nil
        ) {
            self.label = label
            self.program = program
            self.logDirectory = logDirectory
            self.machineIdleTimeout = machineIdleTimeout
            self.daemonIdleTimeout = daemonIdleTimeout
            self.imageCacheDirectory = imageCacheDirectory
        }

        /// `mawd serve`, with the options that differ from the defaults.
        public var arguments: [String] {
            var arguments = [program, "serve"]
            if label != DaemonInterface.defaultLabel {
                arguments += ["--label", label]
            }
            if logDirectory.standardizedFileURL != MawPaths().logsDirectory.standardizedFileURL {
                arguments += ["--log-directory", logDirectory.path(percentEncoded: false)]
            }
            if let machineIdleTimeout {
                arguments += ["--machine-idle-timeout", String(machineIdleTimeout)]
            }
            if let daemonIdleTimeout {
                arguments += ["--daemon-idle-timeout", String(daemonIdleTimeout)]
            }
            if let imageCacheDirectory {
                arguments += [
                    "--image-cache-directory", imageCacheDirectory.path(percentEncoded: false),
                ]
            }
            return arguments
        }

        public var logFile: URL {
            logDirectory.appending(path: "mawd.log", directoryHint: .notDirectory)
        }

        /// The property list. launchd starts the program when a client connects to the Mach
        /// service, not at load (`RunAtLoad` is absent), and does not restart it when it exits
        /// (`KeepAlive` is absent): an idle daemon exits, and the next connection starts it.
        public var propertyList: [String: Any] {
            [
                "Label": label,
                "ProgramArguments": arguments,
                "MachServices": [label: true],
                "ProcessType": "Interactive",
                "StandardOutPath": logFile.path(percentEncoded: false),
                "StandardErrorPath": logFile.path(percentEncoded: false),
            ]
        }

        /// The property list as XML, with keys in sorted order.
        public func propertyListData() throws(MawError) -> Data {
            do {
                return try PropertyListSerialization.data(
                    fromPropertyList: propertyList, format: .xml, options: 0)
            } catch {
                throw .launchAgentFailed(reason: "the property list could not be written: \(error)")
            }
        }
    }
#endif
