#if os(macOS)
    import Darwin
    import Foundation
    import MawCore
    import MawProtocol
    import os

    /// Where an export's archive goes: the descriptor that the client opened, written by the
    /// daemon itself, so that one count of bytes and one place see every write error. A `tar`
    /// archive is written as the guest's `bsdtar` produces it; `tar.gz` and `tar.xz` pass
    /// through `/usr/bin/tar` on the Mac, which compresses them, and whose output the daemon
    /// writes.
    ///
    /// ```
    /// bsdtar ─▶ write(_:) ─────────────────────────────────▶ descriptor        tar
    /// bsdtar ─▶ write(_:) ─▶ pipe ─▶ /usr/bin/tar -z|-J ─▶ ─▶ descriptor   tar.gz, tar.xz
    /// ```
    ///
    /// A thread of its own writes to the descriptor, one chunk at a time; while the reader does
    /// not read, the next chunk waits for it, which holds the guest's `bsdtar` back
    /// (docs/daemon.md, "Exporting a distribution"), so nothing is buffered beyond the pipes and
    /// two chunks. A reader that closes its end ends the export as `readerClosed`: the daemon
    /// ignores SIGPIPE, so the write fails with `EPIPE`. `abort()` ends the export at once even
    /// while a write waits for a reader that has stopped reading.
    final class ArchiveOutput: Sendable {
        enum Failure: Error, Equatable, Sendable {
            /// The reader of a pipe closed its end before the archive was complete.
            case readerClosed
            /// A write failed for another reason, such as a full volume.
            case writeFailed(String)
            /// `/usr/bin/tar` could not start, or exited with an error.
            case compressorFailed(String)
        }

        /// What an export wrote, and why it stopped early if it did.
        struct Outcome: Equatable, Sendable {
            var bytes: UInt64
            var failure: Failure?
        }

        /// Writes to the client's descriptor on a thread of its own.
        private let writer: DescriptorWriter
        /// The write end of the pipe to `/usr/bin/tar`, for a compressed archive.
        private let compressorInput: OwnedDescriptor?
        private let compressor: Task<Result<StreamingProcess.Outcome, any Error>, Never>?
        /// Whether `abort()` was called; `/usr/bin/tar` failing then is not the archive's failure.
        private let aborted = OSAllocatedUnfairLock(initialState: false)

        /// The arguments of `/usr/bin/tar` that compress a pax archive from its standard input
        /// into its standard output.
        static func compressorArguments(for format: ArchiveFormat) -> [String]? {
            let option: String
            switch format {
            case .tar: return nil
            case .tarGzip: option = "--gzip"
            case .tarXz: option = "--xz"
            }
            return ["-c", "-f", "-", "--format", "pax", option, "@-"]
        }

        /// Prepares the archive's way to `destination`, and starts `/usr/bin/tar` for a
        /// compressed format. `destination` is the client's descriptor, which this takes over
        /// and closes once its last write has returned. Throws `compressorFailed` if the pipe
        /// to `/usr/bin/tar` or the writing thread cannot be made.
        ///
        /// The descriptor's open file description is the client's, shared with every process
        /// that inherited it, so nothing about it is changed here: the daemon ignores SIGPIPE,
        /// and a write to a pipe whose reader has gone fails with `EPIPE`.
        init(format: ArchiveFormat, destination: OwnedDescriptor) throws(Failure) {
            writer = try DescriptorWriter(destination)
            guard let arguments = Self.compressorArguments(for: format) else {
                compressorInput = nil
                compressor = nil
                return
            }
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else {
                writer.abort()
                writer.end()
                throw .compressorFailed(SystemError("pipe").description)
            }
            _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
            // The daemon's own pipe: a write after /usr/bin/tar has gone fails with EPIPE.
            _ = fcntl(fds[1], F_SETNOSIGPIPE, 1)
            let reader = OwnedDescriptor(fds[0])
            compressorInput = OwnedDescriptor(fds[1])
            let writer = self.writer
            compressor = Task {
                await runOnDedicatedThread { () -> Result<StreamingProcess.Outcome, any Error> in
                    Result {
                        try StreamingProcess.run("/usr/bin/tar", arguments, input: reader) {
                            chunk in
                            chunk.withUnsafeBytes { writer.write($0) }
                        }
                    }
                }
            }
        }

        /// Takes the next chunk of the guest's archive. Called on one thread, in order. Returns
        /// false once the archive cannot go on: its reader closed its end, a write failed, the
        /// compressor stopped, or `abort()` was called.
        func write(_ buffer: UnsafeRawBufferPointer) -> Bool {
            guard let compressorInput else {
                return writer.write(buffer)
            }
            if aborted.withLock({ $0 }) || writer.hasStopped {
                return false
            }
            // A failed write to the pipe means that /usr/bin/tar has stopped reading; `finish()`
            // reports why.
            return Self.writeAll(compressorInput.rawValue, buffer) == nil
        }

        /// Stops the archive early: nothing more is handed to the descriptor's thread, a write
        /// that waits for it returns at once, and `/usr/bin/tar` is ended at its next output.
        /// The pipe to it is closed by `finish()`, once the guest's output has stopped, so that
        /// no write races with the close.
        func abort() {
            aborted.withLock { $0 = true }
            writer.abort()
        }

        /// Ends the archive's input, waits for `/usr/bin/tar` to have written the rest and for
        /// the descriptor's thread to have written everything, and returns what was written;
        /// the descriptor is then closed, so that the client may remove its file. Call it once
        /// `write(_:)` is no longer called.
        ///
        /// After `abort()` it does not wait for a write that the descriptor's reader holds up,
        /// which may never return: that write's thread closes the descriptor when it does, and
        /// writes nothing more.
        func finish() async -> Outcome {
            compressorInput?.close()
            var compressorFailure: Failure?
            if let compressor {
                switch await compressor.value {
                case .failure(let error):
                    compressorFailure = .compressorFailed(
                        "/usr/bin/tar cannot start: \(error.localizedDescription)")
                case .success(let outcome) where outcome.status != 0:
                    compressorFailure = .compressorFailed(
                        "/usr/bin/tar exited with status \(outcome.status): \(outcome.errors)")
                case .success:
                    break
                }
            }
            let written = await writer.finish()
            if written.failure == nil, !aborted.withLock({ $0 }), let compressorFailure {
                return Outcome(bytes: written.bytes, failure: compressorFailure)
            }
            return written
        }

        /// Writes the archive to the client's descriptor on a detached thread of its own, one
        /// chunk at a time, so that the threads that produce the archive wait on a condition
        /// that `abort()` ends, never in a `write` that only the reader can end.
        private final class DescriptorWriter: @unchecked Sendable {
            private struct State {
                /// The chunk that the thread is to write or is writing.
                var pending: [UInt8]?
                var bytes: UInt64 = 0
                var failure: Failure?
                var aborted = false
                /// Set by `end()`: no chunk follows.
                var ended = false
                /// Set by the thread once it has closed the descriptor.
                var closed = false
            }

            /// Guards `state`.
            private let lock = ConditionLock()
            private var state = State()

            init(_ destination: OwnedDescriptor) throws(Failure) {
                let started = startDetachedThread { [self] in
                    run(destination)
                }
                guard started else {
                    destination.close()
                    throw .compressorFailed("the thread that writes the archive cannot start")
                }
            }

            /// Whether nothing more will be written: a write failed, or `abort()` was called.
            var hasStopped: Bool {
                lock.withLock { state.failure != nil || state.aborted }
            }

            /// Hands a copy of `buffer` to the thread, once it has written the previous chunk.
            /// Returns false if the archive cannot go on.
            func write(_ buffer: UnsafeRawBufferPointer) -> Bool {
                let chunk = [UInt8](buffer)
                return lock.withLock {
                    while state.pending != nil, state.failure == nil, !state.aborted {
                        lock.wait()
                    }
                    guard state.failure == nil, !state.aborted else { return false }
                    state.pending = chunk
                    lock.broadcast()
                    return true
                }
            }

            func abort() {
                lock.withLock {
                    state.aborted = true
                    lock.broadcast()
                }
            }

            /// Tells the thread that no chunk follows.
            func end() {
                lock.withLock {
                    state.ended = true
                    lock.broadcast()
                }
            }

            /// Ends the input and waits until the thread has written everything and closed the
            /// descriptor, or, after `abort()`, not at all.
            func finish() async -> Outcome {
                end()
                return await runOnDedicatedThread { [self] in
                    lock.withLock {
                        // After `abort()`, a chunk in progress is the thread's to finish.
                        while !state.closed, !state.aborted {
                            lock.wait()
                        }
                        return Outcome(bytes: state.bytes, failure: state.failure)
                    }
                }
            }

            /// The thread: writes each chunk, and closes the descriptor once the input has ended
            /// or the archive cannot go on.
            private func run(_ destination: OwnedDescriptor) {
                while true {
                    let chunk: [UInt8]? = lock.withLock {
                        while state.pending == nil, !state.ended, !state.aborted,
                            state.failure == nil
                        {
                            lock.wait()
                        }
                        if state.aborted || state.failure != nil { return nil }
                        return state.pending
                    }
                    guard let chunk else { break }
                    let code = chunk.withUnsafeBytes {
                        ArchiveOutput.writeAll(destination.rawValue, $0)
                    }
                    lock.withLock {
                        state.pending = nil
                        if let code {
                            state.failure =
                                code == EPIPE
                                ? .readerClosed : .writeFailed(SystemError.message(for: code))
                        } else {
                            state.bytes += UInt64(chunk.count)
                        }
                        lock.broadcast()
                    }
                }
                destination.close()
                lock.withLock {
                    state.pending = nil
                    state.closed = true
                    lock.broadcast()
                }
            }
        }

        /// Writes all of `buffer` to `descriptor`, waiting while a non-blocking descriptor is
        /// full. Returns the errno value of a failed write, or `nil`.
        static func writeAll(_ descriptor: Int32, _ buffer: UnsafeRawBufferPointer) -> Int32? {
            guard descriptor >= 0 else { return EBADF }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written >= 0 {
                    offset += written
                    continue
                }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN:
                    var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&poller, 1, -1)
                default:
                    return errno
                }
            }
            return nil
        }
    }
#endif
