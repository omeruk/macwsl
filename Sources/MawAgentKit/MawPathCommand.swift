import MawCore

/// `mawpath`, which translates paths between the Mac and the distribution, as `wslpath` does
/// between Windows and WSL. It is the agent's binary under another name: `/usr/local/bin/mawpath`
/// links to `/run/maw/maw-agent` (`MawPathLink`).
///
/// ```
/// mawpath [-u] <path>   a Mac path's place under /mnt/mac (the default)
/// mawpath -m <path>     the Mac path of a path under /mnt/mac
/// mawpath -a ...        an absolute result for a relative path
/// ```
///
/// The translation is textual (`MacPath`); the path need not exist. The Mac home directory
/// comes from the kernel command line (`MacShare.home(fromCommandLine:)`), which the daemon
/// writes.
public enum MawPathCommand {
    public static let name = "mawpath"

    public static let usage = """
        usage: mawpath [-u | -m] [-a] <path>

        Translates a path between the Mac and Linux, as wslpath does between Windows and WSL.
        The Mac's home directory is /mnt/mac in Linux.

          -u   Mac to Linux, the default: /Users/you/Projects becomes /mnt/mac/Projects.
          -m   Linux to Mac: /mnt/mac/Projects becomes /Users/you/Projects.
          -a   Print an absolute path. A relative path is resolved against the current
               directory first; without -a, a relative path gives a relative result.
          -h, --help
               Print this help.

        The path need not exist. A path that the other side cannot see, outside the Mac's
        home directory or outside /mnt/mac, is an error.
        """

    /// What `mawpath` prints and its exit status.
    public struct Outcome: Equatable, Sendable {
        public var status: Int32
        public var output: String
        public var error: String
    }

    /// Runs `mawpath` with `arguments`, its arguments after its name. `commandLine` is the
    /// kernel command line, or `nil` if it cannot be read; `currentDirectory` is the working
    /// directory, or `nil` if it cannot be read.
    public static func run(
        _ arguments: [String], commandLine: () -> String?, currentDirectory: () -> String?
    ) -> Outcome {
        var toMac = false
        var toLinux = false
        var absolute = false
        var operands: [String] = []
        var optionsEnded = false
        for argument in arguments {
            if optionsEnded || !argument.hasPrefix("-") || argument == "-" {
                operands.append(argument)
                continue
            }
            switch argument {
            case "--":
                optionsEnded = true
            case "-h", "--help":
                return Outcome(status: 0, output: usage + "\n", error: "")
            default:
                for flag in argument.dropFirst() {
                    switch flag {
                    case "u": toLinux = true
                    case "m": toMac = true
                    case "a": absolute = true
                    case "w":
                        return failure("-w is not offered: the Mac has no Windows paths", 64)
                    default:
                        return failure("unknown option -\(flag)\n\(usage)", 64)
                    }
                }
            }
        }
        guard !(toMac && toLinux) else { return failure("-u and -m exclude each other", 64) }
        guard operands.count == 1, let path = operands.first, !path.isEmpty else {
            return failure("expected one path\n\(usage)", 64)
        }
        guard let home = commandLine().flatMap(MacShare.home(fromCommandLine:)),
            let paths = MacPath(home: home)
        else {
            return failure(
                "the Mac's home directory is not known in this machine: the kernel command"
                    + " line carries no valid \(MacShare.homeKernelArgument)", 1)
        }

        var source = path
        if !path.hasPrefix("/") {
            guard absolute else {
                return Outcome(status: 0, output: MacPath.normalized(path) + "\n", error: "")
            }
            guard let directory = currentDirectory() else {
                return failure("the current directory cannot be read", 1)
            }
            // A relative path names a place in the current directory, which is Linux's. For
            // -u, the result is that place; for -m, its Mac path.
            source = MacPath.absolute(path, in: directory)
            if !toMac {
                return Outcome(status: 0, output: source + "\n", error: "")
            }
        }
        if toMac {
            guard let translated = paths.macPath(forLinux: source) else {
                return failure(
                    "\(source) is not under \(MacShare.linuxPath), so the Mac cannot see it", 1)
            }
            return Outcome(status: 0, output: translated + "\n", error: "")
        }
        guard let translated = paths.linuxPath(forMac: source) else {
            return failure(
                "\(source) is not under the Mac's home directory, \(paths.home), so Linux"
                    + " cannot see it", 1)
        }
        return Outcome(status: 0, output: translated + "\n", error: "")
    }

    private static func failure(_ message: String, _ status: Int32) -> Outcome {
        Outcome(status: status, output: "", error: "mawpath: \(message)\n")
    }
}

/// What the agent's binary does, from its name and arguments.
public enum AgentCommand: Equatable, Sendable {
    case serve
    case selfTest
    case mountMacShare(root: String, tag: String)
    /// `network-dns`: writes the drop-ins that turn off DHCP and router-advertised DNS for
    /// every `.network` file (`NetworkDNS`), from the boot's unit before systemd-networkd.
    case networkDNS
    /// `login-shell <operands>`, as `runuser -l`'s shell helper (`LoginShellHelper`).
    case loginShell([String])
    /// The binary was started as `mawpath`, by a link of that name.
    case mawpath([String])
    case version
    case usage(status: Int32)

    /// `argv` is the whole argument vector. The binary is `mawpath` when the last path
    /// component of `argv[0]` is exactly `mawpath`; a login shell's name, such as
    /// `-maw-agent`, which `runuser -l` gives the helper, never is.
    public init(argv: [String]) {
        let name = argv.first.flatMap { $0.split(separator: "/").last.map(String.init) } ?? ""
        let arguments = Array(argv.dropFirst())
        if name == MawPathCommand.name {
            self = .mawpath(arguments)
            return
        }
        switch arguments.first {
        case nil: self = .serve
        case "--version": self = .version
        case "self-test": self = .selfTest
        case "mount-mac-share":
            let operands = arguments.dropFirst()
            self =
                operands.count == 2
                ? .mountMacShare(root: operands.first!, tag: operands.last!) : .usage(status: 64)
        case "network-dns":
            self = arguments.count == 1 ? .networkDNS : .usage(status: 64)
        case LoginShellHelper.subcommand:
            self = .loginShell(Array(arguments.dropFirst()))
        default:
            self = .usage(status: 64)
        }
    }
}
