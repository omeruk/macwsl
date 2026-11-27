import CMawSystem
import Darwin
import MawCore
import MawProtocol
import Testing
import os

@testable import MawDaemonKit

/// The daemon's side of the DNS channel, with the test as the guest agent at the other end of
/// a socket pair and a resolver that answers from a table.
@Suite(.serialized, .timeLimit(.minutes(2))) struct DNSRelayTests {
    static let patience = Duration.seconds(10)

    /// The agent's side: it accepts the channel and lets the test send queries on it.
    final class FakeAgent: @unchecked Sendable {
        let lock = ConditionLock()
        var channel: FrameConnection?
        var channelsOpened = 0

        var openChannel: @Sendable () async throws(MawError) -> OwnedDescriptor {
            { () throws(MawError) -> OwnedDescriptor in
                var fds: [Int32] = [-1, -1]
                guard maw_socketpair(&fds) == 0 else {
                    throw .guestAgentUnavailable(reason: "socketpair")
                }
                let agentSide = OwnedDescriptor(fds[1])
                _ = startDetachedThread { self.accept(agentSide) }
                return OwnedDescriptor(fds[0])
            }
        }

        private func accept(_ descriptor: OwnedDescriptor) {
            guard let connection = try? FrameConnection(descriptor),
                (try? connection.exchangeVersions(until: .now + DNSRelayTests.patience)) != nil,
                (try? connection.receiveControl(until: .now + DNSRelayTests.patience, expecting: ""))
                    == .dns
            else { return }
            lock.withLock {
                channel = connection
                channelsOpened += 1
            }
        }

        func waitForChannel() async -> Bool {
            await DNSRelayTests.eventually { self.lock.withLock { self.channel != nil } }
        }

        func send(_ frame: Frame) {
            lock.withLock {
                channel?.enqueue(frame)
                try? channel?.flush(until: .now + DNSRelayTests.patience)
            }
        }

        func query(_ query: DNSQuery, tag: UInt32) {
            send(.dns(.dnsQuery, tag: tag, message: query.encoded))
        }

        /// The next answer on the channel.
        func answer() -> (tag: UInt32, response: [UInt8])? {
            guard let channel = lock.withLock({ channel }),
                let frame = try? channel.receiveFrame(until: .now + DNSRelayTests.patience),
                frame.type == .dnsAnswer, let (tag, message) = try? frame.dnsMessage()
            else { return nil }
            return (tag, message)
        }

        func close() {
            lock.withLock {
                channel?.descriptor.close()
                channel = nil
            }
        }
    }

    static func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + patience
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    final class Lines: @unchecked Sendable {
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        var all: [String] { lines.withLock { $0 } }
    }

    static func relay(
        _ agent: FakeAgent, resolver: FakeResolver, lines: Lines = Lines(),
        _ configure: (inout DNSRelay.Environment) -> Void = { _ in }
    ) throws -> DNSRelay {
        var environment = DNSRelay.Environment(
            openChannel: agent.openChannel, resolver: resolver, reopenDelay: .milliseconds(20))
        configure(&environment)
        return DNSRelay(
            machine: .distribution(try DistroName("Test")), environment: environment,
            log: DaemonLog(), console: { line in lines.lines.withLock { $0.append(line) } })
    }

    static func query(_ name: String, _ type: UInt16 = DNSRecordType.a, id: UInt16 = 9) -> DNSQuery
    {
        DNSQuery(id: id, name: DNSName(presentation: name)!, type: type, ednsPayloadSize: 1_232)
    }

    @Test func answersAQueryWithTheMacsRecords() async throws {
        let agent = FakeAgent()
        let resolver = FakeResolver()
        let record = DNSRecord(
            name: DNSName(presentation: "github.com")!, type: DNSRecordType.a, timeToLive: 60,
            data: [140, 82, 121, 3])
        resolver.set("github.com", DNSRecordType.a, DNSLookup(.found, records: [record]))
        let relay = try Self.relay(agent, resolver: resolver)
        await relay.start()
        #expect(await agent.waitForChannel())
        let query = Self.query("github.com")
        agent.query(query, tag: 41)
        let (tag, response) = try #require(agent.answer())
        #expect(tag == 41)
        #expect(response == DNSResponse.encode(query, code: .noError, answers: [record]))
        await relay.stop()
    }

    @Test func answersAMalformedQueryFORMERR() async throws {
        let agent = FakeAgent()
        let relay = try Self.relay(agent, resolver: FakeResolver())
        await relay.start()
        #expect(await agent.waitForChannel())
        var two = Self.query("x.example").encoded
        two[5] = 2
        agent.send(.dns(.dnsQuery, tag: 3, message: two))
        let (tag, response) = try #require(agent.answer())
        #expect(tag == 3)
        #expect(DNSResponse.code(of: response) == .formatError)
        await relay.stop()
    }

    @Test func refusesQueriesBeyondTheRate() async throws {
        let agent = FakeAgent()
        let resolver = FakeResolver()
        resolver.set("x.example", DNSRecordType.a, DNSLookup(.noSuchName))
        let relay = try Self.relay(agent, resolver: resolver) {
            $0.rate = 1
            $0.burst = 2
        }
        await relay.start()
        #expect(await agent.waitForChannel())
        var codes: [DNSResponseCode?] = []
        for tag: UInt32 in 1...3 {
            agent.query(Self.query("x.example"), tag: tag)
            codes.append(agent.answer().flatMap { DNSResponse.code(of: $0.response) })
        }
        #expect(codes == [.nameError, .nameError, .refused])
        await relay.stop()
    }

    @Test func refusesQueriesBeyondTheLimitInFlightAndAnswersSERVFAILAfterTheDeadline()
        async throws
    {
        let agent = FakeAgent()
        let relay = try Self.relay(agent, resolver: FakeResolver(hangs: true)) {
            $0.maximumInFlight = 1
            $0.answerTimeout = .milliseconds(300)
        }
        await relay.start()
        #expect(await agent.waitForChannel())
        agent.query(Self.query("slow.example"), tag: 1)
        #expect(await Self.eventually { await relay.queriesInFlight == 1 })
        agent.query(Self.query("other.example"), tag: 2)
        let first = try #require(agent.answer())
        #expect(first.tag == 2)
        #expect(DNSResponse.code(of: first.response) == .refused)
        let second = try #require(agent.answer())
        #expect(second.tag == 1)
        #expect(DNSResponse.code(of: second.response) == .serverFailure)
        #expect(await Self.eventually { await relay.queriesInFlight == 0 })
        await relay.stop()
    }

    @Test func opensTheChannelAgainAfterItEnds() async throws {
        let agent = FakeAgent()
        let relay = try Self.relay(agent, resolver: FakeResolver())
        await relay.start()
        #expect(await agent.waitForChannel())
        agent.close()
        #expect(await Self.eventually { agent.lock.withLock { agent.channelsOpened == 2 } })
        await relay.stop()
    }

    @Test func closesTheChannelOnAFrameThatIsNotAQuery() async throws {
        let agent = FakeAgent()
        let relay = try Self.relay(agent, resolver: FakeResolver())
        await relay.start()
        #expect(await agent.waitForChannel())
        agent.send(.control(.info))
        #expect(await Self.eventually { agent.lock.withLock { agent.channelsOpened == 2 } })
        await relay.stop()
    }

    @Test func countsTheAnswersWithoutNames() async throws {
        let agent = FakeAgent()
        let resolver = FakeResolver()
        resolver.set(
            "a.example", DNSRecordType.a,
            DNSLookup(
                .found,
                records: [
                    DNSRecord(
                        name: DNSName(presentation: "a.example")!, type: DNSRecordType.a,
                        timeToLive: 1, data: [1, 2, 3, 4])
                ]))
        resolver.set("gone.example", DNSRecordType.a, DNSLookup(.noSuchName))
        let lines = Lines()
        let relay = try Self.relay(agent, resolver: resolver, lines: lines)
        await relay.start()
        #expect(await agent.waitForChannel())
        agent.query(Self.query("a.example"), tag: 1)
        _ = agent.answer()
        agent.query(Self.query("gone.example"), tag: 2)
        _ = agent.answer()
        agent.query(Self.query("a.example", 257), tag: 3)
        _ = agent.answer()
        await relay.stop()
        let line = try #require(lines.all.last)
        #expect(line.hasPrefix("dns: answered 3 queries in the last "))
        #expect(
            line.hasSuffix(
                "before the machine stopped: 1 with records, 0 NODATA, 1 NXDOMAIN, 0 SERVFAIL, "
                    + "1 refused, not supported, or malformed"))
        #expect(!line.contains("example"))
    }

    @Test func writesTheCountLineEveryInterval() {
        var counts = DNSRelay.Counts()
        #expect(counts.total == 0)
        counts.count(DNSResponse.encode(Self.query("x.example"), code: .noError))
        counts.count(DNSResponse.encode(Self.query("x.example"), code: .serverFailure))
        #expect(
            counts.line(seconds: 60, stopping: false)
                == "dns: answered 2 queries in 60 s: 0 with records, 1 NODATA, 0 NXDOMAIN, "
                + "1 SERVFAIL, 0 refused, not supported, or malformed")
    }
}
