import Logging
import MacWSLAgentKit
import MacWSLCore
import MacWSLProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

// The MacWSL guest agent. busybox `init` starts it from /etc/inittab and restarts it if it
// exits; docs/decisions/0005-init-supervises-the-agent.md explains the arrangement.
//
//   macwsl-agent             serve on vsock port AgentProtocol.vsockPort
//   macwsl-agent self-test   run the self-test (macwsl.test=agent); exit 0 on success
//   macwsl-agent --version   print the version

/// Writes a line to standard error, which busybox `init` connects to the console (hvc0).
func writeLine(_ text: String) {
    let line = text + "\n"
    _ = line.withCString { write(STDERR_FILENO, $0, strlen($0)) }
}

/// Sends the agent's log to the console as `macwsl-agent: <level>: <message>`.
struct ConsoleLogHandler: LogHandler {
    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        writeLine("macwsl-agent: \(event.level): \(event.message)")
    }
}

LoggingSystem.bootstrap { _ in ConsoleLogHandler() }
// A write to a connection or pipe whose reader has gone fails with EPIPE instead. Children
// start with the default action again (see CMacWSLSystem).
signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "--version":
    print("macwsl-agent \(MacWSLVersion.current) (protocol \(ProtocolVersion.current))")

case "self-test":
    let failures = await SelfTest.run()
    if failures.isEmpty {
        writeLine("macwsl-agent self-test: ok")
    } else {
        for failure in failures {
            writeLine("macwsl-agent self-test: \(failure)")
        }
        writeLine("macwsl-agent self-test: FAILED")
        exit(1)
    }

case nil:
    #if os(Linux)
        let listener: OwnedDescriptor
        do {
            listener = try listenOnVsock()
        } catch {
            writeLine("macwsl-agent: cannot listen: \(error)")
            exit(1)
        }
        writeLine("macwsl-agent ready \(MacWSLVersion.current)")
        let server = AgentServer(configuration: .guest())
        do {
            try server.acceptConnections(on: listener)
        } catch {
            writeLine("macwsl-agent: \(error); exiting so that init restarts the agent")
            exit(1)
        }
    #else
        writeLine("macwsl-agent: serving needs Linux vsock; on this platform, use self-test")
        exit(69)
    #endif

default:
    writeLine("usage: macwsl-agent [self-test | --version]")
    exit(64)
}
