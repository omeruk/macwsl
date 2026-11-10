import MawProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Tells which program runs in the foreground of a session's terminal, for `foregroundQuery`
/// (docs/protocol.md, "Foreground program").
///
/// The terminal's foreground process group is a program unless its leader is the session's
/// shell, which `ShellIdentity` describes. The leader's state, parent, and command name come
/// from `processDirectory`, `/proc` in the guest, so that tests can supply a fixture.
struct ForegroundProbe: Sendable {
    /// Where the process files are: `<processDirectory>/<pid>/stat` and `.../comm`.
    var processDirectory: String

    init(processDirectory: String = "/proc") {
        self.processDirectory = processDirectory
    }

    /// The program in the foreground of `terminal`, the primary side of the session's
    /// pseudo-terminal, or `nil` when the shell is in the foreground or there is no foreground
    /// group. `child` is the process the agent started.
    func foregroundProgram(terminal: Int32, child: pid_t, shell: ShellIdentity)
        -> ForegroundProcess?
    {
        let group = tcgetpgrp(terminal)
        guard group > 0 else { return nil }
        return program(inForegroundGroup: group, child: child, shell: shell)
    }

    /// The decision for a known foreground group, apart from the terminal.
    func program(inForegroundGroup group: pid_t, child: pid_t, shell: ShellIdentity)
        -> ForegroundProcess?
    {
        if group == child {
            switch shell.position {
            case .child:
                return execedProgram(group, shell: shell)
            case .childOfChild:
                // runuser itself, before the shell has made its own group.
                return nil
            }
        }
        guard let leader = status(of: group) else {
            // The leader has exited, as it may have in a pipeline.
            return ForegroundProcess(processGroup: group, name: nil)
        }
        if shell.position == .childOfChild && leader.parent == child {
            return execedProgram(group, shell: shell)
        }
        return ForegroundProcess(processGroup: group, name: commandName(of: group))
    }

    /// For the shell's own process: the program it has `exec`'d, if its command name is not
    /// the shell's; otherwise `nil`. Sessions without a shell name skip the check.
    private func execedProgram(_ pid: pid_t, shell: ShellIdentity) -> ForegroundProcess? {
        guard let expected = shell.commandName, let name = commandName(of: pid), name != expected
        else {
            return nil
        }
        return ForegroundProcess(processGroup: pid, name: name)
    }

    struct Status: Equatable {
        var state: Character
        var parent: pid_t
    }

    /// The process's state and parent from its `stat` file, or `nil` if it has exited: the file
    /// is missing, or the state is `Z`.
    func status(of pid: pid_t) -> Status? {
        guard let bytes = readBytes("\(processDirectory)/\(pid)/stat", limit: 4096),
            let status = Self.parseStatus(String(decoding: bytes, as: UTF8.self)),
            status.state != "Z"
        else {
            return nil
        }
        return status
    }

    /// Parses `pid (comm) state ppid ...` from its last `)`, because the command name may
    /// contain spaces and parentheses.
    static func parseStatus(_ text: String) -> Status? {
        guard let close = text.lastIndex(of: ")") else { return nil }
        let fields = text[text.index(after: close)...].split(separator: " ")
        guard fields.count >= 2, fields[0].count == 1, let state = fields[0].first,
            let parent = pid_t(fields[1])
        else {
            return nil
        }
        return Status(state: state, parent: parent)
    }

    /// The process's command name from its `comm` file, without the line feed, or `nil`.
    func commandName(of pid: pid_t) -> String? {
        guard var bytes = readBytes("\(processDirectory)/\(pid)/comm", limit: 4096) else {
            return nil
        }
        if bytes.last == UInt8(ascii: "\n") {
            bytes.removeLast()
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
