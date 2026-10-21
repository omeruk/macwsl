import Testing

@testable import MawProtocol

@Suite struct MessageTests {
    static let everyMessage: [ControlMessage] = [
        .exec(ExecRequest(argv: ["ls", "/"])),
        .exec(
            ExecRequest(
                argv: ["/bin/sh", "-l"],
                environment: ["TERM": "xterm-256color", "LANG": "C.UTF-8"],
                workingDirectory: "/tmp", terminal: TerminalSize(rows: 24, columns: 80))),
        .info,
        .shutdown,
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
        .error(AgentError(.versionMismatch, "mismatch", hostVersion: 1, guestVersion: 2)),
        .error(AgentError(.commandNotFound, "nope: not found")),
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
                "agentInfo", "shutdownAcknowledged", "error",
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
        #expect(json(.exited(.exited(code: 3))) == #"{"exited":{"code":3}}"#)
        #expect(json(.exited(.signaled(signal: 2))) == #"{"exited":{"signal":2}}"#)
        #expect(
            json(.exec(ExecRequest(argv: ["true"])))
                == #"{"exec":{"argv":["true"],"environment":{},"workingDirectory":"/"}}"#)
    }

    @Test func fillsInExecDefaults() throws {
        let message = try ControlMessage(json: Array(#"{"exec":{"argv":["true"]}}"#.utf8))
        #expect(message == .exec(ExecRequest(argv: ["true"])))
    }

    @Test(arguments: [
        "",
        "null",
        "[]",
        "{}",
        #"{"info":{},"shutdown":{}}"#,
        #"{"launch":{}}"#,
        #"{"exec":{}}"#,
        #"{"exec":{"argv":"ls"}}"#,
        #"{"signal":{"name":"NOPE"}}"#,
        #"{"exited":{}}"#,
        #"{"exited":{"code":1,"signal":2}}"#,
        #"{"resize":{"rows":-1,"columns":80}}"#,
        #"{"started":{"pid":"x"}}"#,
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
}
