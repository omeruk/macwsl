import ArgumentParser
import Foundation
import MawCommandLine
import Testing

/// A minimal command, so that the shared reporting is tested independently of `maw`.
private struct Fixture: ParsableCommand {
    @Option var count: Int?

    func validate() throws {
        if let count, count < 0 {
            throw ValidationError("--count must not be negative.")
        }
    }
}

private struct RuntimeError: LocalizedError {
    var errorDescription: String? { "the operation failed" }
    var recoverySuggestion: String? { "Try again later." }
}

@Suite struct CommandFailureTests {
    private func parseError(_ arguments: [String]) throws -> any Error {
        do {
            _ = try Fixture.parse(arguments)
        } catch {
            return error
        }
        Issue.record("\(arguments) parsed without an error")
        throw ExitCode.failure
    }

    @Test func reportsUsageErrorsWithThePrefixAndArgumentParsersHint() throws {
        let error = try parseError(["--count=-1"])
        let failure = try #require(Fixture.failure(for: error))
        #expect(failure.output.hasPrefix("maw: --count must not be negative.\nUsage: "))
        #expect(failure.output == "maw: " + Fixture.fullMessage(for: error).dropFirst(7) + "\n")
        #expect(failure.exitCode == .validationFailure)
    }

    @Test func reportsRuntimeErrorsWithTheSuggestedFix() throws {
        let failure = try #require(Fixture.failure(for: RuntimeError()))
        #expect(
            failure
                == CommandFailure(
                    output: "maw: the operation failed\nTry again later.\n", exitCode: .failure))
    }

    @Test func leavesHelpToArgumentParser() throws {
        #expect(Fixture.failure(for: try parseError(["--help"])) == nil)
        #expect(Fixture.failure(for: ExitCode.success) == nil)
    }

    @Test func printsNothingForAnErrorWithoutAMessage() {
        #expect(
            Fixture.failure(for: ExitCode(3)) == CommandFailure(output: "", exitCode: ExitCode(3)))
    }
}
