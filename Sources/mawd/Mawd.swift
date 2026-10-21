import ArgumentParser
import MawCommandLine
import MawCore
import os

/// The maw daemon. It will own every virtual machine and serve the XPC interface; until
/// then, running it without a subcommand logs a startup line and exits.
@main
struct Mawd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mawd",
        abstract: "The maw daemon, which owns the Linux virtual machines.",
        discussion: """
            Without a subcommand, mawd runs as the daemon. The daemon is a placeholder until \
            the XPC service is implemented: it logs a startup line and exits.
            """,
        subcommands: [DebugBoot.self]
    )

    static func main() async {
        do {
            var command = try parseAsRoot()
            if var command = command as? AsyncParsableCommand {
                try await command.run()
            } else {
                try command.run()
            }
        } catch {
            exit(reporting: error)
        }
    }

    func run() async throws {
        Logger(subsystem: "dev.maw", category: "daemon")
            .notice(
                "mawd \(MawVersion.current, privacy: .public) starting (placeholder, exiting)"
            )
    }
}
