import Logging
import MawAgentKit
import MawCore
import MawProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

// The maw guest agent. busybox `init` starts it from /etc/inittab and restarts it if it
// exits; docs/decisions/0005-init-supervises-the-agent.md explains the arrangement.
//
//   maw-agent             serve on vsock port AgentProtocol.vsockPort
//   maw-agent self-test   run the self-test (maw.test=agent); exit 0 on success
//   maw-agent --version   print the version

/// Writes a line to standard error, which busybox `init` connects to the console (hvc0).
func writeLine(_ text: String) {
    let line = text + "\n"
    _ = line.withCString { write(STDERR_FILENO, $0, strlen($0)) }
}

/// Sends the agent's log to the console as `maw-agent: <level>: <message>`.
struct ConsoleLogHandler: LogHandler {
    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        writeLine("maw-agent: \(event.level): \(event.message)")
    }
}

LoggingSystem.bootstrap { _ in ConsoleLogHandler() }
// A write to a connection or pipe whose reader has gone fails with EPIPE instead. Children
// start with the default action again (see CMawSystem).
signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "--version":
    print("maw-agent \(MawVersion.current) (protocol \(ProtocolVersion.current))")

case "self-test":
    let failures = await SelfTest.run()
    if failures.isEmpty {
        writeLine("maw-agent self-test: ok")
    } else {
        for failure in failures {
            writeLine("maw-agent self-test: \(failure)")
        }
        writeLine("maw-agent self-test: FAILED")
        exit(1)
    }

case nil:
    #if os(Linux)
        let listener: OwnedDescriptor
        do {
            listener = try listenOnVsock()
        } catch {
            writeLine("maw-agent: cannot listen: \(error)")
            exit(1)
        }
        writeLine("maw-agent ready \(MawVersion.current)")
        let server = AgentServer(configuration: .guest())
        do {
            try server.acceptConnections(on: listener)
        } catch {
            writeLine("maw-agent: \(error); exiting so that init restarts the agent")
            exit(1)
        }
    #else
        writeLine("maw-agent: serving needs Linux vsock; on this platform, use self-test")
        exit(69)
    #endif

default:
    writeLine("usage: maw-agent [self-test | --version]")
    exit(64)
}
