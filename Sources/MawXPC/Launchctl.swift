#if os(macOS)
    import Foundation
    import MawCore

    /// Runs `launchctl` in the user's GUI domain.
    public enum Launchctl {
        /// `gui/<uid>`.
        public static var domain: String { "gui/\(getuid())" }

        /// Whether launchd has a job with `label` loaded.
        public static func isLoaded(_ label: String) -> Bool {
            (try? run(["print", "\(domain)/\(label)"]))?.status == 0
        }

        /// Loads the agent in `plist`.
        public static func bootstrap(_ plist: URL) throws(MawError) {
            try check(["bootstrap", domain, plist.path(percentEncoded: false)])
        }

        /// Unloads the job, which stops it with SIGTERM first.
        public static func bootout(_ label: String) throws(MawError) {
            try check(["bootout", "\(domain)/\(label)"])
        }

        private static func check(_ arguments: [String]) throws(MawError) {
            let result = try run(arguments)
            guard result.status == 0 else {
                let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                throw .launchAgentFailed(
                    reason: "launchctl \(arguments.joined(separator: " ")) exited with status "
                        + "\(result.status)" + (output.isEmpty ? "" : ": \(output)"))
            }
        }

        private static func run(_ arguments: [String]) throws(MawError) -> (
            status: Int32, output: String
        ) {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/launchctl")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                throw .launchAgentFailed(reason: "launchctl could not be started: \(error)")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
    }
#endif
