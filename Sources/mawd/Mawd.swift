import ArgumentParser
import MawCommandLine
import MawCore

/// The maw daemon, which owns every virtual machine and serves the XPC interface that `maw`
/// uses (docs/daemon.md).
@main
struct Mawd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mawd",
        abstract: "The maw daemon, which owns the Linux virtual machines.",
        discussion: """
            launchd runs "mawd serve" when maw needs the daemon. Register it once with \
            "mawd install", after building and signing with scripts/sign-dev.sh, and remove it \
            with "mawd uninstall".
            """,
        version: MawVersion.current,
        subcommands: [Install.self, Uninstall.self, Serve.self, DebugBoot.self]
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
}
