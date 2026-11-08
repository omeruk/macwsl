import MawCore

/// What one invocation of `maw` asks for, after parsing and validation.
enum Action: Equatable, Sendable {
    /// No action and no command: open the user's login shell.
    case shell(Session)
    /// `maw [--] <command> [<arguments>...]`: run a command through the user's login shell.
    case run([String], Session)
    /// `maw -e <command> [<arguments>...]`: run a command directly, without a shell.
    case exec([String], Session)
    /// `--install [<distro>] [--name <name>] [--user <user>]`.
    case install(InstallOptions)
    case list(ListMode)
    case setDefault(DistroName)
    case terminate(DistroName)
    case shutdown
    case export(DistroName, file: String)
    case importDistro(DistroName, file: String)
    case unregister(DistroName)
    case status
    case version

    /// The roadmap phase that implements the action.
    var phase: String {
        switch self {
        case .shell, .run, .exec, .shutdown, .status, .version: "04b"
        case .install, .list(.online): "05"
        case .list(.installed), .setDefault, .terminate: "06a"
        case .export, .importDistro, .unregister: "06b"
        }
    }

    /// How the action is named in user-facing messages.
    var displayName: String {
        switch self {
        case .shell: "opening a shell"
        case .run, .exec: "running a command"
        case .install: "--install"
        case .list(.installed(let options)): options.displayName
        case .list(.online): "--list --online"
        case .setDefault: "--set-default"
        case .terminate: "--terminate"
        case .shutdown: "--shutdown"
        case .export: "--export"
        case .importDistro: "--import"
        case .unregister: "--unregister"
        case .status: "--status"
        case .version: "--version"
        }
    }
}

/// Where and as whom a shell or command runs.
struct Session: Equatable, Sendable {
    /// `nil` means the default distribution.
    var distro: DistroName?
    /// `nil` means the distribution's default user.
    var user: String?
    /// `nil` means the current macOS directory, translated into the distribution.
    var directory: String?

    init(distro: DistroName? = nil, user: String? = nil, directory: String? = nil) {
        self.distro = distro
        self.user = user
        self.directory = directory
    }
}

enum ListMode: Equatable, Sendable {
    /// Installed distributions, as `ListOptions` selects them.
    case installed(ListOptions)
    /// Distributions available to install.
    case online
}

/// The modifiers of `--list` without `--online`. `Maw.resolveAction()` rejects `quiet` with
/// `verbose`.
struct ListOptions: Equatable, Sendable {
    /// Adds each distribution's state.
    var verbose: Bool
    /// Lists only the distributions whose virtual machine is not stopped.
    var running: Bool
    /// Prints the names only, one per line, without a header or the default's marker.
    var quiet: Bool

    init(verbose: Bool = false, running: Bool = false, quiet: Bool = false) {
        self.verbose = verbose
        self.running = running
        self.quiet = quiet
    }

    /// The command line that selects these options, for example `--list --running --quiet`.
    var displayName: String {
        let modifiers = [
            (CLIOption.running, running), (CLIOption.verbose, verbose), (CLIOption.quiet, quiet),
        ]
        return (["--\(CLIOption.list.long)"] + modifiers.filter(\.1).map { "--\($0.0.long)" })
            .joined(separator: " ")
    }
}

/// What `--install` installs, under which name, and for which user.
struct InstallOptions: Equatable, Sendable {
    /// A catalog name or alias; `nil` installs the recommended distribution.
    var distro: DistroName?
    /// The name to install it under; `nil` is the catalog entry's name.
    var name: DistroName?
    /// The new account's name. With it, the password is read from standard input; without
    /// it, maw asks for both on the terminal.
    var user: String?

    init(distro: DistroName? = nil, name: DistroName? = nil, user: String? = nil) {
        self.distro = distro
        self.name = name
        self.user = user
    }
}
