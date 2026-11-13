#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The messages that control frames carry. docs/protocol.md specifies each one.
///
/// On the wire each message is a JSON object with a single key, the message's name, whose value
/// holds its fields: `{"signal":{"name":"INT"}}`. Messages without fields have an empty object.
public enum ControlMessage: Equatable, Sendable {
    // Requests: the first control message on a connection, host to guest.

    /// Runs a command. The connection then carries the session.
    case exec(ExecRequest)
    /// Asks for `agentInfo`.
    case info
    /// Asks the guest to power off. The agent replies with `shutdownAcknowledged`.
    case shutdown
    /// Asks the agent to open a connection to the host's `AgentProtocol.dialBackPort` and to
    /// send this nonce first on it. The agent replies with `dialedBack`, and serves the dialed
    /// connection as a new one: its first request may be `exec`, `info`, or `shutdown`.
    /// Accepted only on a connection that the host opened.
    case dialBack(DialBackNonce)
    /// Asks for `sampled`: the guest's memory figures and its IPv4 address.
    case sample

    // During an exec session, host to guest.

    /// No more standard input. In terminal mode, the terminal's end-of-file character is sent.
    case stdinEOF
    /// Delivers a signal: to the process group in pipe mode, to the terminal's foreground
    /// process group in terminal mode.
    case signal(Signal)
    /// Changes the terminal's window size. Ignored in pipe mode.
    case resize(TerminalSize)
    /// Asks which program runs in the foreground of the session's terminal. The agent answers
    /// with `foregroundProgram` and the same `id`, a counter of the host's, so that a late
    /// reply to a query that the host stopped waiting for never answers a later one.
    case foregroundQuery(id: UInt32)

    // Guest to host.

    /// The command started with this process ID.
    case started(pid: Int32)
    /// The command ended. The last message of an exec session.
    case exited(ExitStatus)
    /// The reply to `info`.
    case agentInfo(AgentInfo)
    /// The reply to `shutdown`: the guest is powering off.
    case shutdownAcknowledged
    /// The reply to `dialBack`: the agent has connected to the host and queued the nonce on
    /// that connection.
    case dialedBack
    /// The reply to `foregroundQuery` with the same `id`. `program` is `nil` when no program
    /// other than the session's shell is in the foreground, which is always the case in pipe
    /// mode and after the process has exited.
    case foregroundProgram(id: UInt32, program: ForegroundProcess?)
    /// The reply to `sample`.
    case sampled(GuestSample)
    /// A request failed, or the connection is being closed because of a protocol error.
    case error(AgentError)

    /// The message's key on the wire.
    public var name: String {
        switch self {
        case .exec: "exec"
        case .info: "info"
        case .shutdown: "shutdown"
        case .dialBack: "dialBack"
        case .sample: "sample"
        case .stdinEOF: "stdinEOF"
        case .signal: "signal"
        case .resize: "resize"
        case .foregroundQuery: "foregroundQuery"
        case .started: "started"
        case .exited: "exited"
        case .agentInfo: "agentInfo"
        case .shutdownAcknowledged: "shutdownAcknowledged"
        case .dialedBack: "dialedBack"
        case .foregroundProgram: "foregroundProgram"
        case .sampled: "sampled"
        case .error: "error"
        }
    }
}

/// What an exec session runs.
public enum ExecProgram: Equatable, Sendable {
    /// A program and its arguments, run as they are. A program name without a slash is
    /// searched for in the session's PATH.
    case argv([String])
    /// A command line, run by the user's shell from `/etc/passwd` as `<shell> -c <command>`.
    case shellCommand(String)
    /// The user's shell from `/etc/passwd`, as a login shell.
    case loginShell
}

extension ExecProgram: CustomStringConvertible {
    /// The command as a person would type it, for messages: `ls -l`, the shell's command line,
    /// or `the login shell`.
    public var description: String {
        switch self {
        case .argv(let argv): argv.joined(separator: " ")
        case .shellCommand(let command): command
        case .loginShell: "the login shell"
        }
    }
}

extension ExecProgram: Codable {
    private enum CodingKeys: String, CodingKey {
        case argv, shellCommand, loginShell
    }

    private struct Empty: Codable {}

    /// One key, as in control messages: `{"argv":[...]}`, `{"shellCommand":"..."}`, or
    /// `{"loginShell":{}}`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "a program has exactly one of argv, shellCommand, loginShell")
            )
        }
        switch key {
        case .argv:
            self = .argv(try container.decode([String].self, forKey: .argv))
        case .shellCommand:
            self = .shellCommand(try container.decode(String.self, forKey: .shellCommand))
        case .loginShell:
            _ = try container.decode(Empty.self, forKey: .loginShell)
            self = .loginShell
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .argv(let argv): try container.encode(argv, forKey: .argv)
        case .shellCommand(let command): try container.encode(command, forKey: .shellCommand)
        case .loginShell: try container.encode(Empty(), forKey: .loginShell)
        }
    }
}

/// A command to run in the guest.
public struct ExecRequest: Codable, Equatable, Sendable {
    public var program: ExecProgram
    /// The user to run as. `nil` means the distribution's default user, `[user] default` in
    /// `/etc/maw.conf`, or root if it names none.
    public var user: String?
    /// The locale the host prefers, such as `tr_TR.UTF-8`. The session's `LANG` is this locale
    /// if the guest has it, and `C.UTF-8` otherwise.
    public var locale: String?
    /// Environment variables, applied on top of the session's login environment.
    public var environment: [String: String]
    /// The working directory. `nil` means the user's home directory.
    public var workingDirectory: String?
    /// The initial window size of a pseudo-terminal, or `nil` for separate pipes.
    public var terminal: TerminalSize?

    public init(
        program: ExecProgram, user: String? = nil, locale: String? = nil,
        environment: [String: String] = [:], workingDirectory: String? = nil,
        terminal: TerminalSize? = nil
    ) {
        self.program = program
        self.user = user
        self.locale = locale
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.terminal = terminal
    }

    /// Runs `argv` as root, as `mawd debug-boot` does on the initramfs machine.
    public init(
        argv: [String], environment: [String: String] = [:], workingDirectory: String? = nil,
        terminal: TerminalSize? = nil
    ) {
        self.init(
            program: .argv(argv), environment: environment, workingDirectory: workingDirectory,
            terminal: terminal)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        program = try container.decode(ExecProgram.self, forKey: .program)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        locale = try container.decodeIfPresent(String.self, forKey: .locale)
        environment =
            try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        terminal = try container.decodeIfPresent(TerminalSize.self, forKey: .terminal)
    }
}

/// A terminal's window size in character cells.
public struct TerminalSize: Codable, Equatable, Sendable {
    public var rows: UInt16
    public var columns: UInt16

    public init(rows: UInt16, columns: UInt16) {
        self.rows = rows
        self.columns = columns
    }
}

/// The program in the foreground of a session's terminal, other than the session's shell: the
/// terminal's foreground process group.
public struct ForegroundProcess: Equatable, Sendable {
    /// The foreground process group's ID in the guest.
    public var processGroup: Int32
    /// The command name of the group's leader, as `/proc/<pid>/comm` shows it: at most 15
    /// bytes. `nil` when the leader has exited, as it may have in a pipeline. It comes from the
    /// guest; a host sanitizes it before showing it (`ForegroundAnswer`).
    public var name: String?

    public init(processGroup: Int32, name: String?) {
        self.processGroup = processGroup
        self.name = name
    }
}

/// How a process ended.
public enum ExitStatus: Equatable, Sendable, CustomStringConvertible {
    /// It exited with this code (0 to 255).
    case exited(code: Int32)
    /// A signal ended it. The number is Linux's, whatever the host's numbering.
    case signaled(signal: Int32)

    /// The status a shell (and ssh) reports: the exit code, or 128 plus the signal number.
    public var shellStatus: Int32 {
        switch self {
        case .exited(let code): code
        case .signaled(let signal): 128 + signal
        }
    }

    public var description: String {
        switch self {
        case .exited(let code):
            "exited with code \(code)"
        case .signaled(let number):
            if let signal = Signal(linuxNumber: number) {
                "ended by SIG\(signal.rawValue)"
            } else {
                "ended by signal \(number)"
            }
        }
    }
}

/// What `info` returns.
public struct AgentInfo: Codable, Equatable, Sendable {
    public var agentVersion: String
    public var protocolVersion: UInt32
    /// `uname -r`, for example `6.18.2-maw`.
    public var kernelRelease: String
    /// Time since the guest kernel booted.
    public var uptimeMilliseconds: UInt64

    public init(
        agentVersion: String, protocolVersion: UInt32, kernelRelease: String,
        uptimeMilliseconds: UInt64
    ) {
        self.agentVersion = agentVersion
        self.protocolVersion = protocolVersion
        self.kernelRelease = kernelRelease
        self.uptimeMilliseconds = uptimeMilliseconds
    }
}

/// What `sample` returns: figures that only the guest knows. They come from the guest, which
/// can report anything for its own machine, so they are only displayed.
public struct GuestSample: Equatable, Sendable {
    /// `MemTotal` from `/proc/meminfo`.
    public var memoryTotalBytes: UInt64
    /// `MemAvailable` from `/proc/meminfo`; never more than `memoryTotalBytes`.
    public var memoryAvailableBytes: UInt64
    /// The IPv4 address of the interface of the default route, in dotted decimal, or `nil`
    /// without a default route or an address on its interface.
    public var ipv4Address: String?

    public init(memoryTotalBytes: UInt64, memoryAvailableBytes: UInt64, ipv4Address: String?) {
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryAvailableBytes = memoryAvailableBytes
        self.ipv4Address = ipv4Address
    }

    /// Memory in use: `MemTotal` minus `MemAvailable`, which `free` reports as used.
    public var memoryUsedBytes: UInt64 { memoryTotalBytes - memoryAvailableBytes }

    /// Whether `text` is an IPv4 address in dotted decimal: four numbers from 0 to 255, each
    /// of one to three digits.
    public static func isIPv4Address(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4
            && parts.allSatisfy { part in
                (1...3).contains(part.count) && part.allSatisfy { $0.isASCII && $0.isNumber }
                    && Int(part).map { $0 <= 255 } == true
            }
    }
}

/// An error the agent reports.
public struct AgentError: Codable, Equatable, Sendable, CustomStringConvertible {
    public enum Code: String, Codable, Equatable, Sendable {
        /// The two sides speak different protocol versions; `hostVersion` and `guestVersion`
        /// name them.
        case versionMismatch
        /// A frame was malformed, oversized, truncated, of an unknown type, or out of place.
        case protocolViolation
        /// The program was not found in PATH, or the path does not exist. Shells report 127.
        case commandNotFound
        /// The program exists but cannot be executed. Shells report 126.
        case permissionDenied
        /// The process could not be started for another reason, such as a missing working
        /// directory.
        case spawnFailed
        /// The guest could not be asked to power off.
        case shutdownFailed
        /// The agent is serving as many connections as it allows.
        case busy
        /// The requested user, or the default user that `/etc/maw.conf` names, does not exist.
        case userNotFound
        /// The agent could not connect to the host in reply to `dialBack`: no source port
        /// below 1024 was free, or the connection failed or timed out.
        case dialBackFailed
        /// The agent could not read its memory figures for `sample`, for example because
        /// `/proc/meminfo` has no `MemAvailable`.
        case sampleFailed
    }

    public var code: Code
    public var message: String
    public var hostVersion: UInt32?
    public var guestVersion: UInt32?
    /// With `userNotFound`: the user that does not exist.
    public var user: String?

    public init(
        _ code: Code, _ message: String, hostVersion: UInt32? = nil, guestVersion: UInt32? = nil,
        user: String? = nil
    ) {
        self.code = code
        self.message = message
        self.hostVersion = hostVersion
        self.guestVersion = guestVersion
        self.user = user
    }

    public var description: String { "\(code.rawValue): \(message)" }
}

/// A signal, named rather than numbered: macOS and Linux number several signals differently
/// (SIGUSR1, SIGCHLD, SIGSTOP, and others), so a number would be read differently on each
/// side.
public enum Signal: String, Codable, Equatable, Sendable, CaseIterable {
    case hup = "HUP"
    case int = "INT"
    case quit = "QUIT"
    case ill = "ILL"
    case trap = "TRAP"
    case abrt = "ABRT"
    case bus = "BUS"
    case fpe = "FPE"
    case kill = "KILL"
    case usr1 = "USR1"
    case segv = "SEGV"
    case usr2 = "USR2"
    case pipe = "PIPE"
    case alrm = "ALRM"
    case term = "TERM"
    case chld = "CHLD"
    case cont = "CONT"
    case stop = "STOP"
    case tstp = "TSTP"
    case ttin = "TTIN"
    case ttou = "TTOU"
    case urg = "URG"
    case xcpu = "XCPU"
    case xfsz = "XFSZ"
    case vtalrm = "VTALRM"
    case prof = "PROF"
    case winch = "WINCH"
    case io = "IO"
    case sys = "SYS"

    /// The signal's number on Linux (arm64 and x86_64 agree).
    public var linuxNumber: Int32 {
        switch self {
        case .hup: 1
        case .int: 2
        case .quit: 3
        case .ill: 4
        case .trap: 5
        case .abrt: 6
        case .bus: 7
        case .fpe: 8
        case .kill: 9
        case .usr1: 10
        case .segv: 11
        case .usr2: 12
        case .pipe: 13
        case .alrm: 14
        case .term: 15
        case .chld: 17
        case .cont: 18
        case .stop: 19
        case .tstp: 20
        case .ttin: 21
        case .ttou: 22
        case .urg: 23
        case .xcpu: 24
        case .xfsz: 25
        case .vtalrm: 26
        case .prof: 27
        case .winch: 28
        case .io: 29
        case .sys: 31
        }
    }

    public init?(linuxNumber: Int32) {
        guard let signal = Self.allCases.first(where: { $0.linuxNumber == linuxNumber }) else {
            return nil
        }
        self = signal
    }
}

// MARK: JSON

extension ControlMessage: Codable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init(_ name: String) {
            stringValue = name
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    private struct Empty: Codable {}

    private struct SignalFields: Codable {
        var name: Signal
    }

    private struct DialBackFields: Codable {
        var nonce: String
    }

    private struct StartedFields: Codable {
        var pid: Int32
    }

    private struct ExitedFields: Codable {
        var code: Int32?
        var signal: Int32?
    }

    private struct ForegroundQueryFields: Codable {
        var id: UInt32
    }

    private struct ForegroundProgramFields: Codable {
        var id: UInt32
        var processGroup: Int32?
        var name: String?
    }

    private struct SampledFields: Codable {
        var memoryTotalBytes: UInt64
        var memoryAvailableBytes: UInt64
        var ipv4Address: String?
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        let key = Key(name)
        switch self {
        case .exec(let request):
            try container.encode(request, forKey: key)
        case .info, .shutdown, .sample, .stdinEOF, .shutdownAcknowledged, .dialedBack:
            try container.encode(Empty(), forKey: key)
        case .dialBack(let nonce):
            try container.encode(DialBackFields(nonce: nonce.hexadecimal), forKey: key)
        case .signal(let signal):
            try container.encode(SignalFields(name: signal), forKey: key)
        case .resize(let size):
            try container.encode(size, forKey: key)
        case .foregroundQuery(let id):
            try container.encode(ForegroundQueryFields(id: id), forKey: key)
        case .foregroundProgram(let id, let program):
            try container.encode(
                ForegroundProgramFields(
                    id: id, processGroup: program?.processGroup, name: program?.name),
                forKey: key)
        case .started(let pid):
            try container.encode(StartedFields(pid: pid), forKey: key)
        case .exited(.exited(let code)):
            try container.encode(ExitedFields(code: code), forKey: key)
        case .exited(.signaled(let signal)):
            try container.encode(ExitedFields(signal: signal), forKey: key)
        case .agentInfo(let info):
            try container.encode(info, forKey: key)
        case .sampled(let sample):
            try container.encode(
                SampledFields(
                    memoryTotalBytes: sample.memoryTotalBytes,
                    memoryAvailableBytes: sample.memoryAvailableBytes,
                    ipv4Address: sample.ipv4Address),
                forKey: key)
        case .error(let error):
            try container.encode(error, forKey: key)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "a control message must have exactly one key"))
        }
        switch key.stringValue {
        case "exec":
            self = .exec(try container.decode(ExecRequest.self, forKey: key))
        case "info":
            _ = try container.decode(Empty.self, forKey: key)
            self = .info
        case "shutdown":
            _ = try container.decode(Empty.self, forKey: key)
            self = .shutdown
        case "dialBack":
            let text = try container.decode(DialBackFields.self, forKey: key).nonce
            guard let nonce = DialBackNonce(hexadecimal: text) else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath + [key],
                        debugDescription: "the nonce is not "
                            + "\(AgentProtocol.dialBackNonceSize * 2) lowercase hexadecimal digits"
                    ))
            }
            self = .dialBack(nonce)
        case "dialedBack":
            _ = try container.decode(Empty.self, forKey: key)
            self = .dialedBack
        case "sample":
            _ = try container.decode(Empty.self, forKey: key)
            self = .sample
        case "sampled":
            self = .sampled(try Self.sample(container.decode(SampledFields.self, forKey: key)))
        case "stdinEOF":
            _ = try container.decode(Empty.self, forKey: key)
            self = .stdinEOF
        case "signal":
            self = .signal(try container.decode(SignalFields.self, forKey: key).name)
        case "resize":
            self = .resize(try container.decode(TerminalSize.self, forKey: key))
        case "foregroundQuery":
            self = .foregroundQuery(
                id: try container.decode(ForegroundQueryFields.self, forKey: key).id)
        case "foregroundProgram":
            let fields = try container.decode(ForegroundProgramFields.self, forKey: key)
            switch (fields.processGroup, fields.name) {
            case (nil, nil):
                self = .foregroundProgram(id: fields.id, program: nil)
            case (let group?, let name):
                self = .foregroundProgram(
                    id: fields.id, program: ForegroundProcess(processGroup: group, name: name))
            case (nil, _?):
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath + [key],
                        debugDescription: "foregroundProgram has a name without a processGroup"))
            }
        case "started":
            self = .started(pid: try container.decode(StartedFields.self, forKey: key).pid)
        case "exited":
            let fields = try container.decode(ExitedFields.self, forKey: key)
            switch (fields.code, fields.signal) {
            case (let code?, nil):
                self = .exited(.exited(code: code))
            case (nil, let signal?):
                self = .exited(.signaled(signal: signal))
            default:
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath + [key],
                        debugDescription: "exited needs exactly one of code and signal"))
            }
        case "agentInfo":
            self = .agentInfo(try container.decode(AgentInfo.self, forKey: key))
        case "shutdownAcknowledged":
            _ = try container.decode(Empty.self, forKey: key)
            self = .shutdownAcknowledged
        case "error":
            self = .error(try container.decode(AgentError.self, forKey: key))
        default:
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown control message '\(key.stringValue)'"))
        }
    }

    /// Checks a `sampled` reply, which comes from the guest: available memory within the total,
    /// and an address only in dotted decimal.
    private static func sample(_ fields: SampledFields) throws -> GuestSample {
        guard fields.memoryAvailableBytes <= fields.memoryTotalBytes else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: [Key("sampled")],
                    debugDescription: "sampled has more available memory than its total"))
        }
        if let address = fields.ipv4Address, !GuestSample.isIPv4Address(address) {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: [Key("sampled")],
                    debugDescription: "sampled has an ipv4Address that is not an IPv4 address"))
        }
        return GuestSample(
            memoryTotalBytes: fields.memoryTotalBytes,
            memoryAvailableBytes: fields.memoryAvailableBytes, ipv4Address: fields.ipv4Address)
    }

    /// The message as JSON with sorted keys.
    public func encodedJSON() -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return Array(try encoder.encode(self))
        } catch {
            // Every field is a string, an integer, or a container of those, all of which
            // JSONEncoder always encodes.
            preconditionFailure("encoding \(name) failed: \(error)")
        }
    }

    /// Decodes a message from JSON. Any failure is a `FrameError.malformedControl`.
    public init(json: [UInt8]) throws(FrameError) {
        do {
            self = try JSONDecoder().decode(ControlMessage.self, from: Data(json))
        } catch let error as DecodingError {
            throw .malformedControl(Self.describe(error))
        } catch {
            throw .malformedControl("\(error)")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        let context: DecodingError.Context
        switch error {
        case .dataCorrupted(let c), .keyNotFound(_, let c), .typeMismatch(_, let c),
            .valueNotFound(_, let c):
            context = c
        @unknown default:
            return "\(error)"
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
    }
}
