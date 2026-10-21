#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

extension Signal {
    /// The signal's number on the platform this code runs on.
    public var localNumber: Int32 {
        switch self {
        case .hup: SIGHUP
        case .int: SIGINT
        case .quit: SIGQUIT
        case .ill: SIGILL
        case .trap: SIGTRAP
        case .abrt: SIGABRT
        case .bus: SIGBUS
        case .fpe: SIGFPE
        case .kill: SIGKILL
        case .usr1: SIGUSR1
        case .segv: SIGSEGV
        case .usr2: SIGUSR2
        case .pipe: SIGPIPE
        case .alrm: SIGALRM
        case .term: SIGTERM
        case .chld: SIGCHLD
        case .cont: SIGCONT
        case .stop: SIGSTOP
        case .tstp: SIGTSTP
        case .ttin: SIGTTIN
        case .ttou: SIGTTOU
        case .urg: SIGURG
        case .xcpu: SIGXCPU
        case .xfsz: SIGXFSZ
        case .vtalrm: SIGVTALRM
        case .prof: SIGPROF
        case .winch: SIGWINCH
        case .io: SIGIO
        case .sys: SIGSYS
        }
    }

    public init?(localNumber: Int32) {
        guard let signal = Self.allCases.first(where: { $0.localNumber == localNumber }) else {
            return nil
        }
        self = signal
    }
}
