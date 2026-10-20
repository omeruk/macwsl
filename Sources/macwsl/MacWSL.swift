import ArgumentParser
import Foundation
import MacWSLCore

/// The `macwsl` command line, modeled on `wsl.exe`: one root command whose flags select a single
/// action, rather than subcommands. `resolveAction()` turns the parsed flags into an `Action`
/// and rejects combinations that do not make sense.
@main
struct MacWSL: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macwsl",
        abstract: "Run and manage Linux distributions on your Mac.",
        usage: """
            macwsl [-d <distro>] [-u <user>] [--cd <directory>] [<command> [<argument>...]]
            macwsl [-d <distro>] [-u <user>] [--cd <directory>] -- <command> [<argument>...]
            macwsl [-d <distro>] [-u <user>] [--cd <directory>] -e <command> [<argument>...]
            macwsl --install [<distro>]
            macwsl --list [--verbose | --online]
            macwsl --set-default <distro>
            macwsl --terminate <distro>
            macwsl --shutdown
            macwsl --export <distro> <file>
            macwsl --import <distro> <file>
            macwsl --unregister <distro>
            macwsl --status
            macwsl --version
            """,
        discussion: """
            With no arguments, macwsl opens your login shell in the default distribution. \
            Anything after the options is a command to run there: "macwsl ls -la" is the same \
            as "macwsl -- ls -la". Use -- when the command itself starts with a dash.

            As in wsl.exe, -v means --verbose after --list, and --version anywhere else.

            Examples:
              macwsl --install Ubuntu-24.04     Install Ubuntu 24.04.
              macwsl -l -v                      List distributions with their state.
              macwsl -d Ubuntu -u root          Open a root shell in Ubuntu.
              macwsl -e uname -a                Run uname directly, without a shell.
              macwsl --export Ubuntu ubuntu.tar Back up Ubuntu to a tar file.
            """
    )

    @OptionGroup(title: "Running commands")
    var running: RunningOptions

    @OptionGroup(title: "Managing distributions")
    var managing: ManagingOptions

    @OptionGroup(title: "General")
    var general: GeneralOptions

    /// The operand of the action: the distro for `--install`, the file for `--export`/`--import`.
    @Argument(help: .hidden)
    var operand: String?

    /// The command after `--`. `ArgumentNormalizer` inserts the `--` before a bare command and
    /// after `-e`.
    @Argument(parsing: .postTerminator, help: .hidden)
    var command: [String] = []

    static func main() async {
        let arguments = ArgumentNormalizer.normalize(Array(CommandLine.arguments.dropFirst()))
        do {
            let invocation = try parse(arguments)
            try await invocation.run()
        } catch let error as MacWSLError {
            report(error)
            Foundation.exit(EXIT_FAILURE)
        } catch {
            exit(withError: error)
        }
    }

    mutating func validate() throws {
        _ = try resolveAction()
    }

    func run() async throws {
        let action = try resolveAction()
        throw MacWSLError.notImplemented(feature: action.displayName)
    }

    /// Prints `error` the way every MacWSL front end does: the message, then the suggested fix.
    private static func report(_ error: MacWSLError) {
        var message = "macwsl: \(error.description)\n"
        if let suggestion = error.recoverySuggestion {
            message += "\(suggestion)\n"
        }
        FileHandle.standardError.write(Data(message.utf8))
    }
}

// MARK: - Options

struct RunningOptions: ParsableArguments {
    @Option(
        name: CLIOption.distribution.names,
        parsing: .unconditional,
        help: ArgumentHelp(
            "Use <distro> instead of the default distribution.",
            discussion: "Also names the distribution to install with --install.",
            valueName: "distro"),
        transform: { try DistroName($0) }
    )
    var distribution: DistroName?

    @Option(
        name: CLIOption.user.names,
        parsing: .unconditional,
        help: ArgumentHelp(
            "Run as <user> instead of the distribution's default user.", valueName: "user"))
    var user: String?

    @Option(
        name: CLIOption.cd.names,
        parsing: .unconditional,
        help: ArgumentHelp(
            "Start in <directory>.",
            discussion: """
                A Linux path, a macOS path (translated to its /mnt/mac location), or ~ for the \
                Linux home directory. Defaults to the current macOS directory.
                """,
            valueName: "directory"))
    var directory: String?

    /// The command itself arrives in `MacWSL.command`: `ArgumentNormalizer` puts `--` after `-e`.
    @Flag(
        name: CLIOption.exec.names,
        help: ArgumentHelp(
            "Run the command that follows directly, without the Linux shell.",
            discussion: "Everything after -e is passed to the command unchanged."))
    var exec = false
}

struct ManagingOptions: ParsableArguments {
    @Flag(
        name: CLIOption.install.names,
        help: ArgumentHelp(
            "Install a distribution: --install [<distro>].",
            discussion: """
                Name the distribution after --install or with -d. Without a name, installs the \
                recommended distribution. --list --online shows what is available.
                """))
    var install = false

    @Flag(name: CLIOption.list.names, help: "List installed distributions.")
    var list = false

    @Flag(
        name: CLIOption.verbose.names,
        help: "With --list: also show each distribution's state and whether it is the default.")
    var verbose = false

    @Flag(
        name: CLIOption.online.names,
        help: "With --list: list distributions available to install instead.")
    var online = false

    @Option(
        name: CLIOption.setDefault.names,
        parsing: .unconditional,
        help: ArgumentHelp("Make <distro> the default distribution.", valueName: "distro"),
        transform: { try DistroName($0) })
    var setDefault: DistroName?

    @Option(
        name: CLIOption.terminate.names,
        parsing: .unconditional,
        help: ArgumentHelp("Stop <distro>'s virtual machine.", valueName: "distro"),
        transform: { try DistroName($0) })
    var terminate: DistroName?

    @Flag(name: CLIOption.shutdown.names, help: "Stop every running distribution.")
    var shutdown = false

    @Option(
        name: CLIOption.export.names,
        parsing: .unconditional,
        // The file is the positional `operand`. Naming it in the value keeps the help and the
        // parser's error messages ("Missing value for '--export <distro> <file>'") accurate.
        help: ArgumentHelp("Export <distro> to <file>, a tar archive.", valueName: "distro> <file"),
        transform: { try DistroName($0) })
    var export: DistroName?

    @Option(
        name: CLIOption.import.names,
        parsing: .unconditional,
        help: ArgumentHelp(
            "Create <distro> from <file>, a tar archive made by --export.",
            valueName: "distro> <file"),
        transform: { try DistroName($0) })
    var `import`: DistroName?

    @Option(
        name: CLIOption.unregister.names,
        parsing: .unconditional,
        help: ArgumentHelp(
            "Remove <distro> and permanently delete its disk.", valueName: "distro"),
        transform: { try DistroName($0) })
    var unregister: DistroName?
}

struct GeneralOptions: ParsableArguments {
    @Flag(
        name: CLIOption.status.names,
        help: "Show the default distribution and the state of the MacWSL service.")
    var status = false

    @Flag(
        name: CLIOption.version.names,
        help: "Show version information. -v does the same when it does not follow --list.")
    var version = false
}
