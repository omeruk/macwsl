import Testing

@testable import MawProtocol

@Suite struct FrameTests {
    static let samples: [Frame] = [
        .version(),
        .version(0xDEAD_BEEF),
        .control(.info),
        .control(.exec(ExecRequest(argv: ["uname", "-a"], environment: ["TERM": "xterm"]))),
        Frame(type: .stdin, payload: []),
        Frame(type: .stdout, payload: Array("hello\n".utf8)),
        Frame(type: .stderr, payload: (0..<300).map { UInt8($0 % 256) }),
    ]

    @Test func encodesTheHeaderAsLengthThenType() {
        let frame = Frame(type: .stdout, payload: [0x41, 0x42, 0x43])
        #expect(frame.encoded == [0, 0, 0, 3, 0x11, 0x41, 0x42, 0x43])
        #expect(Frame.version(1).encoded == [0, 0, 0, 4, 0x01, 0, 0, 0, 1])
    }

    @Test func roundTripsEveryFrameType() throws {
        var decoder = FrameDecoder()
        decoder.append(Self.samples.flatMap(\.encoded))
        var decoded: [Frame] = []
        while let frame = try decoder.nextFrame() {
            decoded.append(frame)
        }
        #expect(decoded == Self.samples)
        #expect(decoder.bufferedByteCount == 0)
        try decoder.finish()
    }

    @Test func reassemblesFramesSplitAtEveryByte() throws {
        let bytes = Self.samples.flatMap(\.encoded)
        for split in 0...bytes.count {
            var decoder = FrameDecoder()
            var decoded: [Frame] = []
            decoder.append(bytes[..<split])
            while let frame = try decoder.nextFrame() {
                decoded.append(frame)
            }
            decoder.append(bytes[split...])
            while let frame = try decoder.nextFrame() {
                decoded.append(frame)
            }
            #expect(decoded == Self.samples, "split at byte \(split)")
        }
    }

    @Test func reassemblesFramesDeliveredOneByteAtATime() throws {
        var decoder = FrameDecoder()
        var decoded: [Frame] = []
        for byte in Self.samples.flatMap(\.encoded) {
            decoder.append([byte])
            while let frame = try decoder.nextFrame() {
                decoded.append(frame)
            }
        }
        #expect(decoded == Self.samples)
    }

    @Test func rejectsAnOversizedFrameFromItsHeaderAlone() {
        let size = UInt32(AgentProtocol.maximumPayloadSize + 1)
        var decoder = FrameDecoder()
        decoder.append([
            UInt8(size >> 24), UInt8(truncatingIfNeeded: size >> 16),
            UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size), 0x11,
        ])
        #expect(throws: FrameError.oversized(size)) { try decoder.nextFrame() }
    }

    @Test func acceptsAFrameOfExactlyTheMaximumSize() throws {
        var decoder = FrameDecoder()
        let frame = Frame(
            type: .stdout, payload: [UInt8](repeating: 7, count: AgentProtocol.maximumPayloadSize))
        decoder.append(frame.encoded)
        #expect(try decoder.nextFrame() == frame)
    }

    @Test func rejectsUnknownTypes() {
        let known = Set(FrameType.allCases.map(\.rawValue))
        for type in UInt8.min...UInt8.max where !known.contains(type) {
            var decoder = FrameDecoder()
            decoder.append([0, 0, 0, 0, type])
            #expect(throws: FrameError.unknownType(type)) { try decoder.nextFrame() }
        }
    }

    @Test func reportsATruncatedFrameAtEndOfFile() throws {
        let bytes = Frame(type: .stdout, payload: Array("hello".utf8)).encoded
        for cut in 1..<bytes.count {
            var decoder = FrameDecoder()
            decoder.append(bytes[..<cut])
            #expect(try decoder.nextFrame() == nil)
            #expect(throws: FrameError.truncated(buffered: cut)) { try decoder.finish() }
        }
    }

    @Test func readsVersionFrames() throws {
        #expect(try Frame.version(7).protocolVersion() == 7)
        #expect(throws: FrameError.malformedVersion(size: 3)) {
            try Frame(type: .version, payload: [0, 0, 1]).protocolVersion()
        }
        #expect(throws: FrameError.unexpectedType(0x02, expected: "version")) {
            try Frame.control(.info).protocolVersion()
        }
    }

    @Test func compactsItsBufferOverManyFrames() throws {
        var decoder = FrameDecoder()
        let frame = Frame(type: .stdout, payload: [UInt8](repeating: 1, count: 1_000))
        for _ in 0..<1_000 {
            decoder.append(frame.encoded)
            #expect(try decoder.nextFrame() == frame)
        }
        #expect(decoder.bufferedByteCount == 0)
    }
}
