import Darwin
import Foundation
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
    /// The working directory in Linux; `nil` means the user's home directory, and `~/<path>` a
    /// path under it.
    var workingDirectory: String?
    /// Whether the guest may start in the home directory when it cannot enter
    /// `workingDirectory`: only for the directory that maw translated from its own.
    var fallsBackToHome: Bool
    /// A line for standard error before the session starts, when maw chose the home directory
    /// because its own directory is not shared.
    var notice: String?

    init(
        machine: MachineID?, program: ExecProgram, user: String? = nil,
        workingDirectory: String? = nil, fallsBackToHome: Bool = false, notice: String? = nil
    ) {
        self.machine = machine
        self.program = program
        self.user = user
        self.workingDirectory = workingDirectory
        self.fallsBackToHome = fallsBackToHome
        self.notice = notice
    }

    /// Maps `.shell`, `.run`, and `.exec` to their sessions, and every other action, which has
    /// no session, to `nil`.
    init?(_ action: Action, mac: MacDirectories = .live) throws(MawError) {
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
            return nil
        }
        user = session.user
        let choice = try WorkingDirectory.choose(session.directory, mac: mac)
        workingDirectory = choice.directory
        fallsBackToHome = choice.fallsBackToHome
        notice = choice.notice
        machine = MachineResolver.machine(for: session.distro)
    }

    /// `maw <command> [<argument>...]` passes its arguments to the user's shell as one command
    /// line, joined with spaces, as `wsl.exe` does. The Mac's shell has already removed any
    /// quoting, so `maw echo "a  b"` prints `a b`, and `maw -- sh -c 'echo a; echo b'` runs
    /// `sh -c echo a; echo b`; `-e` passes arguments unchanged.
    static func shellCommand(_ arguments: [String]) -> ExecProgram {
        .shellCommand(arguments.joined(separator: " "))
    }

    /// Top-level directories that exist on macOS but not in a Linux distribution. A `--cd`
    /// path under one of them is a macOS path, which is translated if it is under the home
    /// directory; any other absolute path is a Linux path.
    static let macOSDirectories = [
        "/Users", "/Volumes", "/Applications", "/Library", "/System", "/private",
    ]

    static func isMacOSPath(_ path: String) -> Bool {
        macOSDirectories.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

/// What the Mac tells maw about directories, so that tests can supply it.
struct MacDirectories: Sendable {
    /// The current directory from `getcwd`, or the errno value with which it failed.
    var current: @Sendable () -> CurrentDirectory
    /// The owner's home directory, as the daemon shares it.
    var home: String
    /// `realpath(3)` of an existing path, or `nil`.
    var resolve: @Sendable (String) -> String?

    /// What `getcwd` returned.
    enum CurrentDirectory: Equatable, Sendable {
        case path(String)
        case failed(errno: Int32)
    }

    static let live = MacDirectories(
        current: {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            guard getcwd(&buffer, buffer.count) != nil else {
                return .failed(errno: errno)
            }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return .path(String(decoding: bytes, as: UTF8.self))
        },
        home: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false),
        resolve: { path in
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        })
}

/// The session's working directory (docs/decisions/0022-working-directory-and-logind.md).
///
/// Without `--cd`, the session starts in the Linux path of maw's current directory: the home
/// directory is `/mnt/mac`, and a directory under it `/mnt/mac/<the rest>`. Both are resolved
/// before they are compared, so a home directory reached through a link still matches.
/// Outside the home directory, or when `getcwd` fails, the session starts in the Linux home
/// directory, with a notice. With `--cd`, `~` and `~/<path>` are the Linux home directory and a
/// path under it, an absolute Linux path is used as given, a macOS path under the home
/// directory is translated, and a relative path is resolved against the current directory and
/// translated; a Mac path outside the home directory is an error. Only the translated current
/// directory may fall back to the home directory in the guest.
enum WorkingDirectory {
    struct Choice: Equatable {
        var directory: String?
        var fallsBackToHome = false
        var notice: String? = nil
    }

    static let homeNotice = "starting in the home directory."

    static func choose(_ requested: String?, mac: MacDirectories) throws(MawError) -> Choice {
        guard let requested else {
            switch mac.current() {
            case .failed(let error):
                return Choice(directory: nil, notice: unreadableNotice(error))
            case .path(let current):
                guard let linux = linuxPath(of: current, mac: mac) else {
                    return Choice(
                        directory: nil,
                        notice: "maw: \(current) is not shared with Linux; \(homeNotice)")
                }
                return Choice(directory: linux, fallsBackToHome: true)
            }
        }
        if requested == "~" {
            return Choice(directory: nil)
        }
        if requested.hasPrefix("~/") {
            return Choice(directory: requested)
        }
        if requested.hasPrefix("/") {
            guard SessionPlan.isMacOSPath(requested) else {
                return Choice(directory: requested)
            }
            guard let linux = linuxPath(of: requested, mac: mac) else {
                throw .directoryNotShared(requested)
            }
            return Choice(directory: linux)
        }
        let current: String
        switch mac.current() {
        case .failed(let error):
            throw .currentDirectoryUnreadable(reason: String(cString: strerror(error)))
        case .path(let directory):
            current = directory
        }
        let absolute = MacPath.absolute(requested, in: current)
        guard let linux = linuxPath(of: absolute, mac: mac) else {
            throw .directoryNotShared(absolute)
        }
        return Choice(directory: linux)
    }

    /// The `/mnt/mac` path of `path`, a Mac path, comparing the resolved path with the
    /// resolved home directory first, and the paths as written after that.
    static func linuxPath(of path: String, mac: MacDirectories) -> String? {
        let resolvedHome = mac.resolve(mac.home) ?? mac.home
        let resolvedPath = mac.resolve(path) ?? path
        if let translated = MacPath(home: resolvedHome)?.linuxPath(forMac: resolvedPath) {
            return translated
        }
        return MacPath(home: mac.home)?.linuxPath(forMac: path)
    }

    static func unreadableNotice(_ error: Int32) -> String {
        error == ENOENT
            ? "maw: the current directory no longer exists; \(homeNotice)"
            : "maw: the current directory cannot be read (\(String(cString: strerror(error))));"
                + " \(homeNotice)"
    }

    /// The line that says why the guest started in the home directory instead of
    /// `directory`, which maw translated; `distribution` names the console log.
    static func fallbackLine(
        _ fallback: WorkingDirectoryFallback, directory: String, distribution: String
    ) -> String {
        switch fallback {
        case .shareNotMounted:
            "maw: \(MacShare.linuxPath) is not mounted in \(distribution); \(homeNotice)"
                + " ~/Library/Logs/maw/\(distribution).log says why."
        case .notFound:
            "maw: \(directory) does not exist in Linux; \(homeNotice)"
        case .permissionDenied:
            "maw: \(directory) cannot be entered (permission denied); \(homeNotice)"
        case .notADirectory:
            "maw: \(directory) is not a directory in Linux; \(homeNotice)"
        case .other:
            "maw: \(directory) cannot be entered in Linux; \(homeNotice)"
        }
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
