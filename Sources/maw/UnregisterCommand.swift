import Darwin
import Foundation
import MawClient
import MawCore
import MawXPC

/// `maw --unregister <distro> [--yes]`: has the daemon stop the distribution and delete it.
///
/// The daemon resolves the name first, so that a name that is not installed fails without a
/// question and the question shows the stored spelling. When standard input is a terminal and
/// `--yes` is absent, maw then asks on the controlling terminal, as `--install` asks for the
/// account, and sends the removal only after `y` or `yes`. Success prints nothing, except one
/// line on standard error when another distribution has become the default.
struct UnregisterCommand {
    let name: DistroName
    let yes: Bool
    /// Connects to the daemon. The tests replace it.
    var connect: @Sendable () async throws(MawError) -> any UnregisterDaemon = {
        () async throws(MawError) -> any UnregisterDaemon in
        try await DaemonClient.connect()
    }
    /// Whether standard input is a terminal. The tests replace it.
    var inputIsTerminal: Bool = isatty(STDIN_FILENO) == 1
    /// Asks `question` and returns the answer's line, or `nil` at the end of input. The tests
    /// replace it.
    var ask: (String) throws -> String? = { question in
        let terminal = try PromptTerminal.open()
        terminal.write(question)
        return terminal.readLine()
    }
    /// Writes a line to standard error. The tests replace it.
    var report: (String) -> Void = { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// The question, with the distribution's stored spelling.
    static func question(for name: DistroName) -> String {
        "Delete \(name) and its disk for good? [y/N] "
    }

    /// Whether an answer goes on: `y` or `yes`, in any case, with the line's spaces ignored.
    static func isYes(_ answer: String?) -> Bool {
        guard let answer else { return false }
        let word = answer.trimmingCharacters(in: .whitespaces).lowercased()
        return word == "y" || word == "yes"
    }

    func run() async throws {
        let client = try await connect()
        defer { client.close() }
        let stored = try await client.checkUnregister(name)
        if inputIsTerminal, !yes {
            guard Self.isYes(try ask(Self.question(for: stored))) else {
                throw MawError.unregisterDeclined(stored)
            }
        }
        let summary = try await client.unregister(stored)
        if let newDefault = summary.newDefault {
            report("\(newDefault) is now the default distribution.")
        }
    }
}

/// What `maw --unregister` needs from the daemon. The tests supply a fake.
protocol UnregisterDaemon: Sendable {
    func checkUnregister(_ name: DistroName) async throws(MawError) -> DistroName
    func unregister(_ name: DistroName) async throws(MawError) -> UnregisterSummary
    func close()
}

extension DaemonClient: UnregisterDaemon {}
