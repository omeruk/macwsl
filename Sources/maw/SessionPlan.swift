import MawCore
import MawProtocol

/// What a shell or command session runs, and where, derived from an `Action` before anything
/// connects to the daemon.
struct SessionPlan: Equatable, Sendable {
    /// Until phase 05 there is no login shell to look up; the initramfs has busybox `sh`.
    static let shell = "/bin/sh"

    var machine: MachineID
    var argv: [String]
    var workingDirectory: String

    init(machine: MachineID, argv: [String], workingDirectory: String) {
        self.machine = machine
        self.argv = argv
        self.workingDirectory = workingDirectory
    }

    /// Maps `.shell`, `.run`, and `.exec`; other actions have no session.
    init(_ action: Action) throws(MawError) {
        let session: Session
        switch action {
        case .shell(let selected):
            session = selected
            argv = [Self.shell, "-l"]
        case .run(let command, let selected):
            session = selected
            argv = Self.shellCommand(command)
        case .exec(let command, let selected):
            session = selected
            argv = command
        default:
            throw .notImplemented(feature: action.displayName, phase: action.phase)
        }
        if session.user != nil {
            throw .notImplemented(feature: CLIOption.user.displayName, phase: "05")
        }
        workingDirectory = try Self.workingDirectory(session.directory)
        machine = try MachineResolver.machine(for: session.distro)
    }

    /// `maw <command> [<argument>...]` passes its arguments to the shell as one command line,
    /// joined with spaces, as `wsl.exe` does. The Mac's shell has already removed any quoting,
    /// so `maw echo "a  b"` prints `a b`; `-e` passes arguments unchanged.
    static func shellCommand(_ arguments: [String]) -> [String] {
        [shell, "-c", arguments.joined(separator: " ")]
    }

    /// Top-level directories that exist on macOS but not in a Linux distribution. A `--cd`
    /// path under one of them is a macOS path, which phase 07 translates.
    static let macOSDirectories = [
        "/Users", "/Volumes", "/Applications", "/Library", "/System", "/private",
    ]

    /// `/` by default; otherwise `directory`, which must be an absolute Linux path.
    static func workingDirectory(_ directory: String?) throws(MawError) -> String {
        guard let directory else { return "/" }
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
    /// The machine for `distro`, or for the default distribution when it is `nil`.
    ///
    /// PHASE 05: No distribution can be installed yet, so `-d` always fails and the default
    /// falls back to the initramfs machine. Phase 05 resolves installed distributions here,
    /// and replaces the fallback with a "no distribution installed" error.
    static func machine(for distro: DistroName?) throws(MawError) -> MachineID {
        if let distro {
            throw .distributionNotInstalled(distro)
        }
        return .initramfs
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
