import ArgumentParser
import Foundation

/// How a MacWSL command-line tool reports an error that ends the run unsuccessfully. Shared by
/// `macwsl` and `macwsld`, so that both report errors in the same `macwsl:` format.
public struct CommandFailure: Equatable, Sendable {
    /// The text for standard error, ending in a newline. Empty when the error carries no
    /// message, as with `throw ExitCode.failure`.
    public var output: String
    /// 64 (`EX_USAGE`) for usage errors, 1 for runtime errors.
    public var exitCode: ExitCode

    public init(output: String, exitCode: ExitCode) {
        self.output = output
        self.exitCode = exitCode
    }
}

extension ParsableArguments {
    /// Describes how to report `error` in the single `macwsl:` format: the message, the
    /// suggested fix if the error has one, and the usage hint that ArgumentParser shows for
    /// usage errors.
    ///
    /// Returns `nil` for help, completion scripts and other clean exits, whose output
    /// ArgumentParser prints unchanged.
    public static func failure(for error: any Error) -> CommandFailure? {
        let exitCode = exitCode(for: error)
        if exitCode == .success {
            return nil
        }
        let message = message(for: error)
        if message.isEmpty {
            return CommandFailure(output: "", exitCode: exitCode)
        }

        var lines = ["macwsl: \(message)"]
        if let suggestion = (error as? any LocalizedError)?.recoverySuggestion {
            lines.append(suggestion)
        }
        if let hint = usageHint(for: error, following: message) {
            lines.append(hint)
        }
        return CommandFailure(output: lines.joined(separator: "\n") + "\n", exitCode: exitCode)
    }

    /// Reports `error` as `failure(for:)` describes and exits. Help and other clean exits are
    /// left to ArgumentParser, which prints them to standard output and exits with status 0.
    public static func exit(reporting error: any Error) -> Never {
        guard let failure = failure(for: error) else {
            exit(withError: error)
        }
        FileHandle.standardError.write(Data(failure.output.utf8))
        Foundation.exit(failure.exitCode.rawValue)
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
