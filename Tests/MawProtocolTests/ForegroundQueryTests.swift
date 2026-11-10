import MawCore
import Testing

@testable import MawProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// `GuestProcess.foregroundProgram(within:)` and `hangUp()` against a scripted agent.
@Suite struct ForegroundQueryTests {
    /// What the scripted agent saw.
    final class Observed: @unchecked Sendable {
        private let lock = ConditionLock()
        private var queries: [UInt32] = []
        private var closed = false

        func query(_ id: UInt32) -> Int {
            lock.withLock {
                queries.append(id)
                return queries.count
            }
        }

        func close() {
            lock.withLock { closed = true }
        }

        var queryIDs: [UInt32] { lock.withLock { queries } }
        var sawTheClose: Bool { lock.withLock { closed } }
    }

    /// Plays the agent: answers `exec` with `started`, then answers the `n`th query (from 1)
    /// with the messages that `reply` returns for it, until the host closes the connection.
    static func agent(
        observed: Observed, reply: @escaping @Sendable (_ id: UInt32, _ n: Int) -> [ControlMessage]
    ) throws -> GuestAgentClient {
        let (host, peer) = try HandshakeTests.socketPair()
        startDetachedThread {
            defer { peer.close() }
            guard let connection = try? FrameConnection(peer) else { return }
            _ = try? connection.exchangeVersions(until: .now + .seconds(5))
            _ = try? connection.receiveControl(until: .now + .seconds(5), expecting: "exec")
            connection.enqueue(.control(.started(pid: 7)))
            try? connection.flush(until: .now + .seconds(5))
            while true {
                guard let frame = try? connection.receiveFrame(until: .now + .seconds(30)) else {
                    observed.close()
                    return
                }
                guard case .foregroundQuery(let id) = try? frame.controlMessage() else { continue }
                for message in reply(id, observed.query(id)) {
                    connection.enqueue(.control(message))
                }
                try? connection.flush(until: .now + .seconds(5))
            }
        }
        return GuestAgentClient { () throws(MawError) in host }
    }

    @Test func returnsTheAgentsAnswer() async throws {
        let observed = Observed()
        let client = try Self.agent(observed: observed) { id, n in
            n == 1
                ? [.foregroundProgram(id: id, program: nil)]
                : [
                    .foregroundProgram(
                        id: id, program: ForegroundProcess(processGroup: 812, name: "sleep"))
                ]
        }
        let process = try await client.exec(ExecRequest(program: .loginShell)) { _, _ in }
        #expect(await process.foregroundProgram(within: .seconds(10)) == .none)
        #expect(
            await process.foregroundProgram(within: .seconds(10))
                == .program(processGroup: 812, name: "sleep"))
        #expect(observed.queryIDs == [1, 2])
        process.hangUp()
    }

    @Test func reportsALeaderThatHasExitedWithoutAName() async throws {
        let client = try Self.agent(observed: Observed()) { id, _ in
            [.foregroundProgram(id: id, program: ForegroundProcess(processGroup: 812, name: nil))]
        }
        let process = try await client.exec(ExecRequest(program: .loginShell)) { _, _ in }
        #expect(
            await process.foregroundProgram(within: .seconds(10))
                == .program(processGroup: 812, name: nil))
        process.hangUp()
    }

    /// The guest chooses the name: control and format characters, which could move the cursor
    /// or reorder text in a dialog, are replaced, and at most 64 bytes are kept.
    @Test func sanitizesTheNameFromTheGuest() async throws {
        let hostile = "\u{1B}[2Jrm\u{7F}\n\u{202E}gpj" + String(repeating: "ş", count: 40)
        let client = try Self.agent(observed: Observed()) { id, _ in
            [.foregroundProgram(id: id, program: ForegroundProcess(processGroup: 9, name: hostile))]
        }
        let process = try await client.exec(ExecRequest(program: .loginShell)) { _, _ in }
        let answer = await process.foregroundProgram(within: .seconds(10))
        guard case .program(9, let name?) = answer else {
            Issue.record("expected a program with a name, received \(answer)")
            return
        }
        // 4 replacements of 3 bytes and 8 ASCII bytes make 20 bytes, and 22 of the 2-byte "ş"
        // fill the remaining 44.
        #expect(
            name == "\u{FFFD}[2Jrm\u{FFFD}\u{FFFD}\u{FFFD}gpj" + String(repeating: "ş", count: 22))
        #expect(name.utf8.count <= ForegroundAnswer.nameLimit)
        #expect(!name.unicodeScalars.contains { $0.properties.generalCategory == .control })
        process.hangUp()
    }

    @Test func keepsNamesAsTheyAreWhenTheyAreSafe() {
        #expect(ForegroundAnswer.displayableName("sleep") == "sleep")
        #expect(ForegroundAnswer.displayableName("çay ocağı") == "çay ocağı")
        #expect(ForegroundAnswer.displayableName("") == "")
        #expect(ForegroundAnswer.displayableName("a\u{2028}b\u{0085}c") == "a\u{FFFD}b\u{FFFD}c")
    }

    /// A query that the agent does not answer in time gets `noAnswer`, and its late reply does
    /// not answer the next query.
    @Test func neverLetsALateReplyAnswerALaterQuery() async throws {
        let observed = Observed()
        let client = try Self.agent(observed: observed) { id, n in
            // The first query stays unanswered until the second arrives; then the first gets a
            // program and the second none.
            n == 1
                ? []
                : [
                    .foregroundProgram(
                        id: id - 1, program: ForegroundProcess(processGroup: 812, name: "sleep")),
                    .foregroundProgram(id: id, program: nil),
                ]
        }
        let process = try await client.exec(ExecRequest(program: .loginShell)) { _, _ in }
        #expect(await process.foregroundProgram(within: .milliseconds(200)) == .noAnswer)
        #expect(await process.foregroundProgram(within: .seconds(10)) == .none)
        #expect(observed.queryIDs == [1, 2])
        process.hangUp()
    }

    @Test func answersNoAnswerWhenTheTaskIsCancelled() async throws {
        let client = try Self.agent(observed: Observed()) { _, _ in [] }
        let process = try await client.exec(ExecRequest(program: .loginShell)) { _, _ in }
        let asking = Task { await process.foregroundProgram(within: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(50))
        asking.cancel()
        #expect(await asking.value == .noAnswer)
        process.hangUp()
    }

    /// Callers that ask while the agent has not answered get the answer when it comes, and
    /// the end of the session answers callers that still wait.
    @Test func answersNoneOnceTheSessionHasEnded() async throws {
        let client = try GuestProcessTests.scriptedAgent(sending: [
            .control(.started(pid: 7)), .control(.exited(.exited(code: 0))),
        ])
        let process = try await client.exec(ExecRequest(program: .loginShell)) { _, _ in }
        #expect(try await process.waitForExit() == .exited(code: 0))
        #expect(await process.foregroundProgram(within: .seconds(10)) == .none)
    }

    @Test func answersCallersThatWaitWhenTheConnectionEnds() async throws {
        let observed = Observed()
        let client = try Self.agent(observed: observed) { _, _ in [] }
        let process = try await client.exec(ExecRequest(program: .loginShell)) { _, _ in }
        let asking = Task { await process.foregroundProgram(within: .seconds(60)) }
        while observed.queryIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        process.hangUp()
        #expect(await asking.value == .none)
    }

    /// A reply to a query that the host never sent is a protocol violation.
    @Test func closesTheConnectionOnAReplyToAQueryThatWasNotSent() async throws {
        let client = try GuestProcessTests.scriptedAgent(sending: [
            .control(.started(pid: 7)), .control(.foregroundProgram(id: 5, program: nil)),
        ])
        let process = try await client.exec(ExecRequest(program: .loginShell)) { _, _ in }
        await #expect(
            throws: MawError.guestAgentFailed(
                reason: "exec: foregroundProgram answers query 5, which was not sent")
        ) {
            try await process.waitForExit()
        }
    }

    // MARK: Hanging up

    /// The host closes the connection without waiting for the exit; the agent sees the close
    /// and, as on any host disconnect, hangs up on the process.
    @Test func closesTheConnectionOnHangUp() async throws {
        let observed = Observed()
        let client = try Self.agent(observed: observed) { _, _ in [] }
        let process = try await client.exec(ExecRequest(program: .loginShell)) { _, _ in }
        process.hangUp()
        await #expect(throws: MawError.guestAgentFailed(reason: "exec: the host hung up")) {
            try await process.waitForExit()
        }
        #expect(!process.connectionEndedBeforeExit)
        #expect(!process.write(Array("ignored\n".utf8)))
        #expect(await process.foregroundProgram(within: .seconds(10)) == .none)
        let deadline = ContinuousClock.now + .seconds(10)
        while !observed.sawTheClose && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed.sawTheClose)
    }

    @Test func doesNothingWhenHangingUpAfterTheExit() async throws {
        let client = try GuestProcessTests.scriptedAgent(sending: [
            .control(.started(pid: 7)), .control(.exited(.exited(code: 3))),
        ])
        let process = try await client.exec(ExecRequest(program: .loginShell)) { _, _ in }
        #expect(try await process.waitForExit() == .exited(code: 3))
        process.hangUp()
        #expect(try await process.waitForExit() == .exited(code: 3))
    }
}
