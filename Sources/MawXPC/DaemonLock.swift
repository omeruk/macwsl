#if os(macOS)
    import Darwin
    import Foundation
    import MawCore

    /// The lock that a running daemon holds on `MawPaths.daemonLockFile(label:)`.
    ///
    /// Connecting to the daemon's Mach service makes launchd start it, so a client that only
    /// wants to know whether the daemon runs, such as `maw --status`, checks this lock instead.
    /// The kernel releases a `flock` when its holder exits, however it exits.
    public final class DaemonLock: Sendable {
        let descriptor: Int32

        private init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        /// Unlocks before closing. Closing alone releases a `flock` only when no other
        /// descriptor refers to the open file, and a child that another thread is starting has
        /// a copy of every descriptor until its `execve`, close-on-exec or not.
        deinit {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        /// Takes the lock, creating the file and its directory if needed. Returns `nil` if
        /// another process holds it.
        public static func acquire(at url: URL) throws(MawError) -> DaemonLock? {
            let path = url.path(percentEncoded: false)
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                throw .daemonUnreachable(
                    reason: "the lock file \(path) cannot be created: \(error)")
            }
            let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else {
                throw .daemonUnreachable(
                    reason:
                        "the lock file \(path) cannot be opened: \(String(cString: strerror(errno)))"
                )
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                return nil
            }
            return DaemonLock(descriptor: descriptor)
        }

        /// The labels of the daemons that hold their lock among the `<label>.lock` files in
        /// `directory` (`MawPaths.applicationSupportDirectory`), sorted.
        public static func labelsHeld(in directory: URL) -> [String] {
            let names =
                (try? FileManager.default.contentsOfDirectory(
                    atPath: directory.path(percentEncoded: false))) ?? []
            return names.filter { $0.hasSuffix(".lock") && $0.count > ".lock".count }
                .filter { isHeld(at: directory.appending(path: $0, directoryHint: .notDirectory)) }
                .map { String($0.dropLast(".lock".count)) }
                .sorted()
        }

        /// Whether a process holds the lock. A missing file means no daemon has run.
        public static func isHeld(at url: URL) -> Bool {
            let descriptor = open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
                flock(descriptor, LOCK_UN)
                return false
            }
            return errno == EWOULDBLOCK
        }
    }
#endif
