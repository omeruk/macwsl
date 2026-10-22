#if os(macOS)
    import Darwin
    import Foundation

    /// Runs a program on the Mac and hands its standard output to a consumer in chunks.
    ///
    /// It uses `posix_spawn` rather than Foundation's `Process`: the parent keeps no copy of
    /// the output pipe's write end, so that reading ends at end-of-file when the program exits;
    /// the child gets only its three standard descriptors (`POSIX_SPAWN_CLOEXEC_DEFAULT`), so
    /// that it cannot inherit the daemon's connections; and it starts with default signal
    /// dispositions.
    enum StreamingProcess {
        struct Outcome: Equatable {
            /// The exit status, or 128 plus the signal that ended it.
            var status: Int32
            /// The end of what it wrote to standard error.
            var errors: String
        }

        /// Runs `path` with `arguments` and calls `consume` with each chunk of its standard
        /// output. If `consume` returns false, the program is terminated and the rest of its
        /// output discarded. Blocks until the program has exited; call it on a thread of its
        /// own.
        static func run(
            _ path: String, _ arguments: [String], consume: (Data) -> Bool
        ) throws -> Outcome {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            let (reader, writer) = (fds[0], fds[1])
            _ = fcntl(reader, F_SETFD, FD_CLOEXEC)
            _ = fcntl(writer, F_SETFD, FD_CLOEXEC)
            let errorFile = FileManager.default.temporaryDirectory.appending(
                path: "maw-\(UUID().uuidString).stderr")
            defer { try? FileManager.default.removeItem(at: errorFile) }

            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, writer, STDOUT_FILENO)
            posix_spawn_file_actions_addopen(
                &actions, STDERR_FILENO, errorFile.path(percentEncoded: false),
                O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            // Default signal dispositions and an empty mask: the daemon ignores SIGPIPE, and
            // the child must still end when its reader goes away.
            var everySignal = sigset_t()
            sigfillset(&everySignal)
            var noSignal = sigset_t()
            sigemptyset(&noSignal)
            posix_spawnattr_setsigdefault(&attributes, &everySignal)
            posix_spawnattr_setsigmask(&attributes, &noSignal)
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

            let argv = ([path] + arguments).map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }
            var pid: pid_t = 0
            let spawned = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
            close(writer)
            guard spawned == 0 else {
                close(reader)
                throw POSIXError(.init(rawValue: spawned) ?? .EIO)
            }

            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            var consuming = true
            while true {
                let count = read(reader, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                if consuming, !consume(Data(buffer[..<count])) {
                    consuming = false
                    kill(pid, SIGTERM)
                }
            }
            close(reader)

            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            let exitStatus = status & 0x7F == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            let errors = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
            return Outcome(
                status: exitStatus,
                errors: String(errors.trimmingCharacters(in: .whitespacesAndNewlines).suffix(2048)))
        }
    }
#endif
