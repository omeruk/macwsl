#if os(macOS)
    import Darwin
    import Foundation
    import MacWSLCore
    import os

    /// The guest's console: the host side of the virtio console (hvc0).
    ///
    /// The guest writes into one pipe and reads from another. A dedicated thread reads the
    /// guest's output and passes each chunk, in order, to:
    ///
    /// 1. the console log, with one rotation at `rotationSize` (the previous log is kept as
    ///    `<name>.1`);
    /// 2. the optional `output` handle, such as the terminal in an interactive session;
    /// 3. the `lines` stream.
    ///
    /// Back-pressure policy:
    ///
    /// - **The log and `output` never drop data.** The thread writes to them synchronously.
    ///   When either is slow, the thread reads more slowly, the pipe fills, and the guest
    ///   blocks on its next console write until there is room again.
    /// - **`lines` is bounded.** It holds at most `lineBufferLimit` lines that no consumer has
    ///   taken yet, and discards the oldest when a consumer falls behind or never reads
    ///   (`bufferingNewest`). A line longer than `maximumLineLength` is delivered in pieces.
    ///   Memory therefore stays bounded whatever the consumer does, and the log still contains
    ///   every line.
    ///
    /// If an `input` handle is given, a second thread copies it to the guest.
    final class Console: Sendable {
        static let defaultRotationSize: UInt64 = 10 << 20
        static let defaultLineBufferLimit = 1_000
        static let maximumLineLength = 64 << 10

        /// The guest writes its console output into this pipe.
        let fromGuest = Pipe()
        /// The guest reads its console input from this pipe.
        let toGuest = Pipe()

        /// Lines of guest output, without line terminators. See the back-pressure policy.
        let lines: AsyncStream<String>
        private let lineContinuation: AsyncStream<String>.Continuation
        private let drained: AsyncStream<Void>
        private let drainedContinuation: AsyncStream<Void>.Continuation

        let logURL: URL
        private let log: OSAllocatedUnfairLock<LogFile>
        private let output: FileHandle?
        private let input: FileHandle?

        init(
            logURL: URL,
            output: FileHandle? = nil,
            input: FileHandle? = nil,
            lineBufferLimit: Int = Console.defaultLineBufferLimit,
            rotationSize: UInt64 = Console.defaultRotationSize
        ) throws(MacWSLError) {
            self.logURL = logURL
            self.output = output
            self.input = input
            (lines, lineContinuation) = AsyncStream.makeStream(
                of: String.self, bufferingPolicy: .bufferingNewest(max(1, lineBufferLimit)))
            (drained, drainedContinuation) = AsyncStream.makeStream(of: Void.self)
            log = OSAllocatedUnfairLock(
                uncheckedState: try LogFile(url: logURL, rotationSize: rotationSize))
            // A write to the guest after it has gone must fail with EPIPE, not kill the process.
            _ = fcntl(toGuest.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        }

        /// Starts the threads that copy console data. Call once.
        func start() {
            Thread { [self] in pumpGuestOutput() }.start()
            if let input {
                Thread { [self] in pumpInput(from: input) }.start()
            }
        }

        /// Appends a line from the host to the log, marked `[macwsld]` and timestamped, so that
        /// lifecycle events appear in order with the guest's output.
        func note(_ message: String) {
            let timestamp = Date.now.formatted(.iso8601)
            log.withLockUnchecked { log in
                let separator = log.isAtLineStart ? "" : "\n"
                log.write(Data("\(separator)[macwsld] \(timestamp) \(message)\n".utf8))
            }
        }

        /// Closes the host's copies of the guest's ends of both pipes, so that the reader
        /// thread sees end-of-file once the virtual machine has released its copies.
        func closeGuestSide() {
            try? fromGuest.fileHandleForWriting.close()
            try? toGuest.fileHandleForReading.close()
        }

        /// Waits until the reader thread has passed on all guest output and finished `lines`.
        func waitUntilDrained() async {
            for await _ in drained {}
        }

        /// Writes `data` to the log as if the guest had written it. For tests.
        func ingest(_ data: Data) {
            try? fromGuest.fileHandleForWriting.write(contentsOf: data)
        }

        // MARK: Threads

        private func pumpGuestOutput() {
            let descriptor = fromGuest.fileHandleForReading.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 16 << 10)
            var splitter = LineSplitter(maximumLineLength: Self.maximumLineLength)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    read(descriptor, $0.baseAddress, $0.count)
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                let chunk = Data(buffer[..<count])
                log.withLockUnchecked { $0.write(chunk) }
                if let output {
                    try? output.write(contentsOf: chunk)
                }
                for line in splitter.append(chunk) {
                    lineContinuation.yield(line)
                }
            }
            if let rest = splitter.finish() {
                lineContinuation.yield(rest)
            }
            lineContinuation.finish()
            drainedContinuation.finish()
        }

        private func pumpInput(from input: FileHandle) {
            let source = input.fileDescriptor
            let destination = toGuest.fileHandleForWriting.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 4 << 10)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0, Self.writeAll(buffer[..<count], to: destination) else { break }
            }
        }

        private static func writeAll(_ bytes: ArraySlice<UInt8>, to descriptor: Int32) -> Bool {
            var remaining = bytes[...]
            while !remaining.isEmpty {
                let written = remaining.withUnsafeBytes {
                    write(descriptor, $0.baseAddress, $0.count)
                }
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                remaining = remaining.dropFirst(written)
            }
            return true
        }
    }

    /// The console log file, with a single rotation.
    struct LogFile {
        let url: URL
        let rotatedURL: URL
        let rotationSize: UInt64
        private var handle: FileHandle
        private(set) var size: UInt64
        private(set) var isAtLineStart = true
        private var reportedFailure = false

        init(url: URL, rotationSize: UInt64) throws(MacWSLError) {
            self.url = url
            self.rotatedURL = url.appendingPathExtension("1")
            self.rotationSize = rotationSize
            (handle, size) = try Self.open(url)
            if size >= rotationSize {
                try rotate()
            }
        }

        /// Writes `data`, rotating first if the log has reached `rotationSize`. A failure is
        /// reported once through the unified log; the console keeps running without the file.
        mutating func write(_ data: Data) {
            guard !data.isEmpty else { return }
            do {
                if size >= rotationSize {
                    try rotate()
                }
                try handle.write(contentsOf: data)
                size += UInt64(data.count)
                isAtLineStart = data.last == UInt8(ascii: "\n")
            } catch {
                if !reportedFailure {
                    reportedFailure = true
                    let failure = error as? MacWSLError ?? failure(error)
                    Logger.virtualization.error("\(failure.description, privacy: .public)")
                }
            }
        }

        private mutating func rotate() throws(MacWSLError) {
            try? handle.close()
            let fileManager = FileManager.default
            do {
                if fileManager.fileExists(atPath: rotatedURL.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: rotatedURL)
                }
                try fileManager.moveItem(at: url, to: rotatedURL)
            } catch {
                throw failure(error)
            }
            (handle, size) = try Self.open(url)
            isAtLineStart = true
        }

        private static func open(_ url: URL) throws(MacWSLError) -> (FileHandle, UInt64) {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                    guard
                        fileManager.createFile(
                            atPath: url.path(percentEncoded: false), contents: nil)
                    else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                let handle = try FileHandle(forWritingTo: url)
                return (handle, try handle.seekToEnd())
            } catch {
                throw .consoleLogFailed(
                    path: url.path(percentEncoded: false), reason: error.localizedDescription)
            }
        }

        private func failure(_ error: any Error) -> MacWSLError {
            .consoleLogFailed(
                path: url.path(percentEncoded: false), reason: error.localizedDescription)
        }
    }

    /// Splits a byte stream into lines. A line ends at "\n"; a trailing "\r" is removed. A
    /// partial line longer than `maximumLineLength` is emitted in pieces, so that the pending
    /// buffer stays bounded.
    struct LineSplitter {
        let maximumLineLength: Int
        private var pending: [UInt8] = []

        init(maximumLineLength: Int) {
            self.maximumLineLength = maximumLineLength
        }

        mutating func append(_ bytes: some Sequence<UInt8>) -> [String] {
            var lines: [String] = []
            for byte in bytes {
                if byte == UInt8(ascii: "\n") {
                    lines.append(Self.line(from: pending))
                    pending.removeAll(keepingCapacity: true)
                } else {
                    pending.append(byte)
                    if pending.count >= maximumLineLength {
                        lines.append(Self.line(from: pending))
                        pending.removeAll(keepingCapacity: true)
                    }
                }
            }
            return lines
        }

        /// The final, unterminated line, if any.
        mutating func finish() -> String? {
            defer { pending.removeAll() }
            return pending.isEmpty ? nil : Self.line(from: pending)
        }

        private static func line(from bytes: [UInt8]) -> String {
            let trimmed = bytes.last == UInt8(ascii: "\r") ? bytes.dropLast() : bytes[...]
            return String(decoding: trimmed, as: UTF8.self)
        }
    }
#endif
