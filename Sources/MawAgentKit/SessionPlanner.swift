import MawCore
import MawProtocol

/// What the agent reads from the guest to plan a session, so that tests can supply it.
public struct GuestSystem: Sendable {
    /// The contents of a file, or `nil` if it cannot be read.
    public var readFile: @Sendable (String) -> String?
    public var isDirectory: @Sendable (String) -> Bool
    public var isExecutable: @Sendable (String) -> Bool
    public var exists: @Sendable (String) -> Bool
    /// The locales the guest has, as `locale -a` names them.
    public var availableLocales: @Sendable () -> [String]
    public var initSystem: @Sendable () -> InitSystem
    /// The agent's own user ID: root in the guest. A session for that user needs no switch.
    public var currentUserID: UInt32

    public init(
        readFile: @escaping @Sendable (String) -> String?,
        isDirectory: @escaping @Sendable (String) -> Bool,
        isExecutable: @escaping @Sendable (String) -> Bool,
        exists: @escaping @Sendable (String) -> Bool,
        availableLocales: @escaping @Sendable () -> [String],
        initSystem: @escaping @Sendable () -> InitSystem,
        currentUserID: UInt32
    ) {
        self.readFile = readFile
        self.isDirectory = isDirectory
        self.isExecutable = isExecutable
        self.exists = exists
        self.availableLocales = availableLocales
        self.initSystem = initSystem
        self.currentUserID = currentUserID
    }
}

/// The user, groups, and identity a process starts with.
struct Credentials: Equatable, Sendable {
    var uid: UInt32
    var gid: UInt32
    var groups: [UInt32]
}

/// Who owns a session's pseudo-terminal: its user, and the `tty` group with mode 620, as
/// `login` and `sshd` set it, so that programs that reopen the terminal, such as `screen` or
/// GnuPG's pinentry, can.
struct TerminalOwner: Equatable, Sendable {
    var uid: UInt32
    var gid: UInt32
}

/// How `ForegroundProbe` recognizes a session's shell among the processes on its terminal.
struct ShellIdentity: Equatable, Sendable {
    enum Position: Equatable, Sendable {
        /// The process the agent starts is the shell, or the session's program.
        case child
        /// The process the agent starts is `runuser -l`, and the shell is its child, which
        /// makes a process group of its own.
        case childOfChild
    }

    /// The length of a Linux command name, `TASK_COMM_LEN` less its terminating zero.
    static let commandNameLimit = 15

    var position: Position
    /// For a login shell, the command name its process has (`/proc/<pid>/comm`): the basename
    /// of the account's shell, truncated to `commandNameLimit` bytes. A shell process with
    /// another name has run `exec`, and the probe reports that program. `nil` for sessions
    /// that are not login shells, which skip the check.
    var commandName: String?

    static let child = ShellIdentity(position: .child, commandName: nil)

    /// The identity of a login shell whose executable is `shellPath`.
    static func loginShell(_ shellPath: String, position: Position) -> ShellIdentity {
        let basename = shellPath.split(separator: "/").last.map(String.init) ?? shellPath
        return ShellIdentity(position: position, commandName: commandName(basename))
    }

    /// `name` as the kernel keeps it: at most `commandNameLimit` bytes.
    static func commandName(_ name: String) -> String {
        String(decoding: name.utf8.prefix(commandNameLimit), as: UTF8.self)
    }
}

/// Exactly what the agent starts for a request.
struct SpawnPlan: Equatable, Sendable {
    /// The executable, or `nil` to search PATH for `argv[0]`.
    var path: String?
    var argv: [String]
    var environment: [String: String]
    var workingDirectory: String
    /// Where the process starts when it cannot enter `workingDirectory`, or `nil` to fail.
    var fallbackDirectory: String? = nil
    /// The identity to switch to, or `nil` to keep the agent's (root).
    var credentials: Credentials?
    /// Whether to wait, briefly, for the system bus before starting: `pam_systemd` registers
    /// the session with `systemd-logind` over it.
    var waitsForSystemBus: Bool
    /// The pseudo-terminal's owner, when the session runs as another user than the agent's.
    var terminalOwner: TerminalOwner? = nil
    /// How the foreground probe recognizes the session's shell.
    var shell: ShellIdentity = .child
    /// Whether the process is `runuser -l` with the agent as its shell helper
    /// (`LoginShellHelper`), which reports on descriptor 3 whether it entered the working
    /// directory before it starts the user's shell.
    var reportsThroughHelper = false
    /// The descriptor that the process gets as descriptor 3, set when it is spawned.
    var inheritedDescriptor: Int32? = nil
}

/// Turns an exec request into a `SpawnPlan` for the account it runs as.
///
/// - The user is the request's, or `[user] default` from `/etc/maw.conf`, or root.
/// - The environment is a login environment, as ssh builds it: `HOME`, `USER`, `LOGNAME`,
///   `SHELL`, `PATH` from `/etc/login.defs`, `LANG` from `GuestLocale`, and `XDG_RUNTIME_DIR`
///   when the user's runtime directory exists. The request's variables apply on top.
/// - A login shell under systemd starts through `runuser -l`, whose PAM stack includes
///   `pam_systemd`, so that `systemd-logind` registers the session
///   (`docs/decisions/0015-sessions-through-pam.md`). Everything else switches identity in the
///   agent itself and does not open a login session, which keeps commands fast.
enum SessionPlanner {
    static let runuserPaths = ["/usr/sbin/runuser", "/sbin/runuser"]
    /// The agent's binary in a distribution, which `/init` copies there
    /// (docs/decisions/0013-systemd-and-the-agent.md). `runuser -l` runs it as the shell helper
    /// of a login shell in a working directory (docs/decisions/0022-working-directory-and-logind.md).
    static let agentPath = "/run/maw/maw-agent"
    /// Where `mawpath` is linked, which every session's PATH includes.
    static let mawpathDirectory = "/usr/local/bin"
    static let systemBusSocket = "/run/dbus/system_bus_socket"
    /// Variables that `runuser -l` would otherwise clear. It always sets HOME, SHELL, USER,
    /// LOGNAME, and PATH itself.
    static let runuserResetVariables: Set<String> = ["HOME", "SHELL", "USER", "LOGNAME", "PATH"]

    static func plan(_ request: ExecRequest, system: GuestSystem) throws(SpawnFailure) -> SpawnPlan
    {
        let account = try self.account(for: request, system: system)
        let isRoot = account.uid == 0

        var environment = [
            "HOME": account.home,
            "USER": account.name,
            "LOGNAME": account.name,
            "SHELL": account.shell,
            "PATH": including(
                mawpathDirectory,
                in: LoginDefinitions.path(
                    forRoot: isRoot, loginDefs: system.readFile("/etc/login.defs"))),
            "LANG": GuestLocale.choose(
                preferred: request.locale, available: system.availableLocales()),
        ]
        let runtimeDirectory = "/run/user/\(account.uid)"
        if system.isDirectory(runtimeDirectory) {
            environment["XDG_RUNTIME_DIR"] = runtimeDirectory
        }
        environment.merge(request.environment) { _, requested in requested }

        let home = system.isDirectory(account.home) ? account.home : "/"
        let requested = request.workingDirectory.map { expandingHome($0, home: account.home) }
        let workingDirectory = requested ?? home
        let fallbackDirectory = request.fallsBackToHome && requested != nil ? home : nil
        let credentials =
            account.uid == system.currentUserID
            ? nil : Credentials(uid: account.uid, gid: account.gid, groups: account.groups)
        let terminalOwner =
            account.uid == system.currentUserID
            ? nil
            : TerminalOwner(
                uid: account.uid,
                gid: UserDatabase.groupID(named: "tty", group: system.readFile("/etc/group") ?? "")
                    ?? 5)

        switch request.program {
        case .argv(let argv):
            return SpawnPlan(
                path: nil, argv: argv, environment: environment,
                workingDirectory: workingDirectory, fallbackDirectory: fallbackDirectory,
                credentials: credentials, waitsForSystemBus: false, terminalOwner: terminalOwner)
        case .shellCommand(let command):
            return SpawnPlan(
                path: account.shell, argv: [account.shell, "-c", command],
                environment: environment, workingDirectory: workingDirectory,
                fallbackDirectory: fallbackDirectory, credentials: credentials,
                waitsForSystemBus: false, terminalOwner: terminalOwner)
        case .loginShell:
            if system.initSystem() == .systemd,
                let runuser = runuserPaths.first(where: system.isExecutable),
                requested == nil || system.isExecutable(agentPath)
            {
                // runuser -l opens the PAM session, which registers the shell with
                // systemd-logind, and changes to the home directory. In another directory,
                // the agent runs as runuser's shell helper, which enters it and then starts
                // the user's shell (LoginShellHelper).
                let kept = environment.keys.filter { !runuserResetVariables.contains($0) }.sorted()
                var argv = [runuser, "-l", account.name]
                if !kept.isEmpty {
                    argv += ["-w", kept.joined(separator: ",")]
                }
                if let requested {
                    argv += ["-s", agentPath, "--"]
                    argv += LoginShellHelper.arguments(
                        directory: requested, fallsBack: fallbackDirectory != nil,
                        shell: account.shell)
                }
                return SpawnPlan(
                    path: runuser, argv: argv, environment: environment,
                    workingDirectory: "/", credentials: nil, waitsForSystemBus: true,
                    terminalOwner: terminalOwner,
                    shell: .loginShell(account.shell, position: .childOfChild),
                    reportsThroughHelper: requested != nil)
            }
            let shellName = account.shell.split(separator: "/").last.map(String.init) ?? "sh"
            return SpawnPlan(
                path: account.shell, argv: ["-" + shellName], environment: environment,
                workingDirectory: workingDirectory, fallbackDirectory: fallbackDirectory,
                credentials: credentials, waitsForSystemBus: false, terminalOwner: terminalOwner,
                shell: .loginShell(account.shell, position: .child))
        }
    }

    /// `~` and `~/<path>` as the user's home directory and a path under it; anything else as
    /// it is. `~user` is not expanded.
    static func expandingHome(_ directory: String, home: String) -> String {
        if directory == "~" { return home }
        if directory.hasPrefix("~/") {
            return (home == "/" ? "" : home) + directory.dropFirst()
        }
        return directory
    }

    /// `path`, a PATH value, with `directory` appended unless one of its entries is already
    /// `directory`.
    static func including(_ directory: String, in path: String) -> String {
        let entries = path.split(separator: ":", omittingEmptySubsequences: false)
        if entries.contains(where: { $0 == directory }) { return path }
        return path.isEmpty ? directory : path + ":" + directory
    }

    private static func account(for request: ExecRequest, system: GuestSystem)
        throws(SpawnFailure) -> Account
    {
        let name =
            request.user
            ?? system.readFile("/etc/maw.conf").flatMap { MawConf(parsing: $0).defaultUser }
            ?? "root"
        guard
            let account = UserDatabase.account(
                named: name, passwd: system.readFile("/etc/passwd") ?? "",
                group: system.readFile("/etc/group") ?? "")
        else {
            throw SpawnFailure(
                code: .userNotFound, message: "there is no user named '\(name)' in /etc/passwd",
                user: name)
        }
        return account
    }
}
