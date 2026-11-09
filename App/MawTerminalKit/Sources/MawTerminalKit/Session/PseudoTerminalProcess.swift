import Darwin
import Foundation
import os

/// A program on a pseudo-terminal of its own, started with `posix_spawn`: the local shell.
///
/// `POSIX_SPAWN_CLOEXEC_DEFAULT` gives the child its terminal as standard input, output, and
/// error, and no other descriptor of the app, whether or not it is marked close-on-exec, so a
/// local shell never inherits a Linux session's connection (docs/security.md). The child leads
/// a session of its own (`POSIX_SPAWN_SETSID`) and opens the terminal's secondary side first,
/// which makes it the session's controlling terminal.
///
/// One thread reads the output into an `OutputPump` and reaps the child, through a kqueue;
/// another writes the input, so that typed keys never wait behind output.
final class PseudoTerminalProcess: Sendable {
    let pid: pid_t
    /// The primary side and the kqueue, or -1 once the reading thread has closed them.
    private let descriptors: OSAllocatedUnfairLock<(primary: Int32, queue: Int32)>
    private let input: TerminalInput

    init(
        executable: String, argv0: String, environment: [String], directory: String,
        size: winsize, output: OutputPump<TerminationStatus>
    ) throws(TerminalSessionError) {
        let primary = posix_openpt(O_RDWR | O_NOCTTY)
        guard primary >= 0 else { throw Self.failure("no pseudo-terminal is available") }
        _ = fcntl(primary, F_SETFD, FD_CLOEXEC)
        var name = [CChar](repeating: 0, count: 128)
        var size = size
        // The size is set on the secondary side, as openpty does; the primary side refuses it
        // until the secondary side has been opened.
        let secondary =
            grantpt(primary) == 0 && unlockpt(primary) == 0
                && ptsname_r(primary, &name, name.count) == 0
            ? open(name, O_RDWR | O_NOCTTY | O_CLOEXEC) : -1
        let writer =
            secondary >= 0 && ioctl(secondary, TIOCSWINSZ, &size) == 0
            ? fcntl(primary, F_DUPFD_CLOEXEC, 0) : -1
        defer { if secondary >= 0 { close(secondary) } }
        guard writer >= 0 else {
            let failure = Self.failure("the pseudo-terminal could not be set up")
            close(primary)
            throw failure
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, name, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO)
        // forkpty ignored a start directory that does not exist, and so does this.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            posix_spawn_file_actions_addchdir_np(&actions, directory)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        var noSignal = sigset_t()
        sigemptyset(&noSignal)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        posix_spawnattr_setsigmask(&attributes, &noSignal)
        posix_spawnattr_setflags(
            &attributes,
            Int16(
                POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
                    | POSIX_SPAWN_SETSIGMASK))

        let argv = [strdup(argv0)] + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { for argument in argv + envp { free(argument) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        let queue = spawned == 0 ? kqueue() : -1
        guard queue >= 0 else {
            let failure = Self.failure("\(executable) could not start", code: spawned)
            close(primary)
            close(writer)
            if spawned == 0 {
                kill(pid, SIGKILL)
                waitpid(pid, nil, 0)
            }
            throw failure
        }
        _ = fcntl(queue, F_SETFD, FD_CLOEXEC)
        self.pid = pid
        descriptors = OSAllocatedUnfairLock(initialState: (primary, queue))
        input = TerminalInput(descriptor: writer)
        let reaper = Reaper(pid: pid, primary: primary, queue: queue, output: output)
        let input = input
        Thread.detachNewThread { input.run() }
        Thread.detachNewThread { [self] in
            let status = reaper.run(closing: closeDescriptors)
            input.finish()
            output.finish(TerminationStatus(waitStatus: status))
        }
    }

    private static func failure(_ what: String, code: Int32 = errno) -> TerminalSessionError {
        .startFailed(reason: "\(what): \(String(cString: strerror(code)))")
    }

    /// Calls `body` with the primary side, unless the process has ended.
    func withPrimary<T>(_ body: (Int32) -> T) -> T? {
        descriptors.withLockUnchecked { $0.primary >= 0 ? body($0.primary) : nil }
    }

    func send(_ bytes: some Collection<UInt8>) {
        input.append(bytes)
    }

    /// Ends the terminal, as closing a terminal window does: SIGHUP to the program, and the
    /// terminal hung up. The process is still reaped, and the pump receives its status.
    func hangUp() {
        kill(pid, SIGHUP)
        input.finish()
        descriptors.withLock { descriptors in
            guard descriptors.queue >= 0 else { return }
            var trigger = kevent(
                ident: 0, filter: Int16(EVFILT_USER), flags: 0, fflags: UInt32(NOTE_TRIGGER),
                data: 0, udata: nil)
            _ = kevent(descriptors.queue, &trigger, 1, nil, 0, nil)
        }
    }

    private func closeDescriptors(queueToo: Bool) {
        descriptors.withLock { descriptors in
            if descriptors.primary >= 0 { close(descriptors.primary) }
            descriptors.primary = -1
            if queueToo, descriptors.queue >= 0 {
                close(descriptors.queue)
                descriptors.queue = -1
            }
        }
    }
}

/// The reading thread's loop: output until the terminal closes, then the exit.
private struct Reaper: Sendable {
    let pid: pid_t
    let primary: Int32
    let queue: Int32
    let output: OutputPump<TerminationStatus>

    /// Returns the `waitpid` status. `close(queueToo:)` closes the primary side, and the queue
    /// with it at the end.
    func run(closing close: (_ queueToo: Bool) -> Void) -> Int32 {
        var isOpen = true
        func closePrimary() {
            if isOpen { close(false) }
            isOpen = false
        }
        var read = kevent(
            ident: UInt(primary), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD), fflags: 0,
            data: 0, udata: nil)
        var hangUp = kevent(
            ident: 0, filter: Int16(EVFILT_USER), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0,
            data: 0, udata: nil)
        var exit = kevent(
            ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD),
            fflags: NOTE_EXIT, data: 0, udata: nil)
        _ = kevent(queue, &read, 1, nil, 0, nil)
        _ = kevent(queue, &hangUp, 1, nil, 0, nil)
        // A child that has already exited cannot be watched (ESRCH); it is reaped below.
        var exited = kevent(queue, &exit, 1, nil, 0, nil) < 0
        var buffer = [UInt8](repeating: 0, count: 128 << 10)
        while !exited {
            var event = kevent()
            let count = kevent(queue, nil, 0, &event, 1, nil)
            guard count >= 0 || errno == EINTR else { break }
            guard count == 1 else { continue }
            switch Int32(event.filter) {
            case EVFILT_READ:
                // The end of the output, or a pane that no longer reads it.
                if !forward(&buffer) { closePrimary() }
            case EVFILT_USER:
                closePrimary()
            default:
                exited = true
            }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        // What the program wrote before it exited is still in the terminal.
        if isOpen {
            _ = fcntl(primary, F_SETFL, O_NONBLOCK)
            for _ in 0..<8 where forward(&buffer) {}
        }
        close(true)
        return status
    }

    private func forward(_ buffer: inout [UInt8]) -> Bool {
        let count = read(primary, &buffer, buffer.count)
        guard count > 0 else { return count < 0 && errno == EINTR }
        return buffer.withUnsafeBytes { output.write(.init(rebasing: $0.prefix(count))) }
    }
}

/// Typed keys and pasted text on their way to the terminal. `append` never blocks; a thread of
/// its own writes them to a duplicate of the primary side, and closes it at the end.
private final class TerminalInput: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: [UInt8] = []
    private var isFinished = false
    private let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func append(_ bytes: some Collection<UInt8>) {
        condition.withLock {
            guard !isFinished else { return }
            pending.append(contentsOf: bytes)
            condition.broadcast()
        }
    }

    func finish() {
        condition.withLock {
            isFinished = true
            condition.broadcast()
        }
    }

    func run() {
        defer { close(descriptor) }
        while true {
            let bytes = condition.withLock { () -> [UInt8]? in
                while pending.isEmpty && !isFinished { condition.wait() }
                defer { pending = [] }
                return isFinished ? nil : pending
            }
            guard var bytes else { return }
            while !bytes.isEmpty {
                let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return }
                bytes.removeFirst(written)
            }
        }
    }
}
