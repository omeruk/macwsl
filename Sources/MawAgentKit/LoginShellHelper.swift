import CMawSystem
import MawCore
import MawProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// The shell helper of a login shell that starts in a working directory
/// (docs/decisions/0022-working-directory-and-logind.md).
///
/// `runuser -l` opens the PAM session, which registers the shell with `systemd-logind`, and
/// always changes to the home directory. The agent therefore runs as
/// `runuser -l <user> -s /run/maw/maw-agent -- login-shell <directory> <mode> <shell>`: as the
/// user, inside the session, the helper enters the directory, reports the result to the agent
/// on descriptor 3, closes it, and executes the user's shell as a login shell. With the mode
/// `fall-back`, a directory it cannot enter leaves it in the home directory; with `exact`, it
/// exits without starting the shell.
public enum LoginShellHelper {
    /// The subcommand, the first argument after the helper's own name.
    public static let subcommand = "login-shell"
    /// The descriptor on which the helper reports to the agent.
    static let reportDescriptor: Int32 = 3
    /// How long the agent waits for the report once `runuser` runs: the PAM session, and
    /// `pam_systemd`'s wait for `systemd-logind`, come first. The host waits 10 seconds for
    /// `started`, and the system bus up to 2 seconds before this.
    static let reportTimeout = Duration.seconds(5)

    /// The helper's arguments after `--`.
    static func arguments(directory: String, fallsBack: Bool, shell: String) -> [String] {
        [subcommand, directory, fallsBack ? "fall-back" : "exact", shell]
    }

    /// What the helper reports: 8 bytes, the outcome and an errno value, in the host's byte
    /// order (both ends are the same machine).
    enum Report: Equatable {
        /// The helper entered the directory.
        case entered
        /// The helper could not enter it, with this errno value, and stays in the home
        /// directory.
        case fellBack(Int32)
        /// The helper could not enter it, with this errno value, and exits.
        case failed(Int32)

        var bytes: [UInt8] {
            let (kind, error): (Int32, Int32) =
                switch self {
                case .entered: (1, 0)
                case .fellBack(let error): (2, error)
                case .failed(let error): (3, error)
                }
            return withUnsafeBytes(of: kind) { Array($0) }
                + withUnsafeBytes(of: error) { Array($0) }
        }

        init?(bytes: [UInt8]) {
            guard bytes.count == 8 else { return nil }
            let kind = bytes[0..<4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            let error = bytes[4..<8].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            switch kind {
            case 1: self = .entered
            case 2: self = .fellBack(error)
            case 3: self = .failed(error)
            default: return nil
            }
        }
    }

    /// The system calls that the helper makes, so that tests can supply them.
    struct System: Sendable {
        var changeDirectory: @Sendable (String) -> Int32
        /// Whether descriptor 3 is the agent's pipe; a helper run by hand writes nothing.
        var reportDescriptorIsPipe: @Sendable () -> Bool
        var write: @Sendable ([UInt8]) -> Void
        var closeReportDescriptor: @Sendable () -> Void
        var setEnvironment: @Sendable (String, String) -> Void
        /// Executes the program with the argument vector; returns only on failure, with errno.
        var execute: @Sendable (String, [String]) -> Int32
        var printError: @Sendable (String) -> Void

        static let live = System(
            changeDirectory: { chdir($0) == 0 ? 0 : errno },
            reportDescriptorIsPipe: {
                var status = stat()
                return fstat(LoginShellHelper.reportDescriptor, &status) == 0
                    && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO)
            },
            write: { bytes in
                _ = bytes.withUnsafeBytes {
                    CLibrary.write(LoginShellHelper.reportDescriptor, $0.baseAddress, $0.count)
                }
            },
            closeReportDescriptor: { close(LoginShellHelper.reportDescriptor) },
            setEnvironment: { setenv($0, $1, 1) },
            execute: { path, argv in
                let pointers = argv.map { strdup($0) } + [nil]
                defer {
                    for pointer in pointers { free(pointer) }
                }
                execv(path, pointers)
                return errno
            },
            printError: { text in
                let line = text + "\n"
                _ = line.withCString { CLibrary.write(STDERR_FILENO, $0, strlen($0)) }
            })
    }

    /// Runs the helper with its arguments after `login-shell`, and returns the exit status if
    /// it does not execute the shell.
    public static func run(_ operands: [String]) -> Int32 {
        run(operands, system: .live)
    }

    static func run(_ operands: [String], system: System) -> Int32 {
        guard operands.count == 3, operands[1] == "fall-back" || operands[1] == "exact",
            operands[0].hasPrefix("/"), operands[2].hasPrefix("/")
        else {
            system.printError(
                "usage: maw-agent \(subcommand) <directory> fall-back|exact <shell>")
            return 64
        }
        let (directory, fallsBack, shell) = (operands[0], operands[1] == "fall-back", operands[2])
        let report: Report
        let error = system.changeDirectory(directory)
        if error == 0 {
            report = .entered
        } else if fallsBack {
            report = .fellBack(error)
        } else {
            report = .failed(error)
        }
        let isPipe = system.reportDescriptorIsPipe()
        if isPipe {
            system.write(report.bytes)
        }
        // Before the shell starts: no descriptor of the agent's reaches the user's programs.
        system.closeReportDescriptor()
        if case .failed = report {
            return 1
        }
        // runuser -l sets SHELL to the helper; the user's own shell is the account's.
        system.setEnvironment("SHELL", shell)
        let name = shell.split(separator: "/").last.map(String.init) ?? "sh"
        let failure = system.execute(shell, ["-" + name])
        system.printError("maw-agent: cannot start \(shell): \(String(cString: strerror(failure)))")
        return 127
    }

    /// Waits for the helper's report on `reader`, at most until `deadline`. `nil` if the
    /// helper's side closed without a report, which happens when `runuser` ends first, or if
    /// the deadline passed.
    static func awaitReport(on reader: Int32, until deadline: ContinuousClock.Instant)
        -> (report: Report?, timedOut: Bool)
    {
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 8)
        while received.count < 8 {
            let remaining = deadline - .now
            guard remaining > .zero else { return (nil, true) }
            var request = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(min(remaining.milliseconds + 1, 60_000))
            let ready = poll(&request, 1, milliseconds)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else {
                if ready == 0 { continue }
                return (nil, false)
            }
            let count = read(reader, &buffer, 8 - received.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { return (nil, false) }
            received += buffer[..<count]
        }
        return (Report(bytes: received), false)
    }
}

/// The C library's `write`, which the closures above cannot name directly: inside them,
/// `write` is the `System` property.
private enum CLibrary {
    static func write(_ descriptor: Int32, _ bytes: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
            Darwin.write(descriptor, bytes, count)
        #elseif canImport(Glibc)
            Glibc.write(descriptor, bytes, count)
        #elseif canImport(Musl)
            Musl.write(descriptor, bytes, count)
        #endif
    }
}

extension WorkingDirectoryFallback {
    /// The reason for an errno value of a failed change to `directory`. A directory under
    /// `/mnt/mac` that does not exist while the share is not mounted is `shareNotMounted`.
    init(error: Int32, directory: String, shareMounted: () -> Bool) {
        switch error {
        case ENOENT where MacShare.contains(linuxPath: directory) && !shareMounted():
            self = .shareNotMounted
        case ENOENT:
            self = .notFound
        case EACCES, EPERM:
            self = .permissionDenied
        case ENOTDIR:
            self = .notADirectory
        default:
            self = .other
        }
    }
}
