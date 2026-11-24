import CMawSystem
import Logging
import MawProtocol
import Testing

@testable import MawAgentKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The agent's DNS server on 127.0.0.1 and a free port, with the test as its resolver's client
/// and as the host at the other end of the channel.
@Suite(.serialized, .timeLimit(.minutes(2))) struct DNSServerTests {
    static let loopback: [UInt8] = [127, 0, 0, 1]
    static let patience = Duration.seconds(10)

    final class Harness: @unchecked Sendable {
        let server: DNSServer
        let port: UInt16
        private var host: FrameConnection?
        private let lock = ConditionLock()
        private var attachEnded = false

        init(_ configure: (inout DNSEnvironment) -> Void = { _ in }) throws {
            port = try #require(Harness.freePort())
            var environment = DNSEnvironment(address: DNSServerTests.loopback, port: port)
            configure(&environment)
            server = try DNSServer(environment: environment, logger: Logger(label: "test"))
            try #require(server.start())
            let deadline = ContinuousClock.now + DNSServerTests.patience
            while !server.isListening, ContinuousClock.now < deadline {
                usleep(5_000)
            }
            try #require(server.isListening)
        }

        /// A port that is free for UDP and TCP on 127.0.0.1 a moment ago.
        static func freePort() -> UInt16? {
            for _ in 0..<50 {
                let port = UInt16.random(in: 20_000...60_000)
                var datagram: Int32 = -1
                var stream: Int32 = -1
                let free = DNSServerTests.loopback.withUnsafeBufferPointer {
                    maw_inet4_bind(0, $0.baseAddress!, port, 0, &datagram) == 0
                        && maw_inet4_bind(1, $0.baseAddress!, port, 1, &stream) == 0
                }
                if datagram >= 0 { close(datagram) }
                if stream >= 0 { close(stream) }
                if free { return port }
            }
            return nil
        }

        /// Opens the DNS channel; returns the host's end.
        @discardableResult
        func attach() throws -> FrameConnection {
            var fds: [Int32] = [-1, -1]
            try #require(maw_socketpair(&fds) == 0)
            let agentSide = try FrameConnection(OwnedDescriptor(fds[0]))
            let hostSide = try FrameConnection(OwnedDescriptor(fds[1]))
            lock.withLock { attachEnded = false }
            _ = startDetachedThread { [self] in
                try? server.attach(agentSide)
                agentSide.descriptor.close()
                lock.withLock { attachEnded = true }
            }
            host = hostSide
            return hostSide
        }

        var hasAttachEnded: Bool { lock.withLock { attachEnded } }

        /// The next query on the channel, or `nil` if none comes within `timeout`.
        func nextQuery(within timeout: Duration = DNSServerTests.patience) -> (
            tag: UInt32, message: [UInt8]
        )? {
            guard let frame = try? host?.receiveFrame(until: .now + timeout) else { return nil }
            #expect(frame.type == .dnsQuery)
            return try? frame.dnsMessage()
        }

        func answer(_ tag: UInt32, _ response: [UInt8]) throws {
            let host = try #require(host)
            host.enqueue(.dns(.dnsAnswer, tag: tag, message: response))
            try host.flush(until: .now + DNSServerTests.patience)
        }

        func closeChannel() {
            host?.descriptor.close()
            host = nil
        }
    }

    // MARK: A client of the server

    final class Client {
        let descriptor: Int32
        let port: UInt16

        init(port: UInt16) {
            self.port = port
            descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        }

        deinit { close(descriptor) }

        func send(_ bytes: [UInt8]) {
            var address = DNSServerTests.address(port)
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        descriptor, bytes, bytes.count, 0, $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        func receive(within timeout: Duration = DNSServerTests.patience) -> [UInt8]? {
            var request = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)]
            guard (try? pollDescriptors(&request, timeout: pollTimeout(until: .now + timeout))) == 1
            else { return nil }
            var buffer = [UInt8](repeating: 0, count: 8_192)
            let count = recv(descriptor, &buffer, buffer.count, 0)
            return count > 0 ? Array(buffer[..<count]) : nil
        }
    }

    static func address(_ port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        return address
    }

    static func query(
        _ name: String, type: UInt16 = DNSRecordType.a, id: UInt16 = 7, payload: UInt16? = 1_232
    ) -> DNSQuery {
        DNSQuery(id: id, name: DNSName(presentation: name)!, type: type, ednsPayloadSize: payload)
    }

    static func answer(_ query: DNSQuery, address: [UInt8] = [192, 0, 2, 1]) -> [UInt8] {
        DNSResponse.encode(
            query, code: .noError,
            answers: [
                DNSRecord(name: query.name, type: DNSRecordType.a, timeToLive: 60, data: address)
            ])
    }

    // MARK: Tests

    @Test func passesAQueryToTheHostAndItsAnswerToTheClient() throws {
        let harness = try Harness()
        try harness.attach()
        let client = Client(port: harness.port)
        let query = Self.query("github.com")
        client.send(query.encoded)
        let (tag, message) = try #require(harness.nextQuery())
        #expect(message == query.encoded)
        try harness.answer(tag, Self.answer(query))
        #expect(client.receive() == Self.answer(query))
    }

    @Test func answersMalformedUnsupportedAndLocalQueriesItself() throws {
        let harness = try Harness()
        try harness.attach()
        let client = Client(port: harness.port)
        // Two questions: FORMERR.
        var two = Self.query("example.com").encoded
        two[5] = 2
        client.send(two)
        #expect(client.receive().flatMap(DNSResponse.code(of:)) == .formatError)
        client.send(Self.query("example.com", type: 257).encoded)
        #expect(client.receive().flatMap(DNSResponse.code(of:)) == .notImplemented)
        client.send(Self.query("printer.local").encoded)
        #expect(client.receive().flatMap(DNSResponse.code(of:)) == .refused)
        // Too short to answer: nothing.
        client.send([1, 2, 3])
        #expect(client.receive(within: .milliseconds(200)) == nil)
        #expect(harness.nextQuery(within: .milliseconds(200)) == nil)
    }

    @Test func holdsAQueryUntilTheChannelOpens() throws {
        let harness = try Harness { $0.holdTimeout = .seconds(5) }
        let client = Client(port: harness.port)
        let query = Self.query("early.example")
        client.send(query.encoded)
        usleep(100_000)
        try harness.attach()
        let (tag, message) = try #require(harness.nextQuery())
        #expect(message == query.encoded)
        try harness.answer(tag, Self.answer(query))
        #expect(client.receive() == Self.answer(query))
    }

    @Test func answersSERVFAILWhenNoChannelOpensInTime() throws {
        let harness = try Harness { $0.holdTimeout = .milliseconds(200) }
        let client = Client(port: harness.port)
        client.send(Self.query("lonely.example").encoded)
        #expect(client.receive().flatMap(DNSResponse.code(of:)) == .serverFailure)
    }

    @Test func answersSERVFAILWhenTheHostDoesNotAnswerInTime() throws {
        let harness = try Harness { $0.answerTimeout = .milliseconds(300) }
        try harness.attach()
        let client = Client(port: harness.port)
        client.send(Self.query("slow.example").encoded)
        #expect(harness.nextQuery() != nil)
        #expect(client.receive().flatMap(DNSResponse.code(of:)) == .serverFailure)
    }

    @Test func answersSERVFAILAndReturnsWhenTheChannelEnds() async throws {
        let harness = try Harness()
        try harness.attach()
        let client = Client(port: harness.port)
        client.send(Self.query("gone.example").encoded)
        #expect(harness.nextQuery() != nil)
        harness.closeChannel()
        #expect(client.receive().flatMap(DNSResponse.code(of:)) == .serverFailure)
        let deadline = ContinuousClock.now + Self.patience
        while !harness.hasAttachEnded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(harness.hasAttachEnded)
        // The next channel serves again.
        try harness.attach()
        let query = Self.query("again.example")
        client.send(query.encoded)
        let (tag, _) = try #require(harness.nextQuery())
        try harness.answer(tag, Self.answer(query))
        #expect(client.receive() == Self.answer(query))
    }

    @Test func truncatesAnAnswerLargerThanUDPCarriesAndAnswersItOverTCP() throws {
        let harness = try Harness()
        try harness.attach()
        let query = Self.query("big.example", type: DNSRecordType.txt, payload: nil)
        let text = [UInt8](repeating: UInt8(ascii: "x"), count: 255)
        let large = DNSResponse.encode(
            query, code: .noError,
            answers: (0..<4).map { _ in
                DNSRecord(
                    name: query.name, type: DNSRecordType.txt, timeToLive: 60, data: [255] + text)
            })
        #expect(large.count > 512)

        let client = Client(port: harness.port)
        client.send(query.encoded)
        let (tag, _) = try #require(harness.nextQuery())
        try harness.answer(tag, large)
        let truncated = try #require(client.receive())
        #expect(truncated == DNSResponse.truncated(query, code: .noError))

        var stream: Int32 = -1
        try #require(maw_tcp_connect_loopback(0, harness.port, 2_000, &stream) == 0)
        defer { close(stream) }
        let message = query.encoded
        try writeAll(
            [UInt8(message.count >> 8), UInt8(message.count & 0xFF)] + message, to: stream)
        let (streamTag, _) = try #require(harness.nextQuery())
        try harness.answer(streamTag, large)
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while received.count < 2 + large.count {
            let count = read(stream, &buffer, buffer.count)
            guard count > 0 else { break }
            received += buffer[..<count]
        }
        #expect(received == [UInt8(large.count >> 8), UInt8(large.count & 0xFF)] + large)
    }

    @Test func refusesQueriesBeyondTheLimitInFlight() throws {
        let harness = try Harness { $0.maximumInFlight = 2 }
        try harness.attach()
        let client = Client(port: harness.port)
        for id: UInt16 in 1...2 {
            client.send(Self.query("q\(id).example", id: id).encoded)
            #expect(harness.nextQuery() != nil)
        }
        client.send(Self.query("q3.example", id: 3).encoded)
        #expect(client.receive().flatMap(DNSResponse.code(of:)) == .refused)
    }

    @Test func asksTheHostOnceForAQueryThatIsSentAgain() throws {
        let harness = try Harness()
        try harness.attach()
        let client = Client(port: harness.port)
        let query = Self.query("twice.example")
        client.send(query.encoded)
        client.send(query.encoded)
        let (tag, _) = try #require(harness.nextQuery())
        #expect(harness.nextQuery(within: .milliseconds(300)) == nil)
        try harness.answer(tag, Self.answer(query))
        #expect(client.receive() == Self.answer(query))
        #expect(client.receive(within: .milliseconds(200)) == nil)
    }

    @Test func answersSERVFAILToAnAnswerForAnotherQuery() throws {
        let harness = try Harness()
        try harness.attach()
        let client = Client(port: harness.port)
        let query = Self.query("mismatch.example", id: 1)
        client.send(query.encoded)
        let (tag, _) = try #require(harness.nextQuery())
        try harness.answer(tag, Self.answer(Self.query("mismatch.example", id: 2)))
        #expect(client.receive().flatMap(DNSResponse.code(of:)) == .serverFailure)
    }
}
