import MawCore
import MawProtocol

/// What a shell or command session runs, and where, derived from an `Action` before anything
/// connects to the daemon.
struct SessionPlan: Equatable, Sendable {
    /// The machine to run on; `nil` means the default distribution's.
    var machine: MachineID?
    var program: ExecProgram
    /// The user to run as; `nil` means the distribution's default user.
    var user: String?
    /// The working directory; `nil` means the user's home directory.
    var workingDirectory: String?

    init(
        machine: MachineID?, program: ExecProgram, user: String? = nil,
        workingDirectory: String? = nil
    ) {
        self.machine = machine
        self.program = program
        self.user = user
        self.workingDirectory = workingDirectory
    }

    /// Maps `.shell`, `.run`, and `.exec`; other actions have no session.
    init(_ action: Action) throws(MawError) {
        let session: Session
        switch action {
        case .shell(let selected):
            session = selected
            program = .loginShell
        case .run(let command, let selected):
            session = selected
            program = Self.shellCommand(command)
        case .exec(let command, let selected):
            session = selected
            program = .argv(command)
        default:
            throw .notImplemented(feature: action.displayName, phase: action.phase)
        }
        user = session.user
        workingDirectory = try Self.workingDirectory(session.directory)
        machine = MachineResolver.machine(for: session.distro)
    }

    /// `maw <command> [<argument>...]` passes its arguments to the user's shell as one command
    /// line, joined with spaces, as `wsl.exe` does. The Mac's shell has already removed any
    /// quoting, so `maw echo "a  b"` prints `a b`; `-e` passes arguments unchanged.
    static func shellCommand(_ arguments: [String]) -> ExecProgram {
        .shellCommand(arguments.joined(separator: " "))
    }

    /// Top-level directories that exist on macOS but not in a Linux distribution. A `--cd`
    /// path under one of them is a macOS path, which phase 07 translates.
    static let macOSDirectories = [
        "/Users", "/Volumes", "/Applications", "/Library", "/System", "/private",
    ]

    /// `nil` (the home directory) by default; otherwise `directory`, which must be an absolute
    /// Linux path.
    static func workingDirectory(_ directory: String?) throws(MawError) -> String? {
        guard let directory else { return nil }
        let isMacOSPath = macOSDirectories.contains {
            directory == $0 || directory.hasPrefix($0 + "/")
        }
        guard directory.hasPrefix("/"), !isMacOSPath else {
            throw .unsupportedDirectory(directory)
        }
        return directory
    }
}

/// Chooses the machine for a session.
enum MachineResolver {
    /// The machine of `distro`, or `nil` for the default distribution's, which the daemon
    /// resolves. The daemon also reports a distribution that is not installed, or that none is.
    static func machine(for distro: DistroName?) -> MachineID? {
        distro.map { .distribution($0) }
    }
}

/// How a session's standard streams reach the guest.
enum SessionMode: Equatable, Sendable {
    /// A pseudo-terminal in the guest; the local terminal is in raw mode.
    case terminal
    /// Separate pipes for standard input, output, and error.
    case pipes

    /// A terminal when standard input and standard output both are one, as in ssh.
    static func select(inputIsTerminal: Bool, outputIsTerminal: Bool) -> SessionMode {
        inputIsTerminal && outputIsTerminal ? .terminal : .pipes
    }

    /// The environment the guest process gets on top of the agent's defaults.
    func environment(host: [String: String]) -> [String: String] {
        if let term = host["TERM"], !term.isEmpty {
            return ["TERM": term]
        }
        return self == .terminal ? ["TERM": "xterm-256color"] : [:]
    }
}
