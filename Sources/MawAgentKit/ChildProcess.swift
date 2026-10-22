import CMawSystem
import MawProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Why a command could not be started. Becomes the `error` reply to `exec`.
struct SpawnFailure: Error, Equatable {
    var code: AgentError.Code
    var message: String
    /// With `userNotFound`: the user that does not exist.
    var user: String? = nil
}

/// A process started for an exec session, with the parent's ends of its standard streams.
///
/// In pipe mode the process has three pipes and leads a new process group. In terminal mode it
/// leads a new session whose controlling terminal is a pseudo-terminal; the primary side
/// carries both its input and its output.
final class ChildProcess {
    let pid: pid_t
    /// The pseudo-terminal's primary side, in terminal mode.
    let terminal: OwnedDescriptor?
    /// The agent's copy of the secondary side, in terminal mode, held until the process has
    /// exited. Darwin's primary side reports end-of-file as soon as no secondary descriptor is
    /// open, discarding output that has not been read yet; holding one open keeps a short-lived
    /// process's output readable. Linux keeps the output either way.
    private var secondary: OwnedDescriptor?
    /// Where standard input is written: the pipe in pipe mode, the terminal in terminal mode.
    private(set) var input: OwnedDescriptor?
    /// Open output streams and the frame type each one becomes.
    private(set) var outputs: [(descriptor: OwnedDescriptor, type: FrameType)]
    /// Becomes readable when the process exits, or `nil` if none could be opened.
    let exitWatch: OwnedDescriptor?
    private(set) var exitStatus: ExitStatus?

    private init(
        pid: pid_t, terminal: OwnedDescriptor?, secondary: OwnedDescriptor? = nil,
        input: OwnedDescriptor?, outputs: [(descriptor: OwnedDescriptor, type: FrameType)],
        exitWatch: OwnedDescriptor?
    ) {
        self.pid = pid
        self.terminal = terminal
        self.secondary = secondary
        self.input = input
        self.outputs = outputs
        self.exitWatch = exitWatch
    }

    // MARK: Starting

    static func spawn(_ plan: SpawnPlan, terminal: TerminalSize?) throws(SpawnFailure)
        -> ChildProcess
    {
        guard let command = plan.argv.first, !command.isEmpty else {
            throw SpawnFailure(code: .spawnFailed, message: "argv is empty")
        }
        let path: String
        if let planned = plan.path {
            path = planned
        } else {
            path = try resolve(command, searchPath: plan.environment["PATH"] ?? "")
        }

        if let size = terminal {
            return try spawnOnTerminal(plan, path: path, size: size)
        }
        return try spawnWithPipes(plan, path: path)
    }

    private static func spawnWithPipes(_ plan: SpawnPlan, path: String) throws(SpawnFailure)
        -> ChildProcess
    {
        let stdinPipe = try makePipe()
        let stdoutPipe = try makePipe()
        let stderrPipe = try makePipe()
        let pid = try start(
            plan, path: path,
            stdin: stdinPipe.reader.rawValue, stdout: stdoutPipe.writer.rawValue,
            stderr: stderrPipe.writer.rawValue, controllingTerminal: false)
        // The child's ends stay open in the child only.
        stdinPipe.reader.close()
        stdoutPipe.writer.close()
        stderrPipe.writer.close()

        for descriptor in [stdinPipe.writer, stdoutPipe.reader, stderrPipe.reader] {
            _ = maw_set_nonblocking(descriptor.rawValue)
        }
        // A process that closes its standard input must not kill the agent with SIGPIPE. The
        // agent ignores SIGPIPE; this covers the unit tests, which run in the test process.
        _ = maw_suppress_sigpipe(stdinPipe.writer.rawValue)
        return ChildProcess(
            pid: pid, terminal: nil, input: stdinPipe.writer,
            outputs: [(stdoutPipe.reader, .stdout), (stderrPipe.reader, .stderr)],
            exitWatch: openExitWatch(pid))
    }

    private static func spawnOnTerminal(
        _ plan: SpawnPlan, path: String, size: TerminalSize
    ) throws(SpawnFailure) -> ChildProcess {
        var primaryDescriptor: Int32 = -1
        var secondaryDescriptor: Int32 = -1
        let error = maw_open_pty(
            &primaryDescriptor, &secondaryDescriptor, size.rows, size.columns)
        guard error == 0 else {
            throw SpawnFailure(
                code: .spawnFailed,
                message: "cannot open a pseudo-terminal: \(SystemError.message(for: error))")
        }
        let primary = OwnedDescriptor(primaryDescriptor)
        let secondary = OwnedDescriptor(secondaryDescriptor)
        if let owner = plan.terminalOwner {
            guard fchown(secondary.rawValue, uid_t(owner.uid), gid_t(owner.gid)) == 0,
                fchmod(secondary.rawValue, 0o620) == 0
            else {
                throw SpawnFailure(
                    code: .spawnFailed,
                    message: "cannot give the terminal to user ID \(owner.uid): "
                        + SystemError.message(for: errno))
            }
        }
        let pid = try start(
            plan, path: path,
            stdin: secondary.rawValue, stdout: secondary.rawValue, stderr: secondary.rawValue,
            controllingTerminal: true)
        // Once the process has exited and `releaseTerminal()` has closed this copy, reading
        // the primary side reports end-of-file (EIO on Linux) when the process's descendants
        // have closed theirs too.
        _ = maw_set_nonblocking(primary.rawValue)
        return ChildProcess(
            pid: pid, terminal: primary, secondary: secondary, input: primary,
            outputs: [(primary, .stdout)], exitWatch: openExitWatch(pid))
    }

    private static func start(
        _ plan: SpawnPlan, path: String, stdin: Int32, stdout: Int32, stderr: Int32,
        controllingTerminal: Bool
    ) throws(SpawnFailure) -> pid_t {
        let arguments = CStringArray(plan.argv)
        let variables = CStringArray(
            plan.environment.sorted { $0.key < $1.key }.map { "\($0)=\($1)" })
        let groups = (plan.credentials?.groups ?? []).map { gid_t($0) }
        var pid: pid_t = 0
        var stage = MAW_SPAWN_STAGE_FORK
        let error = path.withCString { pathPointer in
            plan.workingDirectory.withCString { directoryPointer in
                groups.withUnsafeBufferPointer { groupPointer in
                    var options = maw_spawn_options(
                        path: pathPointer, argv: arguments.pointer, envp: variables.pointer,
                        working_directory: directoryPointer, stdin_fd: stdin, stdout_fd: stdout,
                        stderr_fd: stderr, controlling_terminal: controllingTerminal ? 1 : 0,
                        set_credentials: plan.credentials == nil ? 0 : 1,
                        uid: uid_t(plan.credentials?.uid ?? 0),
                        gid: gid_t(plan.credentials?.gid ?? 0),
                        groups: groupPointer.baseAddress, group_count: groupPointer.count)
                    return maw_spawn(&options, &pid, &stage)
                }
            }
        }
        guard error != 0 else { return pid }

        let reason = SystemError.message(for: error)
        let command = plan.argv[0]
        switch stage {
        case MAW_SPAWN_STAGE_EXEC where error == ENOENT:
            throw SpawnFailure(code: .commandNotFound, message: "\(command): \(reason)")
        case MAW_SPAWN_STAGE_EXEC where error == EACCES:
            throw SpawnFailure(code: .permissionDenied, message: "\(command): \(reason)")
        case MAW_SPAWN_STAGE_EXEC:
            throw SpawnFailure(code: .spawnFailed, message: "\(command): \(reason)")
        case MAW_SPAWN_STAGE_WORKING_DIRECTORY:
            throw SpawnFailure(
                code: .spawnFailed,
                message: "cannot change to the working directory \(plan.workingDirectory): "
                    + reason)
        case MAW_SPAWN_STAGE_CREDENTIALS:
            throw SpawnFailure(
                code: .spawnFailed,
                message: "cannot switch to user ID \(plan.credentials?.uid ?? 0): \(reason)")
        case MAW_SPAWN_STAGE_SESSION:
            throw SpawnFailure(
                code: .spawnFailed, message: "cannot set up the process's session: \(reason)")
        case MAW_SPAWN_STAGE_DESCRIPTORS:
            throw SpawnFailure(
                code: .spawnFailed, message: "cannot set up standard streams: \(reason)")
        default:
            throw SpawnFailure(code: .spawnFailed, message: "fork: \(reason)")
        }
    }

    /// Finds `command` the way `execvp` does: a name with a slash is used as is; otherwise each
    /// directory in `searchPath` is tried in order.
    static func resolve(_ command: String, searchPath: String) throws(SpawnFailure) -> String {
        if command.contains("/") {
            return command
        }
        var sawUnexecutable = false
        for directory in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = (directory.isEmpty ? "." : String(directory)) + "/" + command
            var status = stat()
            guard stat(candidate, &status) == 0, Int(status.st_mode) & Int(S_IFMT) == Int(S_IFREG)
            else {
                continue
            }
            if access(candidate, X_OK) == 0 {
                return candidate
            }
            sawUnexecutable = true
        }
        if sawUnexecutable {
            throw SpawnFailure(code: .permissionDenied, message: "\(command): Permission denied")
        }
        throw SpawnFailure(
            code: .commandNotFound, message: "\(command): not found in PATH \(searchPath)")
    }

    private static func makePipe() throws(SpawnFailure) -> (
        reader: OwnedDescriptor, writer: OwnedDescriptor
    ) {
        var fds: [Int32] = [-1, -1]
        let error = maw_pipe(&fds)
        guard error == 0 else {
            throw SpawnFailure(
                code: .spawnFailed, message: "pipe: \(SystemError.message(for: error))")
        }
        return (OwnedDescriptor(fds[0]), OwnedDescriptor(fds[1]))
    }

    private static func openExitWatch(_ pid: pid_t) -> OwnedDescriptor? {
        let descriptor = maw_open_exit_watch(pid)
        return descriptor >= 0 ? OwnedDescriptor(descriptor) : nil
    }

    // MARK: Running

    /// Delivers a signal: in terminal mode to the terminal's foreground process group, in pipe
    /// mode to the process group. Nothing is sent once the process has been reaped, because its
    /// process ID may then belong to another process.
    func send(_ signal: Int32) {
        guard exitStatus == nil else { return }
        if let terminal {
            let group = tcgetpgrp(terminal.rawValue)
            if group > 0 && kill(-group, signal) == 0 {
                return
            }
        }
        if kill(-pid, signal) != 0 {
            _ = kill(pid, signal)
        }
    }

    /// Changes the terminal's window size; the kernel sends SIGWINCH.
    func resize(_ size: TerminalSize) {
        if let terminal {
            _ = maw_set_window_size(terminal.rawValue, size.rows, size.columns)
        }
    }

    /// The terminal's end-of-file character, Ctrl-D unless the program changed it.
    var endOfFileCharacter: UInt8 {
        guard let terminal else { return 0x04 }
        let character = maw_terminal_eof_character(terminal.rawValue)
        return character > 0 ? UInt8(truncatingIfNeeded: character) : 0x04
    }

    /// Closes the agent's copy of the terminal's secondary side, after the process has exited.
    func releaseTerminal() {
        secondary?.close()
        secondary = nil
    }

    func closeInput() {
        if terminal == nil {
            input?.close()
        }
        input = nil
    }

    func closeOutput(at index: Int) {
        let output = outputs.remove(at: index)
        if output.descriptor !== terminal {
            output.descriptor.close()
        }
    }

    /// Collects the exit status if the process has exited. Returns whether it has.
    @discardableResult
    func reap() -> Bool {
        guard exitStatus == nil else { return true }
        var status: Int32 = 0
        let result = retrying { waitpid(pid, &status, WNOHANG) }
        if result == pid {
            exitStatus = Self.decode(status)
        } else if result < 0 && errno == ECHILD {
            // Someone else collected it; nothing more can be learned.
            exitStatus = .exited(code: 255)
        }
        return exitStatus != nil
    }

    /// Kills the whole process group and waits for the process. Used when a session fails.
    func terminate() {
        guard exitStatus == nil else { return }
        _ = kill(-pid, SIGKILL)
        _ = kill(pid, SIGKILL)
        var status: Int32 = 0
        if retrying({ waitpid(pid, &status, 0) }) == pid {
            exitStatus = Self.decode(status)
        }
    }

    /// Decodes a `waitpid` status. The layout is the same on Linux and Darwin: the low 7 bits
    /// hold the terminating signal, or 0 if the process exited, and bits 8 to 15 the exit code.
    static func decode(_ status: Int32) -> ExitStatus {
        let signal = status & 0x7F
        if signal == 0 {
            return .exited(code: (status >> 8) & 0xFF)
        }
        return .signaled(signal: Signal(localNumber: signal)?.linuxNumber ?? signal)
    }

    private func retrying(_ call: () -> pid_t) -> pid_t {
        while true {
            let result = call()
            if result >= 0 || errno != EINTR {
                return result
            }
        }
    }
}

/// A NULL-terminated array of C strings that lives as long as the instance.
private final class CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count + 1
        pointer = .allocate(capacity: count)
        for (index, string) in strings.enumerated() {
            (pointer + index).initialize(to: strdup(string))
        }
        (pointer + strings.count).initialize(to: nil)
    }

    deinit {
        for index in 0..<count {
            free(pointer[index])
        }
        pointer.deinitialize(count: count)
        pointer.deallocate()
    }
}
