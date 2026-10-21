import ArgumentParser
import MawCommandLine
import MawCore
import Testing

@testable import maw

@Suite struct FailureTests {
    /// Inputs that fail parsing or validation, which ArgumentParser reports with a usage hint.
    static let usageErrors: [[String]] = [
        ["--shutdown", "-d", "Ubuntu"],
        ["--cd"],
        ["--bogus"],
        ["-d", "-v"],
        ["-e"],
        ["-l", "-o", "-v"],
        ["--install", "a", "b"],
        ["-dUbuntu", "ls"],
    ]

    /// The error `main()` catches for `arguments`, or `nil` if the run succeeds.
    private func caughtError(_ arguments: [String]) async -> (any Error)? {
        do {
            let command = try Maw.parse(ArgumentNormalizer.normalize(arguments))
            try await command.run()
            return nil
        } catch {
            return error
        }
    }

    private func failure(_ arguments: [String]) async throws -> CommandFailure {
        let error = try #require(await caughtError(arguments))
        return try #require(Maw.failure(for: error))
    }

    // MARK: Usage errors

    @Test(arguments: usageErrors)
    func reportsUsageErrorsInTheMawFormat(_ arguments: [String]) async throws {
        let failure = try await failure(arguments)
        #expect(failure.output.hasPrefix("maw: "))
        #expect(!failure.output.contains("Error: "))
        #expect(failure.output.contains("\nUsage: maw "))
        #expect(failure.output.hasSuffix("  See 'maw --help' for more information.\n"))
        #expect(failure.exitCode == .validationFailure)
        #expect(failure.exitCode.rawValue == 64)
    }

    @Test(arguments: usageErrors)
    func keepsArgumentParsersUsageHintUnchanged(_ arguments: [String]) async throws {
        let error = try #require(await caughtError(arguments))
        let failure = try #require(Maw.failure(for: error))
        let argumentParserText = Maw.fullMessage(for: error)
        #expect(argumentParserText.hasPrefix("Error: "))
        #expect(failure.output == "maw: " + argumentParserText.dropFirst("Error: ".count) + "\n")
    }

    @Test func reportsAValidationError() async throws {
        let output = try await failure(["--shutdown", "-d", "Ubuntu"]).output
        #expect(
            output.hasPrefix(
                """
                maw: --shutdown cannot be combined with --distribution (-d).
                Usage: maw [-d <distro>] [-u <user>] [--cd <directory>] [<command> [<argument>...]]

                """))
    }

    @Test func includesTheHelpLineForAMissingValue() async throws {
        let output = try await failure(["--cd"]).output
        #expect(
            output.hasPrefix(
                """
                maw: Missing value for '--cd <directory>'
                Help:  --cd <directory>  Start in <directory>.
                Usage: maw
                """))
    }

    // MARK: Runtime errors

    @Test func reportsARuntimeErrorWithoutUsage() async throws {
        #expect(
            try await failure(["-l", "-v"])
                == CommandFailure(
                    output: "maw: --list --verbose is not implemented yet\n",
                    exitCode: .failure))
    }

    @Test func appendsTheSuggestedFix() throws {
        let error = MawError.invalidDistroName("a b", reason: "the character ' ' is not allowed")
        let failure = try #require(Maw.failure(for: error))
        let description = try #require(error.errorDescription)
        let suggestion = try #require(error.recoverySuggestion)
        #expect(failure.output == "maw: \(description)\n\(suggestion)\n")
        #expect(failure.exitCode.rawValue == 1)
    }

    @Test func printsNothingForAnErrorWithoutAMessage() {
        #expect(
            Maw.failure(for: ExitCode.failure) == CommandFailure(output: "", exitCode: .failure))
        #expect(
            Maw.failure(for: ExitCode(70)) == CommandFailure(output: "", exitCode: ExitCode(70)))
    }

    // MARK: Clean exits

    @Test(arguments: [["--help"], ["-h"], ["--generate-completion-script", "zsh"]])
    func leavesHelpAndCompletionToArgumentParser(_ arguments: [String]) async throws {
        let error = try #require(await caughtError(arguments))
        #expect(Maw.failure(for: error) == nil)
        #expect(Maw.exitCode(for: error) == .success)
    }

    @Test func leavesTheHelpTextUnchanged() async throws {
        let error = try #require(await caughtError(["--help"]))
        #expect(Maw.fullMessage(for: error) == Maw.helpMessage())
        #expect(Maw.fullMessage(for: error).hasPrefix("OVERVIEW: "))
    }

    @Test func leavesASuccessfulExitAlone() {
        #expect(Maw.failure(for: ExitCode.success) == nil)
    }
}
