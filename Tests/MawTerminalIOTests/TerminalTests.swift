import Darwin
import Foundation
import MawCore
import MawProtocol
import MawTerminalIO
import Testing

@Suite struct TerminalTests {
    @Test func requiresATerminalOnStandardInput() throws {
        let pipe = Pipe()
        #expect(throws: MawError.notATerminal(option: "--shell", stream: "standard input")) {
            try Terminal.requireTerminals(
                for: "--shell", input: pipe.fileHandleForReading.fileDescriptor,
                output: pipe.fileHandleForWriting.fileDescriptor)
        }
    }

    @Test func requiresATerminalOnStandardOutput() throws {
        var primary: Int32 = -1
        var secondary: Int32 = -1
        try #require(openpty(&primary, &secondary, nil, nil, nil) == 0)
        defer {
            close(primary)
            close(secondary)
        }
        let pipe = Pipe()
        #expect(
            throws: MawError.notATerminal(option: "--interactive", stream: "standard output")
        ) {
            try Terminal.requireTerminals(
                for: "--interactive", input: secondary,
                output: pipe.fileHandleForWriting.fileDescriptor)
        }
        #expect(throws: Never.self) {
            try Terminal.requireTerminals(for: "--shell", input: secondary, output: secondary)
        }
    }

    @Test func readsTheWindowSize() throws {
        var primary: Int32 = -1
        var secondary: Int32 = -1
        var size = winsize(ws_row: 33, ws_col: 101, ws_xpixel: 0, ws_ypixel: 0)
        try #require(openpty(&primary, &secondary, nil, nil, &size) == 0)
        defer {
            close(primary)
            close(secondary)
        }
        #expect(Terminal.windowSize(of: secondary) == TerminalSize(rows: 33, columns: 101))
        let pipe = Pipe()
        #expect(Terminal.windowSize(of: pipe.fileHandleForWriting.fileDescriptor) == nil)
    }
}
