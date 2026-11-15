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
    /// Every write blocks while the reader does not read, which holds the guest's `bsdtar`
    /// back (docs/daemon.md, "Exporting a distribution"), so nothing is buffered beyond the
    /// pipes and one chunk. A reader that closes its end ends the export as `readerClosed`: the
    /// daemon ignores SIGPIPE, and the descriptor does not raise it, so the write fails with
    /// `EPIPE`.
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

        private let destination: OwnedDescriptor
        /// The write end of the pipe to `/usr/bin/tar`, for a compressed archive.
        private let compressorInput: OwnedDescriptor?
        private let compressor: Task<Result<StreamingProcess.Outcome, any Error>, Never>?
        private let state = OSAllocatedUnfairLock(
            initialState: (bytes: UInt64(0), failure: Failure?.none, aborted: false))

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
        /// compressed format. `destination` is the client's descriptor; it is closed when the
        /// archive is complete or has failed. Throws `compressorFailed` if the pipe to
        /// `/usr/bin/tar` cannot be made.
        init(format: ArchiveFormat, destination: OwnedDescriptor) throws(Failure) {
            self.destination = destination
            // A descriptor of a pipe or a socket that a client passes never raises SIGPIPE here.
            _ = fcntl(destination.rawValue, F_SETNOSIGPIPE, 1)
            guard let arguments = Self.compressorArguments(for: format) else {
                compressorInput = nil
                compressor = nil
                return
            }
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else {
                throw .compressorFailed(SystemError("pipe").description)
            }
            _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
            _ = fcntl(fds[1], F_SETNOSIGPIPE, 1)
            let reader = OwnedDescriptor(fds[0])
            compressorInput = OwnedDescriptor(fds[1])
            // `self` cannot be captured before every property is set, so the compressor writes
            // through a sink of its own that shares the state and the destination.
            let sink = Sink(destination: destination, state: state)
            compressor = Task {
                await runOnDedicatedThread { () -> Result<StreamingProcess.Outcome, any Error> in
                    Result {
                        try StreamingProcess.run("/usr/bin/tar", arguments, input: reader) {
                            chunk in
                            chunk.withUnsafeBytes { sink.write($0) }
                        }
                    }
                }
            }
        }

        /// Takes the next chunk of the guest's archive. Called on one thread, in order. Returns
        /// false once the archive cannot go on: its reader closed its end, a write failed, the
        /// compressor stopped, or `abort()` was called.
        func write(_ buffer: UnsafeRawBufferPointer) -> Bool {
            if state.withLock({ $0.aborted || $0.failure != nil }) {
                return false
            }
            guard let compressorInput else {
                return Sink(destination: destination, state: state).write(buffer)
            }
            // A failed write to the pipe means that /usr/bin/tar has stopped reading; `finish()`
            // reports why.
            return Self.writeAll(compressorInput.rawValue, buffer) == nil
        }

        /// Stops the archive early: nothing more is written to the descriptor, and
        /// `/usr/bin/tar` is ended at its next output. The pipe to it is closed by `finish()`,
        /// once the guest's output has stopped, so that no write races with the close.
        func abort() {
            state.withLock { $0.aborted = true }
        }

        /// Ends the archive's input, waits for `/usr/bin/tar` to have written the rest, closes
        /// the descriptor, and returns what was written. Call it once `write(_:)` is no longer
        /// called. After it returns, nothing writes to the descriptor any more, so that the
        /// client may remove its file.
        func finish() async -> Outcome {
            compressorInput?.close()
            if let compressor {
                let result = await compressor.value
                state.withLock { state in
                    guard state.failure == nil, !state.aborted else { return }
                    switch result {
                    case .failure(let error):
                        state.failure = .compressorFailed(
                            "/usr/bin/tar cannot start: \(error.localizedDescription)")
                    case .success(let outcome) where outcome.status != 0:
                        state.failure = .compressorFailed(
                            "/usr/bin/tar exited with status \(outcome.status): \(outcome.errors)")
                    case .success:
                        break
                    }
                }
            }
            destination.close()
            return state.withLock { Outcome(bytes: $0.bytes, failure: $0.failure) }
        }

        /// Writes to the client's descriptor and counts what it wrote.
        private struct Sink: Sendable {
            let destination: OwnedDescriptor
            let state: OSAllocatedUnfairLock<(bytes: UInt64, failure: Failure?, aborted: Bool)>

            func write(_ buffer: UnsafeRawBufferPointer) -> Bool {
                if state.withLock({ $0.aborted || $0.failure != nil }) {
                    return false
                }
                if let code = ArchiveOutput.writeAll(destination.rawValue, buffer) {
                    state.withLock {
                        $0.failure =
                            code == EPIPE
                            ? .readerClosed : .writeFailed(SystemError.message(for: code))
                    }
                    return false
                }
                let count = UInt64(buffer.count)
                state.withLock { $0.bytes += count }
                return true
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
