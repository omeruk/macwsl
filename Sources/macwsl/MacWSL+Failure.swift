import ArgumentParser
import Foundation

extension MacWSL {
    /// How `main()` reports an error that ends the run unsuccessfully.
    struct Failure: Equatable {
        /// The text for standard error, ending in a newline. Empty when the error carries no
        /// message, as with `throw ExitCode.failure`.
        var output: String
        /// 64 (`EX_USAGE`) for usage errors, 1 for runtime errors.
        var exitCode: ExitCode
    }

    /// Describes how to report `error` in the single `macwsl:` format: the message, the
    /// suggested fix if the error has one, and the usage hint that ArgumentParser shows for
    /// usage errors.
    ///
    /// Returns `nil` for help, completion scripts and other clean exits, whose output
    /// ArgumentParser prints unchanged.
    static func failure(for error: any Error) -> Failure? {
        let exitCode = exitCode(for: error)
        if exitCode == .success {
            return nil
        }
        let message = message(for: error)
        if message.isEmpty {
            return Failure(output: "", exitCode: exitCode)
        }

        var lines = ["macwsl: \(message)"]
        if let suggestion = (error as? any LocalizedError)?.recoverySuggestion {
            lines.append(suggestion)
        }
        if let hint = usageHint(for: error, following: message) {
            lines.append(hint)
        }
        return Failure(output: lines.joined(separator: "\n") + "\n", exitCode: exitCode)
    }

    /// The `Help:` line and usage block that ArgumentParser prints after `message`, or `nil` if
    /// it prints none. ArgumentParser's full text is the prefixed message, a newline, then the
    /// hint; runtime errors have no newline after the message and therefore no hint.
    private static func usageHint(for error: any Error, following message: String) -> String? {
        let fullMessage = fullMessage(for: error)
        guard let messageEnd = fullMessage.range(of: message + "\n")?.upperBound else {
            return nil
        }
        let hint = fullMessage[messageEnd...].trimmingCharacters(in: .newlines)
        return hint.isEmpty ? nil : hint
    }
}
