import ArgumentParser
import MawCore
import Testing

@testable import maw

/// How `maw` prints the errors that end a session (`SessionEnding` in `MawClient`, tested in
/// `MawClientTests`): on standard error, with exit status 1, the status of every runtime error
/// (`CommandFailure`).
@Suite struct SessionConnectionEndTests {
    @Test func printsAnEndOfTheConnectionWithTheCommandsToFindTheProcess() throws {
        let failure = try #require(
            Maw.failure(for: MawError.sessionConnectionEnded(distribution: "Ubuntu-24.04")))
        #expect(
            failure.output == """
                maw: The connection to the session in Ubuntu-24.04 ended unexpectedly.
                The output may be incomplete, and the command may still be running there.
                If the command is still running, find its process ID with
                maw -d Ubuntu-24.04 -e ps -ef and end it with maw -d Ubuntu-24.04 -e kill <ID>.
                maw --terminate Ubuntu-24.04 also ends it, and every other session there.

                """)
        #expect(failure.exitCode == ExitCode(1))
    }

    /// A stopped machine does not say that the command may still be running.
    @Test func printsAStoppedMachineWithoutSayingThatTheCommandMayStillRun() throws {
        let failure = try #require(
            Maw.failure(
                for: MawError.machineStopped(
                    machine: "Ubuntu-24.04", reason: "maw --shutdown was run")))
        #expect(
            failure.output
                == "maw: The session ended because the virtual machine Ubuntu-24.04 stopped:\n"
                + "maw --shutdown was run.\nRun the command again to start a new virtual "
                + "machine.\n")
        #expect(!failure.output.contains("still be running"))
    }
}
