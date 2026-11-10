import CMawTerminal
import Darwin
import Foundation
import os

/// A program on a pseudo-terminal of its own: the local shell.
///
/// `maw_terminal_spawn` (CMawTerminal) forks a child that leads a session of its own with the
/// terminal as its controlling terminal, so that job control works, and that closes every
/// descriptor of the app before `execve`, whether or not it is marked close-on-exec, so that a
/// local shell never inherits a Linux session's connection (docs/security.md). `posix_spawn`
/// cannot do the former on macOS.
///
/// One thread reads the output into an `OutputPump` and reaps the child, through a kqueue;
/// another writes the input, so that typed keys never wait behind output.
final class PseudoTerminalProcess: Sendable {
    let pid: pid_t
    /// The primary side and the kqueue, or -1 once the reading thread has closed them, and
    /// whether the child has been reaped, after which its process ID may belong to another
    /// process.
    private let descriptors: OSAllocatedUnfairLock<(primary: Int32, queue: Int32, isReaped: Bool)>
    private let input: TerminalInput

    init(
        executable: String, argv0: String, environment: [String], directory: String,
        size: winsize, output: OutputPump<TerminationStatus>
    ) throws(TerminalSessionError) {
        // posix_openpt(3) opens this device but documents no O_CLOEXEC, and openpty(3) returns
        // both sides without it; open(2) sets it atomically.
        let primary = open("/dev/ptmx", O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard primary >= 0 else { throw Self.failure("no pseudo-terminal is available") }
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

        let queue = kqueue()
        guard queue >= 0 else {
            let failure = Self.failure("no kqueue is available")
            close(primary)
            close(writer)
            throw failure
        }
        _ = fcntl(queue, F_SETFD, FD_CLOEXEC)

        // Everything the child needs is prepared here, because it may not allocate.
        let argv = [strdup(argv0)] + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { for argument in argv + envp { free(argument) } }
        var step: Int32 = 0
        var code: Int32 = 0
        let pid = maw_terminal_spawn(
            executable, argv, envp, directory, secondary, Self.descriptorLimit, &step, &code)
        guard pid > 0 else {
            close(primary)
            close(writer)
            close(queue)
            throw Self.failure(Self.describe(step, executable: executable), code: code)
        }
        self.pid = pid
        descriptors = OSAllocatedUnfairLock(initialState: (primary, queue, false))
        input = TerminalInput(descriptor: writer)
        let input = input
        Thread.detachNewThread { input.run() }
        Thread.detachNewThread { [self] in
            let status = readUntilExit(primary: primary, queue: queue, into: output)
            input.finish()
            output.finish(TerminationStatus(waitStatus: status))
        }
    }

    private static func failure(_ what: String, code: Int32 = errno) -> TerminalSessionError {
        .startFailed(reason: "\(what): \(String(cString: strerror(code)))")
    }

    /// What failed, for the start failure's reason.
    private static func describe(_ step: Int32, executable: String) -> String {
        switch maw_terminal_step(rawValue: UInt32(step)) {
        case MAW_TERMINAL_STEP_PIPE: "the pipe for the shell's start could not be created"
        case MAW_TERMINAL_STEP_FORK: "no process could be created for \(executable)"
        case MAW_TERMINAL_STEP_SIGNALS: "the shell's signals could not be reset"
        case MAW_TERMINAL_STEP_SESSION: "the shell's session could not be created"
        case MAW_TERMINAL_STEP_CONTROLLING_TERMINAL:
            "the pseudo-terminal could not become the shell's controlling terminal"
        case MAW_TERMINAL_STEP_STANDARD_DESCRIPTORS:
            "the pseudo-terminal could not become the shell's standard input and output"
        case MAW_TERMINAL_STEP_SIGNAL_MASK: "the shell's signal mask could not be cleared"
        default: "\(executable) could not be executed"
        }
    }

    /// The child closes every descriptor below this number except its terminal: the soft
    /// `RLIMIT_NOFILE`, capped at `kern.maxfilesperproc`, at and above which the kernel hands out
    /// no descriptor whatever the soft limit says (`getdtablesize()` reports the same minimum).
    /// An app that launchd starts has 256; a shell's `ulimit -n` may be far larger, and the cap
    /// is then 61,440 on this Mac. If the cap cannot be read, 65,536 stands in for it.
    static var descriptorLimit: Int32 {
        var limit = rlimit()
        let soft = getrlimit(RLIMIT_NOFILE, &limit) == 0 ? limit.rlim_cur : .max
        var perProcess: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let cap: rlim_t =
            sysctlbyname("kern.maxfilesperproc", &perProcess, &size, nil, 0) == 0
                && perProcess > 0 ? rlim_t(perProcess) : 65_536
        return Int32(min(soft, cap))
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
        input.finish()
        descriptors.withLock { [pid] descriptors in
            // Until it is reaped, the child keeps its process ID, even after it has exited.
            if !descriptors.isReaped { kill(pid, SIGHUP) }
            guard descriptors.queue >= 0 else { return }
            Self.watch(descriptors.queue, 0, EVFILT_USER, fflags: UInt32(NOTE_TRIGGER))
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

    @discardableResult
    private static func watch(
        _ queue: Int32, _ ident: Int32, _ filter: Int32, flags: Int32 = 0, fflags: UInt32 = 0
    ) -> Bool {
        var change = kevent(
            ident: UInt(ident), filter: Int16(filter), flags: UInt16(flags), fflags: fflags,
            data: 0, udata: nil)
        return kevent(queue, &change, 1, nil, 0, nil) == 0
    }

    /// The reading thread: output until the terminal closes, then the exit. Returns the
    /// `waitpid` status. The primary side closes at the end of the output, when the pane no
    /// longer reads it, or on `hangUp()`; the queue closes at the exit.
    private func readUntilExit(
        primary: Int32, queue: Int32, into output: OutputPump<TerminationStatus>
    ) -> Int32 {
        var isOpen = true
        var buffer = [UInt8](repeating: 0, count: 128 << 10)
        func forward() -> Bool {
            let count = read(primary, &buffer, buffer.count)
            guard count > 0 else { return count < 0 && errno == EINTR }
            return buffer.withUnsafeBytes { output.write(.init(rebasing: $0.prefix(count))) }
        }
        func closePrimary() {
            if isOpen { closeDescriptors(queueToo: false) }
            isOpen = false
        }
        Self.watch(queue, primary, EVFILT_READ, flags: EV_ADD)
        Self.watch(queue, 0, EVFILT_USER, flags: EV_ADD | EV_CLEAR)
        // A child that has already exited cannot be watched (ESRCH); it is reaped below.
        var exited = !Self.watch(queue, pid, EVFILT_PROC, flags: EV_ADD, fflags: NOTE_EXIT)
        while !exited {
            var event = kevent()
            let count = kevent(queue, nil, 0, &event, 1, nil)
            guard count >= 0 || errno == EINTR else { break }
            guard count == 1 else { continue }
            switch Int32(event.filter) {
            case EVFILT_READ:
                if !forward() { closePrimary() }
            case EVFILT_USER:
                closePrimary()
            default:
                exited = true
            }
        }
        // Waits for the exit without reaping, then reaps under the lock, so that `hangUp()`
        // never signals a process ID that the system may have given to another process.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
        let status = descriptors.withLock { [pid] descriptors in
            descriptors.isReaped = true
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            return status
        }
        // What the program wrote before it exited is still in the terminal.
        if isOpen {
            _ = fcntl(primary, F_SETFL, O_NONBLOCK)
            for _ in 0..<8 where forward() {}
        }
        closeDescriptors(queueToo: true)
        return status
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
