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

/// Exactly what the agent starts for a request.
struct SpawnPlan: Equatable, Sendable {
    /// The executable, or `nil` to search PATH for `argv[0]`.
    var path: String?
    var argv: [String]
    var environment: [String: String]
    var workingDirectory: String
    /// The identity to switch to, or `nil` to keep the agent's (root).
    var credentials: Credentials?
    /// Whether to wait, briefly, for the system bus before starting: `pam_systemd` registers
    /// the session with `systemd-logind` over it.
    var waitsForSystemBus: Bool
    /// The pseudo-terminal's owner, when the session runs as another user than the agent's.
    var terminalOwner: TerminalOwner? = nil
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
            "PATH": LoginDefinitions.path(
                forRoot: isRoot, loginDefs: system.readFile("/etc/login.defs")),
            "LANG": GuestLocale.choose(
                preferred: request.locale, available: system.availableLocales()),
        ]
        let runtimeDirectory = "/run/user/\(account.uid)"
        if system.isDirectory(runtimeDirectory) {
            environment["XDG_RUNTIME_DIR"] = runtimeDirectory
        }
        environment.merge(request.environment) { _, requested in requested }

        let home = system.isDirectory(account.home) ? account.home : "/"
        let workingDirectory = request.workingDirectory ?? home
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
                workingDirectory: workingDirectory, credentials: credentials,
                waitsForSystemBus: false, terminalOwner: terminalOwner)
        case .shellCommand(let command):
            return SpawnPlan(
                path: account.shell, argv: [account.shell, "-c", command],
                environment: environment, workingDirectory: workingDirectory,
                credentials: credentials, waitsForSystemBus: false, terminalOwner: terminalOwner)
        case .loginShell:
            if request.workingDirectory == nil, system.initSystem() == .systemd,
                let runuser = runuserPaths.first(where: system.isExecutable)
            {
                // runuser -l changes to the home directory itself, which is why a requested
                // working directory takes the other path.
                let kept = environment.keys.filter { !runuserResetVariables.contains($0) }.sorted()
                var argv = [runuser, "-l", account.name]
                if !kept.isEmpty {
                    argv += ["-w", kept.joined(separator: ",")]
                }
                return SpawnPlan(
                    path: runuser, argv: argv, environment: environment,
                    workingDirectory: "/", credentials: nil, waitsForSystemBus: true,
                    terminalOwner: terminalOwner)
            }
            let shellName = account.shell.split(separator: "/").last.map(String.init) ?? "sh"
            return SpawnPlan(
                path: account.shell, argv: ["-" + shellName], environment: environment,
                workingDirectory: workingDirectory, credentials: credentials,
                waitsForSystemBus: false, terminalOwner: terminalOwner)
        }
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
