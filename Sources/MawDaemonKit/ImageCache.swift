#if os(macOS)
    import CryptoKit
    import Foundation
    import MawCore
    import MawXPC
    import os

    /// Distribution images in `~/Library/Caches/maw/images`, downloaded over HTTPS and verified
    /// against the catalog's SHA-256 before anything reads them.
    ///
    /// A download writes `<sha256>.<format>.partial` and keeps it when it is interrupted. The
    /// next download resumes it with a range request, made conditional with `If-Range` on the
    /// validator the server gave the first time, so that a changed file is downloaded afresh
    /// instead of being spliced together. A finished download is renamed to
    /// `<sha256>.<format>`, which `verify` checks before every use.
    public final class ImageCache: ImageSource {
        public let directory: URL
        private let session: URLSession
        private let log: DaemonLog

        /// - Parameter configuration: tests pass one with a stub protocol.
        public init(
            directory: URL, configuration: URLSessionConfiguration = .ephemeral,
            log: DaemonLog = DaemonLog()
        ) {
            self.directory = directory
            self.log = log
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 30
            session = URLSession(configuration: configuration)
        }

        func completeFile(for image: CatalogImage) -> URL {
            directory.appending(path: image.cacheFileName)
        }

        func partialFile(for image: CatalogImage) -> URL {
            directory.appending(path: image.cacheFileName + ".partial")
        }

        /// The validator (`ETag` or `Last-Modified`) of the partial file's response.
        func validatorFile(for image: CatalogImage) -> URL {
            directory.appending(path: image.cacheFileName + ".partial.validator")
        }

        public func downloadedBytes(of image: CatalogImage) -> UInt64 {
            if isComplete(image) {
                return image.size
            }
            return Self.size(of: partialFile(for: image)) ?? 0
        }

        public func isComplete(_ image: CatalogImage) -> Bool {
            Self.size(of: completeFile(for: image)) == image.size
        }

        // MARK: Download

        public func download(
            _ image: CatalogImage, progress: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws(MawError) {
            guard image.url.scheme == "https" else {
                throw .downloadFailed(
                    url: image.url.absoluteString, reason: "it does not use HTTPS")
            }
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
            } catch {
                throw .downloadFailed(
                    url: image.url.absoluteString,
                    reason: "\(directory.path(percentEncoded: false)) cannot be created: "
                        + error.localizedDescription)
            }
            let partial = partialFile(for: image)
            var existing = Self.size(of: partial) ?? 0
            let validator = try? String(contentsOf: validatorFile(for: image), encoding: .utf8)
            if existing > image.size || (existing > 0 && validator == nil) {
                // Larger than the image, or from a response without a validator: unusable.
                try? FileManager.default.removeItem(at: partial)
                existing = 0
            }
            if existing == image.size {
                try finishDownload(image)
                return
            }

            var request = URLRequest(url: image.url)
            if existing > 0, let validator {
                request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
                request.setValue(validator, forHTTPHeaderField: "If-Range")
            }
            let transfer = Transfer(
                image: image, partial: partial, validatorFile: validatorFile(for: image),
                existing: existing, progress: progress)
            log.notice(
                "downloading \(image.url.absoluteString)"
                    + (existing > 0 ? ", resuming after \(existing) bytes" : ""))
            try await transfer.run(request, on: session)
            try finishDownload(image)
        }

        private func finishDownload(_ image: CatalogImage) throws(MawError) {
            let complete = completeFile(for: image)
            try? FileManager.default.removeItem(at: complete)
            do {
                try FileManager.default.moveItem(at: partialFile(for: image), to: complete)
            } catch {
                throw .downloadFailed(
                    url: image.url.absoluteString,
                    reason: "the download cannot be saved: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: validatorFile(for: image))
        }

        // MARK: Verification

        public func verify(_ image: CatalogImage) async throws(MawError) -> URL {
            let file = completeFile(for: image)
            let path = file.path(percentEncoded: false)
            guard let size = Self.size(of: file) else {
                throw .imageMissing(path: path)
            }
            guard size == image.size else {
                try? FileManager.default.removeItem(at: file)
                throw .imageSizeMismatch(path: path, expected: image.size, actual: size)
            }
            let digest: String
            do {
                digest = try await Self.sha256(of: file)
            } catch {
                throw .imageMissing(path: path)
            }
            guard digest == image.sha256 else {
                try? FileManager.default.removeItem(at: file)
                log.error("\(path) has the SHA-256 \(digest), not \(image.sha256); removed")
                throw .imageChecksumMismatch(path: path, expected: image.sha256, actual: digest)
            }
            return file
        }

        /// The file's SHA-256 in lowercase hexadecimal, read in 4 MiB pieces off the caller's
        /// executor.
        static func sha256(of file: URL) async throws -> String {
            try await Task.detached(priority: .userInitiated) {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                var hasher = SHA256()
                while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                    try Task.checkCancellation()
                    hasher.update(data: chunk)
                }
                return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }.value
        }

        static func size(of file: URL) -> UInt64? {
            guard
                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: file.path(percentEncoded: false)),
                let size = attributes[.size] as? NSNumber
            else {
                return nil
            }
            return size.uint64Value
        }
    }

    /// One HTTP transfer into a partial file: appends after a `206`, starts over after a
    /// `200`, reports progress a few times a second, and refuses more bytes than the image has.
    private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let image: CatalogImage
        private let partial: URL
        private let validatorFile: URL
        private let progress: @Sendable (DownloadProgress) -> Void
        private let lock = NSLock()
        private var handle: FileHandle?
        private var received: UInt64
        private var resumedFrom: UInt64
        private var failure: MawError?
        private var continuation: CheckedContinuation<Void, Never>?
        /// Set when the task completes, which can happen before `run` has stored its
        /// continuation: a cancellation that arrives first cancels the task at once.
        private var isComplete = false
        private var lastReport = ContinuousClock.now - .seconds(1)
        private var rateSample: (instant: ContinuousClock.Instant, bytes: UInt64)
        private var bytesPerSecond: UInt64 = 0

        init(
            image: CatalogImage, partial: URL, validatorFile: URL, existing: UInt64,
            progress: @escaping @Sendable (DownloadProgress) -> Void
        ) {
            self.image = image
            self.partial = partial
            self.validatorFile = validatorFile
            self.progress = progress
            received = existing
            resumedFrom = existing
            rateSample = (.now, existing)
        }

        func run(_ request: URLRequest, on session: URLSession) async throws(MawError) {
            let task = session.dataTask(with: request)
            task.delegate = self
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let completed = lock.withLock { () -> Bool in
                        if isComplete { return true }
                        self.continuation = continuation
                        return false
                    }
                    if completed {
                        continuation.resume()
                    } else {
                        task.resume()
                    }
                }
            } onCancel: {
                task.cancel()
            }
            let failure = lock.withLock { () -> MawError? in
                try? handle?.close()
                handle = nil
                return self.failure
            }
            if Task.isCancelled {
                // The installer reports the cancellation; the partial file stays for the next
                // attempt.
                throw .downloadFailed(url: image.url.absoluteString, reason: "it was cancelled")
            }
            if let failure {
                throw failure
            }
        }

        // MARK: URLSessionDataDelegate

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest
        ) async -> URLRequest? {
            // HTTPS only, also after a redirect.
            guard newRequest.url?.scheme == "https" else {
                fail(
                    .downloadFailed(
                        url: image.url.absoluteString,
                        reason: "the server redirected to a URL without HTTPS"))
                return nil
            }
            return newRequest
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse
        ) async -> URLSession.ResponseDisposition {
            guard let http = response as? HTTPURLResponse else {
                fail(.downloadFailed(url: image.url.absoluteString, reason: "not an HTTP response"))
                return .cancel
            }
            do {
                switch http.statusCode {
                case 206:
                    let handle = try FileHandle(forWritingTo: partial)
                    try handle.seekToEnd()
                    lock.withLock { self.handle = handle }
                case 200:
                    // A first download, or a server that ignored the range or whose file
                    // changed: start over.
                    FileManager.default.createFile(
                        atPath: partial.path(percentEncoded: false), contents: nil)
                    let handle = try FileHandle(forWritingTo: partial)
                    let validator =
                        http.value(forHTTPHeaderField: "ETag")
                        ?? http.value(forHTTPHeaderField: "Last-Modified")
                    if let validator {
                        try validator.write(to: validatorFile, atomically: true, encoding: .utf8)
                    } else {
                        try? FileManager.default.removeItem(at: validatorFile)
                    }
                    lock.withLock {
                        self.handle = handle
                        received = 0
                        resumedFrom = 0
                        rateSample = (.now, 0)
                    }
                case 416:
                    // The partial file does not fit the server's file. The next attempt starts
                    // over.
                    try? FileManager.default.removeItem(at: partial)
                    try? FileManager.default.removeItem(at: validatorFile)
                    fail(
                        .downloadFailed(
                            url: image.url.absoluteString,
                            reason: "the interrupted download cannot be resumed, so it was "
                                + "discarded"))
                    return .cancel
                default:
                    let reason = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                    fail(
                        .downloadFailed(
                            url: image.url.absoluteString,
                            reason: "the server answered \(http.statusCode) \(reason)"))
                    return .cancel
                }
            } catch {
                fail(
                    .downloadFailed(
                        url: image.url.absoluteString,
                        reason: "the download cannot be written: \(error.localizedDescription)"))
                return .cancel
            }
            return .allow
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
        ) {
            let report: DownloadProgress? = lock.withLock {
                guard let handle, failure == nil else { return nil }
                guard received + UInt64(data.count) <= image.size else {
                    failure = .imageSizeMismatch(
                        path: partial.path(percentEncoded: false), expected: image.size,
                        actual: received + UInt64(data.count))
                    dataTask.cancel()
                    return nil
                }
                do {
                    try handle.write(contentsOf: data)
                } catch {
                    failure = .downloadFailed(
                        url: image.url.absoluteString,
                        reason: "the download cannot be written: \(error.localizedDescription)")
                    dataTask.cancel()
                    return nil
                }
                received += UInt64(data.count)
                let now = ContinuousClock.now
                let window = now - rateSample.instant
                if window >= .seconds(1) {
                    let seconds =
                        Double(window.components.seconds)
                        + Double(window.components.attoseconds) / 1e18
                    bytesPerSecond = UInt64(Double(received - rateSample.bytes) / seconds)
                    rateSample = (now, received)
                }
                guard now - lastReport >= .milliseconds(200) || received == image.size else {
                    return nil
                }
                lastReport = now
                return DownloadProgress(
                    receivedBytes: received, totalBytes: image.size,
                    bytesPerSecond: bytesPerSecond, resumedFromBytes: resumedFrom)
            }
            if let report {
                progress(report)
            }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
        ) {
            lock.withLock {
                if failure == nil, let error = error as? URLError, error.code != .cancelled {
                    failure = Self.map(error, url: image.url)
                } else if failure == nil, error == nil, received != image.size {
                    failure = .imageSizeMismatch(
                        path: partial.path(percentEncoded: false), expected: image.size,
                        actual: received)
                }
                isComplete = true
                continuation?.resume()
                continuation = nil
            }
        }

        private func fail(_ error: MawError) {
            lock.withLock {
                if failure == nil {
                    failure = error
                }
            }
        }

        static func map(_ error: URLError, url: URL) -> MawError {
            let host = url.host() ?? url.absoluteString
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                .cannotConnectToHost, .dnsLookupFailed, .timedOut, .internationalRoamingOff,
                .dataNotAllowed:
                return .networkUnavailable(host: host, reason: error.localizedDescription)
            default:
                return .downloadFailed(url: url.absoluteString, reason: error.localizedDescription)
            }
        }
    }
#endif
