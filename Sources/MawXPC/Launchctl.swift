#if os(macOS)
    import Darwin
    import Foundation
    import MawCore

    /// Runs `launchctl` in the user's GUI domain.
    public enum Launchctl {
        /// How long one `launchctl` command may take. `bootout` waits for the job to exit, and
        /// launchd sends SIGKILL 20 seconds after SIGTERM by default (`ExitTimeOut`).
        static let timeout = Duration.seconds(60)
        /// Output kept from one command; the rest is read and discarded.
        static let outputLimit = 1 << 20

        /// `gui/<uid>`.
        public static var domain: String { "gui/\(getuid())" }

        /// Whether launchd has a job with `label` loaded. Throws only if `launchctl` could not
        /// be run, or did not finish in time.
        public static func isLoaded(_ label: String) throws(MawError) -> Bool {
            try run(["print", "\(domain)/\(label)"]).status == 0
        }

        /// Loads the agent in `plist`.
        public static func bootstrap(_ plist: URL) throws(MawError) {
            try check(["bootstrap", domain, plist.path(percentEncoded: false)])
        }

        /// Unloads the job, which stops it with SIGTERM first.
        public static func bootout(_ label: String) throws(MawError) {
            try check(["bootout", "\(domain)/\(label)"])
        }

        /// How long `waitUntilRemoved` waits: longer than the 20 seconds after which launchd
        /// kills a job's program that has not exited on SIGTERM.
        public static let removalTimeout = Duration.seconds(30)

        /// Waits until launchd no longer has a job with `label`. `bootout` returns before
        /// launchd has removed the job: launchd keeps it while its program exits, and until
        /// then refuses to load the label again ("Bootstrap failed: 5: Input/output error").
        /// Throws `launchAgentNotRemoved` if the job is still there after `timeout`.
        public static func waitUntilRemoved(
            _ label: String, timeout: Duration = removalTimeout
        ) async throws(MawError) {
            try await waitUntilRemoved(
                service: "\(domain)/\(label)", timeout: timeout, interval: .milliseconds(50)
            ) { () throws(MawError) in try isLoaded(label) }
        }

        /// `waitUntilRemoved`, with `isLoaded` asked every `interval`.
        static func waitUntilRemoved(
            service: String, timeout: Duration, interval: Duration,
            isLoaded: () throws(MawError) -> Bool
        ) async throws(MawError) {
            let deadline = ContinuousClock.now + timeout
            while try isLoaded() {
                guard ContinuousClock.now < deadline else {
                    throw .launchAgentNotRemoved(
                        service: service, seconds: Int(timeout.components.seconds))
                }
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    throw .launchAgentFailed(
                        reason: "the wait for launchd to remove \(service) was cancelled")
                }
            }
        }

        private static func check(_ arguments: [String]) throws(MawError) {
            let result = try run(arguments)
            guard result.status == 0 else {
                let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                throw .launchAgentFailed(
                    reason: "launchctl \(arguments.joined(separator: " ")) exited with status "
                        + "\(result.status)" + (output.isEmpty ? "" : ": \(output)"))
            }
        }

        /// Runs `executable` with `arguments` and returns its exit status (128 plus the signal
        /// if a signal ended it) and its standard output and error, combined. If it has not
        /// finished within `timeout`, kills it and throws `launchctlTimedOut`.
        ///
        /// It waits with kqueue rather than `Process.waitUntilExit()`, which also waits for a
        /// notification that Foundation delivers through a run loop, and can wait for ever in
        /// async code that has none.
        static func run(
            _ arguments: [String], executable: String = "/bin/launchctl",
            timeout: Duration = timeout
        ) throws(MawError) -> (status: Int32, output: String) {
            let command = ([URL(filePath: executable).lastPathComponent] + arguments)
                .joined(separator: " ")
            let deadline = ContinuousClock.now + timeout
            let (pid, reader) = try spawn(executable, arguments, command: command)
            defer { close(reader) }

            let queue = kqueue()
            guard queue >= 0 else {
                let reason = describe(errno)
                kill(pid, SIGKILL)
                reap(pid)
                throw .launchAgentFailed(reason: "\(command) could not be waited for: \(reason)")
            }
            defer { close(queue) }
            var output: [UInt8] = []
            let status = try wait(
                for: pid, reading: reader, into: &output, queue: queue, until: deadline,
                command: command)
            guard let status else {
                kill(pid, SIGKILL)
                reap(pid)
                throw .launchctlTimedOut(
                    command: command, seconds: Int(timeout.components.seconds))
            }
            return (status, String(decoding: output, as: UTF8.self))
        }

        /// Starts `executable` with standard input from /dev/null and standard output and
        /// error into a pipe. Returns its process ID and the pipe's read end.
        private static func spawn(
            _ executable: String, _ arguments: [String], command: String
        ) throws(MawError) -> (pid_t, Int32) {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else {
                throw .launchAgentFailed(
                    reason: "\(command) could not be started: \(describe(errno))")
            }
            let (reader, writer) = (fds[0], fds[1])
            _ = fcntl(reader, F_SETFD, FD_CLOEXEC)
            _ = fcntl(writer, F_SETFD, FD_CLOEXEC)

            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, writer, STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, writer, STDERR_FILENO)
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            // Only the three standard descriptors, default signal dispositions (maw and mawd
            // ignore SIGPIPE), and an empty signal mask.
            var everySignal = sigset_t()
            sigfillset(&everySignal)
            var noSignal = sigset_t()
            sigemptyset(&noSignal)
            posix_spawnattr_setsigdefault(&attributes, &everySignal)
            posix_spawnattr_setsigmask(&attributes, &noSignal)
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

            let argv = ([executable] + arguments).map { strdup($0) } + [nil]
            defer {
                for argument in argv {
                    free(argument)
                }
            }
            var pid: pid_t = 0
            let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
            close(writer)
            guard spawned == 0 else {
                close(reader)
                throw .launchAgentFailed(
                    reason: "\(command) could not be started: \(describe(spawned))")
            }
            return (pid, reader)
        }

        /// Reads `reader` to end-of-file and waits for `pid` to exit. Returns the exit status,
        /// or `nil` if the process is still running at `deadline`. A process that has exited
        /// is not waited for beyond `deadline` for the end of its output, which a descendant
        /// may keep open.
        private static func wait(
            for pid: pid_t, reading reader: Int32, into output: inout [UInt8], queue: Int32,
            until deadline: ContinuousClock.Instant, command: String
        ) throws(MawError) -> Int32? {
            var changes = [
                Darwin.kevent(
                    ident: UInt(reader), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD),
                    fflags: 0, data: 0, udata: nil),
                Darwin.kevent(
                    ident: UInt(pid), filter: Int16(EVFILT_PROC),
                    flags: UInt16(EV_ADD | EV_ONESHOT), fflags: NOTE_EXIT, data: 0, udata: nil),
            ]
            // If the process has already exited, registering NOTE_EXIT may fail; `waitpid`
            // below finds the exit either way.
            for index in changes.indices {
                _ = kevent(queue, &changes[index], 1, nil, 0, nil)
            }

            var status: Int32?
            var atEnd = false
            var buffer = [UInt8](repeating: 0, count: 16 << 10)
            while true {
                if status == nil {
                    status = try exitStatus(of: pid, command: command)
                }
                if let status, atEnd {
                    return status
                }
                let remaining = deadline - ContinuousClock.now
                guard remaining > .zero else { return status }
                var limit = timespec(
                    tv_sec: Int(remaining.components.seconds),
                    tv_nsec: Int(remaining.components.attoseconds / 1_000_000_000))
                var event = Darwin.kevent()
                guard kevent(queue, nil, 0, &event, 1, &limit) > 0,
                    event.filter == Int16(EVFILT_READ)
                else { continue }
                let count = buffer.withUnsafeMutableBytes {
                    read(reader, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    output.append(contentsOf: buffer[..<min(count, outputLimit - output.count)])
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    atEnd = true
                    var remove = Darwin.kevent(
                        ident: UInt(reader), filter: Int16(EVFILT_READ),
                        flags: UInt16(EV_DELETE), fflags: 0, data: 0, udata: nil)
                    _ = kevent(queue, &remove, 1, nil, 0, nil)
                }
            }
        }

        /// The exit status if `pid` has exited, reaping it; `nil` while it runs.
        private static func exitStatus(of pid: pid_t, command: String) throws(MawError)
            -> Int32?
        {
            var raw: Int32 = 0
            let result = waitpid(pid, &raw, WNOHANG)
            if result == pid {
                return raw & 0x7F == 0 ? (raw >> 8) & 0xFF : 128 + (raw & 0x7F)
            }
            if result < 0 && errno != EINTR {
                // ECHILD: something else reaped the process, and its status with it. Its ID
                // may already belong to another process, so it is not killed.
                throw .launchAgentFailed(
                    reason: "the exit status of \(command) could not be read: \(describe(errno))")
            }
            return nil
        }

        /// Waits for a killed process to exit, so that it does not remain a zombie.
        private static func reap(_ pid: pid_t) {
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) < 0 && errno == EINTR {}
        }

        private static func describe(_ code: Int32) -> String {
            String(cString: strerror(code))
        }
    }
#endif
