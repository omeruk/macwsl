import ArgumentParser
import Darwin
import Foundation
import MawClient
import MawCommandLine
import MawCore
import MawXPC

/// The `maw` command line, modeled on `wsl.exe`: one root command whose flags select a single
/// action, rather than subcommands. `resolveAction()` turns the parsed flags into an `Action`
/// and rejects combinations that do not make sense.
@main
struct Maw: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "maw",
        abstract: "Run and manage Linux distributions on your Mac.",
        usage: """
            maw [-d <distro>] [-u <user>] [--cd <directory>] [<command> [<argument>...]]
            maw [-d <distro>] [-u <user>] [--cd <directory>] -- <command> [<argument>...]
            maw [-d <distro>] [-u <user>] [--cd <directory>] -e <command> [<argument>...]
            maw --install [<distro>] [--name <name>] [-u <user>]
            maw --list [--running] [--verbose | --quiet]
            maw --list --online
            maw --set-default <distro>
            maw --terminate <distro>
            maw --shutdown
            maw --export <distro> <file> [--format tar | tar.gz | tar.xz]
            maw --import <distro> <file> [-u <user>]
            maw --unregister <distro> [--yes]
            maw --status
            maw --version
            """,
        discussion: """
            With no arguments, maw opens your login shell in the default distribution. \
            Anything after the options is a command to run there: "maw ls -la" is the same \
            as "maw -- ls -la". Use -- when the command itself starts with a dash.

            maw <command> and maw -- <command> join their arguments with spaces into one \
            command line for your Linux shell, as wsl.exe does, so the quoting of your Mac \
            shell is lost: maw -- sh -c 'echo a; echo b' runs sh -c echo a; echo b. To keep \
            the arguments intact, run the command directly with -e, as in \
            maw -e sh -c 'echo a; echo b', or quote the whole command line once, as in \
            maw -- 'echo a; echo b'.

            Sessions start in the Linux path of your current directory: your home \
            directory is /mnt/mac in Linux, and ~/Projects is /mnt/mac/Projects. Outside \
            your home directory, such as in /tmp, they start in your Linux home directory, \
            and maw says so on standard error.

            As in wsl.exe, -v means --verbose after --list, and --version anywhere else.

            --unregister permanently deletes the distribution and its disk, with every file in \
            it. On a terminal, maw asks first; --yes deletes without asking.

            --export writes a stopped distribution's root file system to a tar archive, or to \
            standard output for -. The archive is compressed with gzip when the file name ends \
            in .tar.gz, .tgz, or .gz, and with xz when it ends in .tar.xz, .txz, or .xz; \
            --format chooses instead.

            --import creates a distribution from a tar archive, uncompressed or compressed \
            with gzip, bzip2, xz, or lzip, such as one from --export or wsl.exe --export, or \
            from standard input for -. Its sessions \
            run as the user that -u names, or else the default user of the archive's \
            /etc/maw.conf or /etc/wsl.conf, or else root.

            Examples:
              maw --install Ubuntu-24.04          Install Ubuntu 24.04.
              maw -l -v                           List distributions with their state.
              maw -d Ubuntu-24.04 -u root         Open a root shell in Ubuntu 24.04.
              maw -e uname -a                     Run uname directly, without a shell.
              maw --export Ubuntu-24.04 u.tar.gz  Back up Ubuntu 24.04 to a tar.gz file.
              maw --import Copy u.tar.gz          Create Copy from that archive.
              maw --unregister Ubuntu-24.04       Delete Ubuntu 24.04 and its disk.
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
        } catch {
            exit(reporting: error)
        }
    }

    mutating func validate() throws {
        _ = try resolveAction()
    }

    func run() async throws {
        let action = try resolveAction()
        if let plan = try SessionPlan(action) {
            let status = try await runSession(plan)
            if status != 0 {
                throw ExitCode(status)
            }
            return
        }
        switch action {
        case .shell, .run, .exec:
            // Each has a session, which ran above.
            return
        case .status:
            try await Self.showStatus()
        case .shutdown:
            try await Self.shutDown()
        case .version:
            await Self.showVersion()
        case .install(let options):
            let status = try await InstallCommand(options: options).run()
            if status != 0 {
                throw ExitCode(status)
            }
        case .list(.online):
            print(Reports.online(DistroCatalog.builtIn), terminator: "")
        case .list(.installed(let options)):
            try await Self.listDistributions(options)
        case .setDefault(let name):
            try await Self.setDefault(name)
        case .terminate(let name):
            try await Self.terminate(name)
        case .unregister(let name, let yes):
            try await UnregisterCommand(name: name, yes: yes).run()
        case .export(let name, let file, let format):
            let status = try await ExportCommand(name: name, file: file, format: format).run()
            if status != 0 {
                throw ExitCode(status)
            }
        case .importDistro(let name, let file, let user):
            let status = try await ImportCommand(name: name, file: file, user: user).run()
            if status != 0 {
                throw ExitCode(status)
            }
        }
    }

    /// Runs the session and returns its exit status. A command that cannot be started ends
    /// as it would in a shell: 127 if it does not exist, 126 otherwise.
    private func runSession(_ plan: SessionPlan) async throws -> Int32 {
        let mode = SessionMode.select(
            inputIsTerminal: isatty(STDIN_FILENO) == 1, outputIsTerminal: isatty(STDOUT_FILENO) == 1
        )
        do {
            return try await SessionRunner(plan: plan, mode: mode).run()
        } catch let error as MawError {
            let status: Int32
            switch error {
            case .guestCommandNotFound: status = 127
            case .guestCommandNotStarted: status = 126
            default: throw error
            }
            FileHandle.standardError.write(Data((Self.failure(for: error)?.output ?? "").utf8))
            return status
        }
    }

    // MARK: Daemon actions

    /// `--status`. A daemon that does not run is a normal state, reported without starting it.
    static func showStatus() async throws {
        let label = DaemonInterface.label()
        guard DaemonClient.isRunning(label: label) else {
            guard DaemonClient.isInstalled(label: label) else {
                throw MawError.daemonNotInstalled(label: label)
            }
            print(Reports.daemonNotRunning, terminator: "")
            return
        }
        let client = try await DaemonClient.connect(label: label)
        defer { client.close() }
        print(Reports.status(try await client.status()), terminator: "")
    }

    /// `--shutdown`. Prints nothing, as `wsl.exe` does. Without a running daemon, nothing runs,
    /// and the daemon is not started only to be told so.
    static func shutDown() async throws {
        let label = DaemonInterface.label()
        guard DaemonClient.isRunning(label: label) else { return }
        let client = try await DaemonClient.connect(label: label)
        defer { client.close() }
        _ = try await client.shutdown()
    }

    /// `--list` without `--online`. The daemon owns the distributions and their machines, so
    /// the listing comes from it, and launchd starts it if it does not run. It starts no
    /// machine.
    static func listDistributions(_ options: ListOptions) async throws {
        let client = try await DaemonClient.connect()
        defer { client.close() }
        print(try Reports.installed(try await client.listDistributions(), options), terminator: "")
    }

    /// `--set-default`. Prints nothing, as `--shutdown` does. The daemon checks the name, so
    /// launchd starts it if it does not run; it starts no machine.
    static func setDefault(_ name: DistroName) async throws {
        let client = try await DaemonClient.connect()
        defer { client.close() }
        try await client.setDefault(name)
    }

    /// `--terminate`. Prints nothing, and returns once the machine has stopped. Unlike
    /// `--shutdown`, it starts the daemon if it does not run, because the daemon checks the
    /// name; a distribution that is installed but not running then succeeds at once.
    static func terminate(_ name: DistroName) async throws {
        let client = try await DaemonClient.connect()
        defer { client.close() }
        try await client.terminate(name)
    }

    /// `--version`: maw, the daemon if it runs, and the installed guest files.
    static func showVersion() async {
        let label = DaemonInterface.label()
        let daemon: Reports.DaemonVersion
        if DaemonClient.isRunning(label: label) {
            do {
                let client = try await DaemonClient.connect(label: label)
                daemon = .running(client.daemon)
                client.close()
            } catch {
                daemon = .unreachable(error)
            }
        } else {
            daemon = DaemonClient.isInstalled(label: label) ? .notRunning : .notInstalled
        }
        let guest: Reports.GuestVersion
        do {
            let files = try GuestFiles(directory: MawPaths().kernelDirectory)
            guest = files.manifest.map { .installed($0) } ?? .unreadable
        } catch {
            guest = .missing
        }
        print(Reports.version(daemon: daemon, guest: guest), terminator: "")
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
            "Run as <user> instead of the distribution's default user.",
            discussion:
                "With --install: the account to create. With --import: the default user, "
                + "which must exist in the archive.", valueName: "user"))
    var user: String?

    @Option(
        name: CLIOption.cd.names,
        parsing: .unconditional,
        help: ArgumentHelp(
            "Start in <directory>.",
            discussion: """
                A Linux path, a macOS path under your home directory (translated to its \
                /mnt/mac location), a path relative to the current macOS directory, or '~' \
                for the Linux home directory. Defaults to the current macOS directory. Quote \
                the ~: your Mac shell turns an unquoted ~ into your Mac home directory, so \
                --cd ~ starts in /mnt/mac, and --cd '~' in the Linux home directory.
                """,
            valueName: "directory"))
    var directory: String?

    /// The command itself arrives in `Maw.command`: `ArgumentNormalizer` puts `--` after `-e`.
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

    @Option(
        name: CLIOption.name.names,
        parsing: .unconditional,
        help: ArgumentHelp(
            "With --install: install the distribution under <name>.", valueName: "name"),
        transform: { try DistroName($0) })
    var name: DistroName?

    @Flag(
        name: CLIOption.list.names,
        help: "List the installed distributions. * marks the default.")
    var list = false

    @Flag(
        name: CLIOption.verbose.names,
        help: "With --list: also show the state of each distribution's virtual machine.")
    var verbose = false

    @Flag(
        name: CLIOption.running.names,
        help: ArgumentHelp(
            "With --list: list only the distributions whose virtual machine runs.",
            discussion: "This includes virtual machines that are starting or stopping."))
    var running = false

    @Flag(
        name: CLIOption.quiet.names,
        help: "With --list: print only the names, one per line.")
    var quiet = false

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
        help: ArgumentHelp(
            "Export the stopped <distro> to <file>, a tar archive, or - for standard output.",
            valueName: "distro> <file"),
        transform: { try DistroName($0) })
    var export: DistroName?

    @Option(
        name: CLIOption.format.names,
        parsing: .unconditional,
        help: ArgumentHelp(
            "With --export: write tar, tar.gz, or tar.xz, whatever the file's name.",
            valueName: "format"))
    var format: ArchiveFormat?

    @Option(
        name: CLIOption.import.names,
        parsing: .unconditional,
        help: ArgumentHelp(
            "Create <distro> from <file>, a tar archive, or - for standard input.",
            valueName: "distro> <file"),
        transform: { try DistroName($0) })
    var `import`: DistroName?

    @Option(
        name: CLIOption.unregister.names,
        parsing: .unconditional,
        help: ArgumentHelp(
            "Remove <distro> and permanently delete its disk and every file in it.",
            discussion: "On a terminal, maw asks first.", valueName: "distro"),
        transform: { try DistroName($0) })
    var unregister: DistroName?

    @Flag(
        name: CLIOption.yes.names,
        help: "With --unregister: delete without asking.")
    var yes = false
}

struct GeneralOptions: ParsableArguments {
    @Flag(
        name: CLIOption.status.names,
        help: "Show the default distribution and the state of the maw service.")
    var status = false

    @Flag(
        name: CLIOption.version.names,
        help: "Show version information. -v does the same when it does not follow --list.")
    var version = false
}

extension ArchiveFormat: ExpressibleByArgument {}
