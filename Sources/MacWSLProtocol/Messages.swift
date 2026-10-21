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

    // During an exec session, host to guest.

    /// No more standard input. In terminal mode, the terminal's end-of-file character is sent.
    case stdinEOF
    /// Delivers a signal: to the process group in pipe mode, to the terminal's foreground
    /// process group in terminal mode.
    case signal(Signal)
    /// Changes the terminal's window size. Ignored in pipe mode.
    case resize(TerminalSize)

    // Guest to host.

    /// The command started with this process ID.
    case started(pid: Int32)
    /// The command ended. The last message of an exec session.
    case exited(ExitStatus)
    /// The reply to `info`.
    case agentInfo(AgentInfo)
    /// The reply to `shutdown`: the guest is powering off.
    case shutdownAcknowledged
    /// A request failed, or the connection is being closed because of a protocol error.
    case error(AgentError)

    /// The message's key on the wire.
    public var name: String {
        switch self {
        case .exec: "exec"
        case .info: "info"
        case .shutdown: "shutdown"
        case .stdinEOF: "stdinEOF"
        case .signal: "signal"
        case .resize: "resize"
        case .started: "started"
        case .exited: "exited"
        case .agentInfo: "agentInfo"
        case .shutdownAcknowledged: "shutdownAcknowledged"
        case .error: "error"
        }
    }
}

/// A command to run in the guest.
public struct ExecRequest: Codable, Equatable, Sendable {
    /// The program and its arguments. A program name without a slash is searched for in the
    /// session's PATH.
    public var argv: [String]
    /// Environment variables, applied on top of the agent's defaults (see docs/protocol.md).
    public var environment: [String: String]
    /// The working directory. `/` unless set.
    public var workingDirectory: String
    /// The initial window size of a pseudo-terminal, or `nil` for separate pipes.
    public var terminal: TerminalSize?

    public init(
        argv: [String], environment: [String: String] = [:], workingDirectory: String = "/",
        terminal: TerminalSize? = nil
    ) {
        self.argv = argv
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.terminal = terminal
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        argv = try container.decode([String].self, forKey: .argv)
        environment =
            try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        workingDirectory =
            try container.decodeIfPresent(String.self, forKey: .workingDirectory) ?? "/"
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
    /// `uname -r`, for example `6.18.2-macwsl`.
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
    }

    public var code: Code
    public var message: String
    public var hostVersion: UInt32?
    public var guestVersion: UInt32?

    public init(
        _ code: Code, _ message: String, hostVersion: UInt32? = nil, guestVersion: UInt32? = nil
    ) {
        self.code = code
        self.message = message
        self.hostVersion = hostVersion
        self.guestVersion = guestVersion
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

    private struct StartedFields: Codable {
        var pid: Int32
    }

    private struct ExitedFields: Codable {
        var code: Int32?
        var signal: Int32?
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        let key = Key(name)
        switch self {
        case .exec(let request):
            try container.encode(request, forKey: key)
        case .info, .shutdown, .stdinEOF, .shutdownAcknowledged:
            try container.encode(Empty(), forKey: key)
        case .signal(let signal):
            try container.encode(SignalFields(name: signal), forKey: key)
        case .resize(let size):
            try container.encode(size, forKey: key)
        case .started(let pid):
            try container.encode(StartedFields(pid: pid), forKey: key)
        case .exited(.exited(let code)):
            try container.encode(ExitedFields(code: code), forKey: key)
        case .exited(.signaled(let signal)):
            try container.encode(ExitedFields(signal: signal), forKey: key)
        case .agentInfo(let info):
            try container.encode(info, forKey: key)
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
        case "stdinEOF":
            _ = try container.decode(Empty.self, forKey: key)
            self = .stdinEOF
        case "signal":
            self = .signal(try container.decode(SignalFields.self, forKey: key).name)
        case "resize":
            self = .resize(try container.decode(TerminalSize.self, forKey: key))
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
