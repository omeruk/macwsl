import Testing

@testable import MawProtocol

@Suite struct MessageTests {
    static let everyMessage: [ControlMessage] = [
        .exec(ExecRequest(argv: ["ls", "/"])),
        .exec(
            ExecRequest(
                program: .loginShell, user: "ayse", locale: "tr_TR.UTF-8",
                environment: ["TERM": "xterm-256color"], workingDirectory: "/tmp",
                terminal: TerminalSize(rows: 24, columns: 80))),
        .exec(ExecRequest(program: .shellCommand("uname -a | wc -c"), user: "root")),
        .info,
        .shutdown,
        .dialBack(DialBackNonce(bytes: Array(repeating: 0xA5, count: 32))!),
        .stdinEOF,
        .signal(.int),
        .resize(TerminalSize(rows: 50, columns: 132)),
        .started(pid: 42),
        .exited(.exited(code: 3)),
        .exited(.signaled(signal: 9)),
        .agentInfo(
            AgentInfo(
                agentVersion: "0.1.0", protocolVersion: 1, kernelRelease: "6.18.2-maw",
                uptimeMilliseconds: 1_234)),
        .shutdownAcknowledged,
        .dialedBack,
        .error(AgentError(.dialBackFailed, "no source port below 1024 is free")),
        .error(AgentError(.versionMismatch, "mismatch", hostVersion: 1, guestVersion: 2)),
        .error(AgentError(.commandNotFound, "nope: not found")),
        .error(AgentError(.userNotFound, "there is no user named 'bob'", user: "bob")),
    ]

    @Test(arguments: everyMessage)
    func roundTrips(_ message: ControlMessage) throws {
        #expect(try ControlMessage(json: message.encodedJSON()) == message)
        #expect(try Frame.control(message).controlMessage() == message)
    }

    @Test func coversEveryMessageName() {
        let names = Set(Self.everyMessage.map(\.name))
        #expect(
            names == [
                "exec", "info", "shutdown", "stdinEOF", "signal", "resize", "started", "exited",
                "agentInfo", "shutdownAcknowledged", "error", "dialBack", "dialedBack",
            ])
    }

    @Test func roundTripsEverySignal() throws {
        for signal in Signal.allCases {
            #expect(
                try ControlMessage(json: ControlMessage.signal(signal).encodedJSON())
                    == .signal(signal))
            #expect(Signal(linuxNumber: signal.linuxNumber) == signal)
            #expect(Signal(localNumber: signal.localNumber) == signal)
        }
    }

    @Test func usesTheDocumentedJSONShapes() {
        func json(_ message: ControlMessage) -> String {
            String(decoding: message.encodedJSON(), as: UTF8.self)
        }
        #expect(json(.info) == #"{"info":{}}"#)
        #expect(json(.signal(.int)) == #"{"signal":{"name":"INT"}}"#)
        #expect(
            json(.resize(TerminalSize(rows: 24, columns: 80)))
                == #"{"resize":{"columns":80,"rows":24}}"#)
        #expect(json(.started(pid: 7)) == #"{"started":{"pid":7}}"#)
        let nonce = DialBackNonce(bytes: Array(0..<32))!
        #expect(
            json(.dialBack(nonce))
                == #"{"dialBack":{"nonce":"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"}}"#
        )
        #expect(json(.dialedBack) == #"{"dialedBack":{}}"#)
        #expect(json(.exited(.exited(code: 3))) == #"{"exited":{"code":3}}"#)
        #expect(json(.exited(.signaled(signal: 2))) == #"{"exited":{"signal":2}}"#)
        #expect(
            json(.exec(ExecRequest(argv: ["true"])))
                == #"{"exec":{"environment":{},"program":{"argv":["true"]}}}"#)
        #expect(
            json(.exec(ExecRequest(program: .loginShell, user: "ayse", locale: "tr_TR.UTF-8")))
                == #"{"exec":{"environment":{},"locale":"tr_TR.UTF-8","program":{"loginShell":{}},"user":"ayse"}}"#
        )
        #expect(
            json(.exec(ExecRequest(program: .shellCommand("ls -l"))))
                == #"{"exec":{"environment":{},"program":{"shellCommand":"ls -l"}}}"#)
    }

    @Test func fillsInExecDefaults() throws {
        let message = try ControlMessage(
            json: Array(#"{"exec":{"program":{"argv":["true"]}}}"#.utf8))
        #expect(message == .exec(ExecRequest(argv: ["true"])))
        guard case .exec(let request) = message else { return }
        #expect(request.user == nil && request.locale == nil && request.workingDirectory == nil)
    }

    @Test func speaksVersion3() {
        #expect(ProtocolVersion.current == 3)
    }

    @Test(arguments: [
        "",
        "null",
        "[]",
        "{}",
        #"{"info":{},"shutdown":{}}"#,
        #"{"launch":{}}"#,
        #"{"exec":{}}"#,
        #"{"exec":{"argv":["ls"]}}"#,
        #"{"exec":{"program":{}}}"#,
        #"{"exec":{"program":{"argv":"ls"}}}"#,
        #"{"exec":{"program":{"argv":["ls"],"loginShell":{}}}}"#,
        #"{"exec":{"program":{"run":["ls"]}}}"#,
        #"{"signal":{"name":"NOPE"}}"#,
        #"{"exited":{}}"#,
        #"{"exited":{"code":1,"signal":2}}"#,
        #"{"resize":{"rows":-1,"columns":80}}"#,
        #"{"started":{"pid":"x"}}"#,
        #"{"dialBack":{}}"#,
        #"{"dialBack":{"nonce":""}}"#,
        #"{"dialBack":{"nonce":"00"}}"#,
        // 31 bytes, 33 bytes, uppercase, and a character that is not a digit.
        #"{"dialBack":{"nonce":"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e"}}"#,
        #"{"dialBack":{"nonce":"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"}}"#,
        #"{"dialBack":{"nonce":"000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F"}}"#,
        #"{"dialBack":{"nonce":"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1g"}}"#,
        #"{"dialBack":{"nonce":5}}"#,
        "{\"info\":",
    ])
    func rejectsMalformedJSON(_ text: String) {
        #expect {
            try ControlMessage(json: Array(text.utf8))
        } throws: { error in
            guard case .malformedControl = error as? FrameError else { return false }
            return true
        }
    }

    @Test func computesShellExitStatuses() {
        #expect(ExitStatus.exited(code: 0).shellStatus == 0)
        #expect(ExitStatus.exited(code: 3).shellStatus == 3)
        #expect(ExitStatus.signaled(signal: Signal.int.linuxNumber).shellStatus == 130)
        #expect(ExitStatus.signaled(signal: Signal.kill.linuxNumber).shellStatus == 137)
        #expect(ExitStatus.signaled(signal: 2).description == "ended by SIGINT")
    }

    // MARK: Dial-back nonces

    @Test func readsAndWritesNoncesInHexadecimal() throws {
        let nonce = DialBackNonce.random()
        #expect(DialBackNonce(hexadecimal: nonce.hexadecimal) == nonce)
        #expect(nonce.hexadecimal.count == 64)
        #expect(DialBackNonce(bytes: Array(repeating: 0, count: 31)) == nil)
        #expect(DialBackNonce(bytes: Array(repeating: 0, count: 33)) == nil)
    }

    @Test func drawsADifferentNonceEachTime() {
        let nonces = Set((0..<1_000).map { _ in DialBackNonce.random() })
        #expect(nonces.count == 1_000)
    }

    /// The comparison looks at every byte: a difference in the first or the last byte alone
    /// is found.
    @Test func comparesEveryByte() throws {
        let bytes = (0..<32).map { UInt8($0 * 7) }
        let nonce = try #require(DialBackNonce(bytes: bytes))
        #expect(nonce == DialBackNonce(bytes: bytes))
        for index in [0, 15, 31] {
            var other = bytes
            other[index] ^= 0x01
            #expect(nonce != DialBackNonce(bytes: other))
        }
    }

    /// The comparison reads every byte of both nonces even when the first bytes differ, so that
    /// its duration does not depend on where the first difference is.
    @Test(arguments: [0, 1, 31])
    func readsEveryByteWhateverTheFirstDifference(differingAt index: Int) {
        let bytes = (0..<32).map { UInt8($0) }
        var other = bytes
        other[index] ^= 0xFF
        let left = CountingBytes(bytes)
        let right = CountingBytes(other)
        #expect(!DialBackNonce.constantTimeEqual(left, right))
        #expect(left.reads.value == 32)
        #expect(right.reads.value == 32)
    }

    @Test func findsByteSequencesOfDifferentLengthsUnequal() {
        #expect(!DialBackNonce.constantTimeEqual([1, 2, 3], [1, 2]))
        #expect(DialBackNonce.constantTimeEqual([1, 2, 3], [1, 2, 3]))
    }

    @Test func neverPrintsANonce() {
        let nonce = DialBackNonce.random()
        #expect("\(nonce)" == "<nonce>")
        #expect(!"\(ControlMessage.dialBack(nonce))".contains(nonce.hexadecimal))
    }
}

/// Bytes that count how often they are read.
private struct CountingBytes: RandomAccessCollection {
    final class Counter: @unchecked Sendable {
        var value = 0
    }

    let bytes: [UInt8]
    let reads = Counter()

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var startIndex: Int { bytes.startIndex }
    var endIndex: Int { bytes.endIndex }

    subscript(position: Int) -> UInt8 {
        reads.value += 1
        return bytes[position]
    }
}
