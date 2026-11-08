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
        ["-l", "-q", "-v"],
        ["-l", "-o", "--running"],
        ["-l", "-o", "-q"],
        ["--running"],
        ["-q"],
        ["-l", "-d", "Ubuntu"],
        ["-s", "Ubuntu", "-d", "Debian"],
        ["-t"],
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
            try await failure(["--unregister", "Ubuntu"])
                == CommandFailure(
                    output: "maw: --unregister is not implemented yet; phase 06 adds it.\n",
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

/// Messages that were wider than 80 columns, as `maw` prints them, with the "maw: " prefix.
@Suite struct MessageWidthTests {
    func expectWithinEightyColumns(
        _ error: MawError, printing expected: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let output = try #require(Maw.failure(for: error)?.output)
        #expect(output == expected, sourceLocation: sourceLocation)
        for line in output.split(separator: "\n") {
            #expect(line.count <= 80, "\(line)", sourceLocation: sourceLocation)
        }
    }

    @Test func fitsTheCancellation() throws {
        try expectWithinEightyColumns(
            .installationCancelled(try DistroName("Ubuntu-24.04")),
            printing: """
                maw: The installation of Ubuntu-24.04 was cancelled.
                Nothing was installed. Run maw --install to start again; an interrupted
                download resumes where it stopped.

                """)
    }

    @Test func fitsAPasswordWithAControlCharacter() throws {
        try expectWithinEightyColumns(
            .invalidPassword(reason: "it contains a line break\nor a control character"),
            printing: """
                maw: The password cannot be used: it contains a line break
                or a control character.
                Type the same non-empty password twice. With --user, give it as the first
                line of standard input.

                """)
    }

    @Test func fitsAnUnconfirmedCancellation() throws {
        try expectWithinEightyColumns(
            .installationCancellationUnconfirmed(try DistroName("Ubuntu-24.04")),
            printing: """
                maw: The daemon has not yet confirmed the cancellation of the installation of
                Ubuntu-24.04. The installation may still be ending.
                Wait a moment, then run maw -d Ubuntu-24.04 -e true. It succeeds if
                Ubuntu-24.04 was installed after all, and otherwise says that it is not.

                """)
    }
}
