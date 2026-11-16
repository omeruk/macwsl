import Foundation
import MawClient
import MawCore
import MawXPC
import Testing
import os

@testable import maw

/// The question before `--unregister`, with a fake daemon and a fake terminal.
@Suite struct UnregisterCommandTests {
    final class FakeDaemon: UnregisterDaemon, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: [String]())
        let stored: DistroName
        let newDefault: DistroName?
        let checkError: MawError?

        init(
            stored: DistroName = try! DistroName("Copy"), newDefault: DistroName? = nil,
            checkError: MawError? = nil
        ) {
            self.stored = stored
            self.newDefault = newDefault
            self.checkError = checkError
        }

        var requests: [String] { lock.withLock { $0 } }

        func checkUnregister(_ name: DistroName) async throws(MawError) -> DistroName {
            lock.withLock { $0.append("checkUnregister \(name)") }
            if let checkError { throw checkError }
            return stored
        }

        func unregister(_ name: DistroName) async throws(MawError) -> UnregisterSummary {
            lock.withLock { $0.append("unregister \(name)") }
            return UnregisterSummary(name: name, newDefault: newDefault, endedSessions: 0)
        }

        func close() {}
    }

    /// The questions asked and the lines reported.
    final class Record: @unchecked Sendable {
        var questions: [String] = []
        var reports: [String] = []
    }

    func command(
        _ daemon: FakeDaemon, yes: Bool = false, terminal: Bool = true, answer: String? = "y",
        record: Record
    ) -> UnregisterCommand {
        var command = UnregisterCommand(name: try! DistroName("copy"), yes: yes)
        command.connect = { () async throws(MawError) -> any UnregisterDaemon in daemon }
        command.inputIsTerminal = terminal
        command.ask = { question in
            record.questions.append(question)
            return answer
        }
        command.report = { record.reports.append($0) }
        return command
    }

    /// Only `y` or `yes`, in any case, goes on.
    @Test(arguments: ["y", "Y", "yes", "YES", "Yes", " y ", "yes\t"])
    func removesAfterYes(_ answer: String) async throws {
        let daemon = FakeDaemon()
        let record = Record()
        try await command(daemon, answer: answer, record: record).run()
        #expect(record.questions == ["Delete Copy and its disk for good? [y/N] "])
        #expect(daemon.requests == ["checkUnregister copy", "unregister Copy"])
        #expect(record.reports.isEmpty)
    }

    /// Anything else, an empty line, and the end of input (Ctrl-D) change nothing and fail.
    @Test(arguments: ["n", "N", "no", "", "yy", "ye", "yes please", "oui", nil] as [String?])
    func changesNothingWithoutYes(_ answer: String?) async throws {
        let daemon = FakeDaemon()
        let record = Record()
        await #expect(throws: MawError.unregisterDeclined(try DistroName("Copy"))) {
            try await command(daemon, answer: answer, record: record).run()
        }
        #expect(record.questions.count == 1)
        #expect(daemon.requests == ["checkUnregister copy"])
    }

    @Test func asksNothingWithYes() async throws {
        let daemon = FakeDaemon()
        let record = Record()
        try await command(daemon, yes: true, answer: "n", record: record).run()
        #expect(record.questions.isEmpty)
        #expect(daemon.requests == ["checkUnregister copy", "unregister Copy"])
    }

    /// Without a terminal on standard input, as in a script, nothing is asked, as with
    /// `wsl.exe --unregister`.
    @Test func asksNothingWithoutATerminal() async throws {
        let daemon = FakeDaemon()
        let record = Record()
        try await command(daemon, terminal: false, answer: "n", record: record).run()
        #expect(record.questions.isEmpty)
        #expect(daemon.requests == ["checkUnregister copy", "unregister Copy"])
    }

    /// A name that is not installed fails before any question.
    @Test func asksNothingForANameThatIsNotInstalled() async throws {
        let error = MawError.distributionNotInstalled(try DistroName("copy"))
        let daemon = FakeDaemon(checkError: error)
        let record = Record()
        await #expect(throws: error) {
            try await command(daemon, record: record).run()
        }
        #expect(record.questions.isEmpty)
        #expect(daemon.requests == ["checkUnregister copy"])
    }

    @Test func namesTheNewDefault() async throws {
        let daemon = FakeDaemon(newDefault: try DistroName("Ubuntu-24.04"))
        let record = Record()
        try await command(daemon, record: record).run()
        #expect(record.reports == ["Ubuntu-24.04 is now the default distribution."])
    }

    /// The question and the line fit in 80 columns with a name of 12 characters.
    @Test func fitsItsLinesIn80Columns() throws {
        let name = try DistroName("Ubuntu-24.04")
        #expect(UnregisterCommand.question(for: name).count <= 80)
        #expect("\(name) is now the default distribution.".count <= 80)
        let declined = try #require(Maw.failure(for: MawError.unregisterDeclined(name)))
        for line in declined.output.split(separator: "\n") {
            #expect(line.count <= 80, "\(line)")
        }
    }
}
