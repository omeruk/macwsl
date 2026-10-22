import CryptoKit
import Foundation
import MawCore
import MawXPC
import Testing
import os

@testable import MawDaemonKit

/// `ImageCache` against a stub HTTP server, a `URLProtocol` that answers from memory.
@Suite(.serialized) struct ImageCacheTests {
    static let content = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    static let image = CatalogImage(
        url: URL(string: "https://images.example.com/test.tar.gz")!, format: .tarGzip,
        size: UInt64(content.count),
        sha256: SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined(),
        installedSize: 1)

    let directory: URL
    let cache: ImageCache

    init() {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "maw-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        cache = ImageCache(directory: directory, configuration: configuration)
        StubServer.reset()
    }

    func download(_ image: CatalogImage = Self.image) async throws(MawError) -> [DownloadProgress] {
        let reports = OSAllocatedUnfairLock(initialState: [DownloadProgress]())
        try await cache.download(image) { progress in reports.withLock { $0.append(progress) } }
        return reports.withLock { $0 }
    }

    @Test func downloadsVerifiesAndReportsProgress() async throws {
        #expect(!cache.isComplete(Self.image))
        let reports = try await download()
        #expect(cache.isComplete(Self.image))
        #expect(reports.last?.receivedBytes == Self.image.size)
        #expect(reports.last?.totalBytes == Self.image.size)
        let file = try await cache.verify(Self.image)
        #expect(try Data(contentsOf: file) == Self.content)
        #expect(file.lastPathComponent == Self.image.cacheFileName)
        #expect(StubServer.requests.first?.value(forHTTPHeaderField: "Range") == nil)
    }

    @Test func resumesAnInterruptedDownloadWithARangeRequest() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let half = Self.content.count / 2
        try Self.content.prefix(half).write(to: cache.partialFile(for: Self.image))
        try "\"v1\"".write(
            to: cache.validatorFile(for: Self.image), atomically: true, encoding: .utf8)
        #expect(cache.downloadedBytes(of: Self.image) == UInt64(half))

        let reports = try await download()
        let request = try #require(StubServer.requests.first)
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=\(half)-")
        #expect(request.value(forHTTPHeaderField: "If-Range") == "\"v1\"")
        #expect(reports.last?.resumedFromBytes == UInt64(half))
        #expect(try await cache.verify(Self.image).lastPathComponent == Self.image.cacheFileName)
    }

    @Test func startsOverWhenTheServerSendsTheWholeFile() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A partial file of another version: the server ignores the range because the
        // validator no longer matches.
        try Data(repeating: 0xFF, count: 1000).write(to: cache.partialFile(for: Self.image))
        try "\"old\"".write(
            to: cache.validatorFile(for: Self.image), atomically: true, encoding: .utf8)
        StubServer.honorsRanges = false
        _ = try await download()
        _ = try await cache.verify(Self.image)
    }

    @Test func discardsAPartialFileWithoutAValidator() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: 1000).write(to: cache.partialFile(for: Self.image))
        _ = try await download()
        #expect(StubServer.requests.first?.value(forHTTPHeaderField: "Range") == nil)
        _ = try await cache.verify(Self.image)
    }

    @Test func reportsAnHTTPError() async {
        StubServer.status = 404
        await #expect(
            throws: MawError.downloadFailed(
                url: Self.image.url.absoluteString, reason: "the server answered 404 not found")
        ) {
            try await download()
        }
        #expect(!cache.isComplete(Self.image))
    }

    @Test func reportsAMissingNetwork() async {
        StubServer.failure = URLError(.notConnectedToInternet)
        await #expect {
            try await download()
        } throws: { error in
            guard case .networkUnavailable(let host, _) = error as? MawError else { return false }
            return host == "images.example.com"
        }
    }

    @Test func refusesPlainHTTP() async {
        var image = Self.image
        image.url = URL(string: "http://images.example.com/test.tar.gz")!
        await #expect(
            throws: MawError.downloadFailed(
                url: image.url.absoluteString, reason: "it does not use HTTPS")
        ) {
            try await download(image)
        }
        #expect(StubServer.requests.isEmpty)
    }

    @Test func refusesARedirectToPlainHTTP() async {
        StubServer.redirect = URL(string: "http://images.example.com/test.tar.gz")!
        await #expect(
            throws: MawError.downloadFailed(
                url: Self.image.url.absoluteString,
                reason: "the server redirected to a URL without HTTPS")
        ) {
            try await download(Self.image)
        }
        #expect(StubServer.requests.count == 1)
    }

    @Test func followsARedirectToHTTPS() async throws {
        StubServer.redirect = URL(string: "https://mirror.example.com/test.tar.gz")!
        _ = try await download(Self.image)
        #expect(
            StubServer.requests.map(\.url?.host) == ["images.example.com", "mirror.example.com"])
    }

    @Test func refusesMoreBytesThanTheImageHas() async {
        StubServer.body = Self.content + Data(count: 10)
        await #expect {
            try await download()
        } throws: { error in
            if case .imageSizeMismatch = error as? MawError { true } else { false }
        }
        #expect(!cache.isComplete(Self.image))
    }

    // MARK: Verification

    @Test func rejectsAndRemovesAFileWithAnotherHash() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var altered = Self.content
        altered[100] ^= 0x01
        let file = cache.completeFile(for: Self.image)
        try altered.write(to: file)
        await #expect {
            try await cache.verify(Self.image)
        } throws: { error in
            guard case .imageChecksumMismatch(_, let expected, let actual) = error as? MawError
            else { return false }
            return expected == Self.image.sha256 && actual != expected
        }
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    @Test func rejectsATruncatedFile() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = cache.completeFile(for: Self.image)
        try Self.content.prefix(1000).write(to: file)
        await #expect(
            throws: MawError.imageSizeMismatch(
                path: file.path(percentEncoded: false), expected: Self.image.size, actual: 1000)
        ) {
            try await cache.verify(Self.image)
        }
    }

    @Test func rejectsAMissingFile() async {
        await #expect(
            throws: MawError.imageMissing(
                path: cache.completeFile(for: Self.image).path(percentEncoded: false))
        ) {
            try await cache.verify(Self.image)
        }
    }
}

/// Answers every request from memory: the whole body with `200`, or the requested range with
/// `206` when `honorsRanges` and the `If-Range` validator matches `"v1"`.
final class StubServer: URLProtocol, @unchecked Sendable {
    private struct State {
        var requests: [URLRequest] = []
        var body = ImageCacheTests.content
        var status = 200
        var honorsRanges = true
        var failure: URLError?
        var redirect: URL?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func reset() { state.withLock { $0 = State() } }
    static var requests: [URLRequest] { state.withLock { $0.requests } }
    static var body: Data {
        get { state.withLock { $0.body } }
        set { state.withLock { $0.body = newValue } }
    }
    static var status: Int {
        get { state.withLock { $0.status } }
        set { state.withLock { $0.status = newValue } }
    }
    static var honorsRanges: Bool {
        get { state.withLock { $0.honorsRanges } }
        set { state.withLock { $0.honorsRanges = newValue } }
    }
    static var failure: URLError? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }
    /// Where the first request is redirected to, with `302 Found`.
    static var redirect: URL? {
        get { state.withLock { $0.redirect } }
        set { state.withLock { $0.redirect = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let current = Self.state.withLock { state -> State in
            state.requests.append(request)
            return state
        }
        if let failure = current.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        if let redirect = current.redirect, current.requests.count == 1 {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirect.absoluteString])!
            client?.urlProtocol(
                self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var status = current.status
        var body = current.body
        if status == 200, current.honorsRanges,
            let range = request.value(forHTTPHeaderField: "Range"),
            request.value(forHTTPHeaderField: "If-Range") == "\"v1\"",
            let start = Int(range.dropFirst("bytes=".count).dropLast())
        {
            status = 206
            body = body.subdata(in: start..<body.count)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["ETag": "\"v1\"", "Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status == 200 || status == 206 {
            // In pieces, as a network delivers it.
            var offset = 0
            while offset < body.count {
                let end = min(offset + (256 << 10), body.count)
                client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
                offset = end
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
