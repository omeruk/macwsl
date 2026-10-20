import ArgumentParser

/// One command-line option, described once and shared by the parser declarations in `MacWSL`
/// and by `ArgumentNormalizer`, so the two cannot disagree about spellings or arity.
struct CLIOption: Sendable, Equatable {
    enum Role: Sendable {
        /// Selects what `macwsl` does. At most one action may be given.
        case action
        /// Adjusts an action, or the shell / command when no action is given.
        case modifier
        /// Everything after this flag is a command line (`-e`).
        case command
    }

    let short: Character?
    let long: String
    let role: Role
    let takesValue: Bool

    init(short: Character? = nil, long: String, role: Role, takesValue: Bool = false) {
        self.short = short
        self.long = long
        self.role = role
        self.takesValue = takesValue
    }

    /// The names passed to `@Flag` and `@Option`.
    var names: NameSpecification {
        if let short {
            [.customShort(short), .customLong(long)]
        } else {
            [.customLong(long)]
        }
    }

    /// The spelling used in error messages, for example `--distribution (-d)`.
    var displayName: String {
        if let short {
            "--\(long) (-\(short))"
        } else {
            "--\(long)"
        }
    }
}

extension CLIOption {
    // Running commands.
    static let distribution = CLIOption(
        short: "d", long: "distribution", role: .modifier, takesValue: true)
    static let user = CLIOption(short: "u", long: "user", role: .modifier, takesValue: true)
    static let cd = CLIOption(long: "cd", role: .modifier, takesValue: true)
    static let exec = CLIOption(short: "e", long: "exec", role: .command)

    // Managing distributions.
    static let install = CLIOption(long: "install", role: .action)
    static let list = CLIOption(short: "l", long: "list", role: .action)
    static let verbose = CLIOption(short: "v", long: "verbose", role: .modifier)
    static let online = CLIOption(short: "o", long: "online", role: .modifier)
    static let setDefault = CLIOption(
        short: "s", long: "set-default", role: .action, takesValue: true)
    static let terminate = CLIOption(short: "t", long: "terminate", role: .action, takesValue: true)
    static let shutdown = CLIOption(long: "shutdown", role: .action)
    static let export = CLIOption(long: "export", role: .action, takesValue: true)
    static let `import` = CLIOption(long: "import", role: .action, takesValue: true)
    static let unregister = CLIOption(long: "unregister", role: .action, takesValue: true)

    // General. `--version` is long-only in the parser because `-v` belongs to `--verbose`;
    // `ArgumentNormalizer` rewrites a `-v` that does not follow `--list` to `--version`.
    static let status = CLIOption(long: "status", role: .action)
    static let version = CLIOption(long: "version", role: .action)

    // Provided by ArgumentParser itself. Listed so the normalizer treats them as actions.
    static let help = CLIOption(short: "h", long: "help", role: .action)
    static let generateCompletionScript = CLIOption(
        long: "generate-completion-script", role: .action, takesValue: true)

    static let all: [CLIOption] = [
        distribution, user, cd, exec,
        install, list, verbose, online, setDefault, terminate, shutdown, export, `import`,
        unregister,
        status, version, help, generateCompletionScript,
    ]
}
