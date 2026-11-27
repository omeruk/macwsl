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
//   maw-agent mount-mac-share <root> <tag>
//                         mount the Mac's home directory at <root>/mnt/mac, from /init before
//                         switch_root; exit 0 if it is mounted
//   maw-agent network-dns write the drop-ins that keep the network's DNS servers out of
//                         systemd-resolved, from the boot's unit before systemd-networkd
//                         (NetworkDNS)
//   maw-agent login-shell <directory> fall-back|exact <shell>
//                         runuser -l's shell helper for a login shell in a working directory
//                         (LoginShellHelper)
//   maw-agent --version   print the version
//   mawpath [-u | -m] [-a] <path>
//                         the same binary through /usr/local/bin/mawpath (MawPathCommand)

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

// Logging and SIGPIPE are set up per command: the shell helper and mawpath keep the default
// dispositions, which an executed program inherits for an ignored signal.

/// Writes `text` to the standard stream `descriptor`, all of it.
func writeAll(_ text: String, to descriptor: Int32) {
    var bytes = Array(text.utf8)[...]
    while !bytes.isEmpty {
        let count = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { return }
        bytes = bytes.dropFirst(count)
    }
}

/// The file's text, or `nil` if it cannot be read.
func readText(_ path: String) -> String? {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while bytes.count <= 1 << 16 {
        let count = read(descriptor, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { return nil }
        if count == 0 { return String(decoding: bytes, as: UTF8.self) }
        bytes += buffer[..<count]
    }
    return nil
}

switch AgentCommand(argv: CommandLine.arguments) {
case .mawpath(let arguments):
    let outcome = MawPathCommand.run(
        arguments, commandLine: { readText("/proc/cmdline") },
        currentDirectory: {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            return getcwd(&buffer, buffer.count).map { String(cString: $0) }
        })
    writeAll(outcome.output, to: STDOUT_FILENO)
    writeAll(outcome.error, to: STDERR_FILENO)
    exit(outcome.status)

case .loginShell(let operands):
    exit(LoginShellHelper.run(operands))

case .version:
    print("maw-agent \(MawVersion.current) (protocol \(ProtocolVersion.current))")

case .selfTest:
    LoggingSystem.bootstrap { _ in ConsoleLogHandler() }
    signal(SIGPIPE, SIG_IGN)
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

case .serve:
    LoggingSystem.bootstrap { _ in ConsoleLogHandler() }
    // A write to a connection or pipe whose reader has gone fails with EPIPE instead. Children
    // start with the default action again (see CMawSystem).
    signal(SIGPIPE, SIG_IGN)
    #if os(Linux)
        // Only in a distribution, where /init copied the agent to /run/maw: mawpath links to
        // that copy. The initramfs machine runs /sbin/maw-agent and needs no mawpath.
        var executable = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink("/proc/self/exe", &executable, executable.count - 1)
        if length > 0,
            String(decoding: executable[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                == MawPathLink.target,
            let line = MawPathLink.consoleLine(MawPathLink.install())
        {
            writeLine(line)
        }
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

case .mountMacShare(let root, let tag):
    LoggingSystem.bootstrap { _ in ConsoleLogHandler() }
    let result = MacShareMount.mount(root: root, tag: tag)
    for line in result.lines {
        writeLine(line)
    }
    exit(result.mounted ? 0 : 1)

case .networkDNS:
    let (written, failures) = NetworkDNS.writeDropIns(files: .live)
    if !written.isEmpty {
        writeLine(
            "maw-agent: dns: DHCP and router-advertised DNS off for \(written.joined(separator: ", "))"
        )
    }
    for failure in failures {
        writeLine("maw-agent: dns: cannot write the drop-in for \(failure)")
    }
    // The boot goes on either way: the agent writes what is missing once it runs.
    exit(0)

case .usage(let status):
    writeLine(
        "usage: maw-agent [self-test | mount-mac-share <root> <tag> | network-dns"
            + " | login-shell <directory> fall-back|exact <shell> | --version]")
    exit(status)
}
