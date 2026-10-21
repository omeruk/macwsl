import MawCore
import MawProtocol
import Testing

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Throws 10,000 random frames at the agent's session code. The agent must not crash, must
/// close each connection that receives bad input, and must keep serving new connections.
@Suite struct FuzzTests {
    /// Deterministic, so that a failure can be reproduced.
    struct Generator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Valid control messages, so that some connections get past the request and into a
    /// session. Only harmless commands run, and no signal stops a process.
    static let controlMessages: [ControlMessage] = [
        .info, .shutdown, .stdinEOF, .signal(.term), .signal(.hup), .signal(.int),
        .resize(TerminalSize(rows: 10, columns: 10)), .exec(ExecRequest(argv: ["true"])),
        .exec(ExecRequest(argv: ["cat"])),
        .exec(ExecRequest(argv: ["cat"], terminal: TerminalSize(rows: 5, columns: 5))),
        .started(pid: 1), .exited(.exited(code: 0)), .shutdownAcknowledged,
    ]

    static func randomFrame(using random: inout Generator) -> [UInt8] {
        switch Int.random(in: 0..<10, using: &random) {
        case 0:
            // Random bytes: anything at all, including impossible headers.
            return (0..<Int.random(in: 1...64, using: &random)).map { _ in
                UInt8.random(in: .min ... .max, using: &random)
            }
        case 1:
            // An oversized declaration.
            let size = UInt32.random(
                in: UInt32(AgentProtocol.maximumPayloadSize + 1)...UInt32.max, using: &random)
            return [
                UInt8(size >> 24), UInt8(truncatingIfNeeded: size >> 16),
                UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size), 0x02,
            ]
        case 2:
            // A header that promises more than follows.
            var bytes = Frame(type: .stdin, payload: Array(repeating: 1, count: 100)).encoded
            bytes.removeLast(Int.random(in: 1...100, using: &random))
            return bytes
        case 3:
            // A valid header with an unknown or random type.
            let payload = (0..<Int.random(in: 0...32, using: &random)).map { _ in
                UInt8.random(in: .min ... .max, using: &random)
            }
            var bytes = Frame(type: .stdin, payload: payload).encoded
            bytes[4] = UInt8.random(in: .min ... .max, using: &random)
            return bytes
        case 4:
            // Malformed JSON in a control frame.
            let text = [#"{"exec":{}}"#, "{", #"{"x":1}"#, "[]", #"{"signal":{"name":7}}"#]
                .randomElement(using: &random)!
            return Frame(type: .control, payload: Array(text.utf8)).encoded
        case 5:
            return Frame.version(UInt32.random(in: 0...3, using: &random)).encoded
        case 6, 7:
            return Frame.control(controlMessages.randomElement(using: &random)!).encoded
        default:
            let type = [FrameType.stdin, .stdout, .stderr].randomElement(using: &random)!
            return Frame(type: type, payload: Array("data\n".utf8)).encoded
        }
    }

    @Test func survivesTenThousandRandomFrames() async throws {
        let agent = TestAgent()
        var random = Generator(state: 0x4D57)
        var framesSent = 0
        var connections = 0

        while framesSent < 10_000 {
            let descriptor = try agent.connect()
            var bytes: [UInt8] = []
            if Bool.random(using: &random) {
                bytes += Frame.version().encoded
            }
            let count = Int.random(in: 1...20, using: &random)
            for _ in 0..<count {
                bytes += Self.randomFrame(using: &random)
            }
            framesSent += count
            connections += 1

            let closed = await runOnDedicatedThread { [bytes] () -> Bool in
                Self.sendThenWaitForClose(bytes, on: descriptor)
            }
            #expect(closed, "connection \(connections) was not closed by the agent")
        }

        // The agent still serves well-formed requests.
        let info = try await agent.client.info()
        #expect(info.protocolVersion == ProtocolVersion.current)
        let process = try await agent.client.exec(
            ExecRequest(argv: ["true"]), output: Output().handler)
        #expect(try await process.waitForExit() == .exited(code: 0))
    }

    /// Writes `bytes`, half-closes the connection, and reads until the agent closes it.
    /// Returns false if the agent has not closed it within 10 seconds.
    static func sendThenWaitForClose(_ bytes: [UInt8], on descriptor: OwnedDescriptor) -> Bool {
        defer { descriptor.close() }
        let fd = descriptor.rawValue
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes {
                write(fd, $0.baseAddress! + offset, $0.count - offset)
            }
            // The agent may close the connection before reading everything.
            guard written > 0 else { break }
            offset += written
        }
        shutdown(fd, Int32(SHUT_WR))

        let deadline = ContinuousClock.now + .seconds(10)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while ContinuousClock.now < deadline {
            var request = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
            guard poll(&request, 1, 100) >= 0 else { return false }
            if request[0].revents == 0 {
                continue
            }
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count <= 0 {
                return true
            }
        }
        return false
    }
}
