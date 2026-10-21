import MawCore
import Testing

@testable import mawd

@Suite struct ConsoleEscapesTests {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    private func process(
        _ chunks: [UInt8]..., detachKey: DetachKey = .default
    ) -> [ConsoleEscapes.Action] {
        var escapes = ConsoleEscapes(detachKey: detachKey)
        return chunks.flatMap { escapes.process($0) }
    }

    // MARK: ~ escape sequences

    @Test func detachesOnTildeDotAtTheStartOfTheSession() {
        #expect(process(bytes("~.")) == [.detach])
    }

    @Test func detachesOnTildeDotAfterEnter() {
        #expect(process(bytes("ls\r~.")) == [.send(bytes("ls\r")), .detach])
        #expect(process(bytes("ls\n~.")) == [.send(bytes("ls\n")), .detach])
    }

    @Test func passesTildeDotInTheMiddleOfALine() {
        #expect(process(bytes("echo a~.b\r")) == [.send(bytes("echo a~.b\r"))])
    }

    @Test func recognizesASequenceSplitAcrossReads() {
        #expect(process(bytes("ls\r~"), bytes(".")) == [.send(bytes("ls\r")), .detach])
    }

    @Test func listsTheEscapesOnTildeQuestionMark() {
        #expect(process(bytes("~?~.")) == [.showHelp, .detach])
    }

    @Test func sendsASingleTildeForTildeTilde() {
        #expect(process(bytes("~~echo\r")) == [.send(bytes("~echo\r"))])
        // After "~~", the line has started, so a following "~." is literal.
        #expect(process(bytes("~~~.")) == [.send(bytes("~~."))])
    }

    @Test func sendsAHeldTildeWithTheNextByte() {
        #expect(process(bytes("~/bin\r")) == [.send(bytes("~/bin\r"))])
        #expect(process(bytes("~"), bytes("x")) == [.send(bytes("~x"))])
    }

    @Test func sendsAHeldTildeBeforeTheDetachKey() {
        #expect(process(bytes("~") + [0x1D]) == [.send(bytes("~")), .detach])
    }

    @Test func passesControlCToTheGuest() {
        #expect(process([0x03]) == [.send([0x03])])
    }

    // MARK: Detach key

    @Test func detachesOnCtrlRightBracketByDefault() {
        #expect(process(bytes("ab") + [0x1D] + bytes("cd")) == [.send(bytes("ab")), .detach])
    }

    @Test func detachesOnTheChosenKeyOnly() throws {
        let ctrlQ = try DetachKey(parsing: "^Q")
        #expect(process([0x1D, 0x11], detachKey: ctrlQ) == [.send([0x1D]), .detach])
    }

    @Test func detachesOnlyWithTildeDotWhenTheKeyIsNone() {
        #expect(
            process([0x1D] + bytes("\r~."), detachKey: .none) == [.send([0x1D, 0x0D]), .detach])
    }

    // MARK: Messages

    @Test func namesTheActiveKeys() throws {
        #expect(
            ConsoleEscapes(detachKey: .default).instructions
                == "To stop the virtual machine and detach, type ~. at the start of a line or "
                + "press Ctrl-]. Type ~? for help.")
        #expect(
            ConsoleEscapes(detachKey: try DetachKey(parsing: "ctrl-q")).instructions.contains(
                "press Ctrl-Q"))
        #expect(!ConsoleEscapes(detachKey: .none).instructions.contains("press"))
    }

    @Test func listsTheEscapesWithTheRequestedLineEnding() {
        let help = ConsoleEscapes(detachKey: .default).help(lineEnding: "\r\n")
        #expect(help.contains("  ~.  stop the virtual machine and detach\r\n"))
        #expect(help.contains("  ~~  send a single ~\r\n"))
        #expect(help.hasSuffix("Ctrl-] also stops the virtual machine and detaches.\r\n"))
    }
}

@Suite struct DetachKeyTests {
    @Test(arguments: [
        ("^]", UInt8(0x1D)), ("^q", 0x11), ("^Q", 0x11), ("ctrl-q", 0x11), ("CTRL-Q", 0x11),
        ("^\\", 0x1C), ("^@", 0x00), ("^_", 0x1F), ("^A", 0x01),
    ])
    func parsesControlKeys(_ text: String, _ byte: UInt8) throws {
        #expect(try DetachKey(parsing: text).byte == byte)
    }

    @Test func parsesNone() throws {
        #expect(try DetachKey(parsing: "none") == .none)
        #expect(try DetachKey(parsing: "NONE") == .none)
    }

    @Test(arguments: [
        ("q", "write it as ^X or ctrl-X, or none"),
        ("^", "it is not a control key"),
        ("^QQ", "it is not a control key"),
        ("^1", "it is not a control key"),
        ("^[", "it is Escape, which starts arrow-key sequences"),
        ("^M", "it is Enter"),
        ("^J", "it is Enter"),
    ])
    func rejectsKeysThatCannotDetach(_ text: String, _ reason: String) {
        #expect(throws: MawError.invalidDetachKey(text, reason: reason)) {
            try DetachKey(parsing: text)
        }
    }

    @Test func describesKeysTheWayUsersTypeThem() throws {
        #expect(DetachKey.default.description == "Ctrl-]")
        #expect(try DetachKey(parsing: "^q").description == "Ctrl-Q")
        #expect(DetachKey.none.description == "none")
    }
}
