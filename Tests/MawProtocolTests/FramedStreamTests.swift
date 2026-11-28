import Testing

@testable import MawProtocol

@Suite struct FramedStreamTests {
    /// Decodes `bytes`, given in pieces of `pieceSize`, into its payload and whether it ended.
    static func decode(_ bytes: [UInt8], pieceSize: Int) throws -> (
        [UInt8], Bool
    ) {
        var decoder = FramedStreamDecoder()
        var payload: [UInt8] = []
        var ended = false
        var start = 0
        while start < bytes.count {
            let piece = Array(bytes[start..<min(start + pieceSize, bytes.count)])
            start += piece.count
            var offset = 0
            try piece.withUnsafeBytes { raw in
                while let event = try decoder.next(raw, from: &offset) {
                    switch event {
                    case .data(let range): payload += raw[range]
                    case .end: ended = true
                    }
                }
            }
        }
        return (payload, ended)
    }

    static let stream: [UInt8] =
        Frame(type: .streamData, payload: Array("hello ".utf8)).encoded
        + Frame(type: .streamData, payload: (0..<1000).map { UInt8(truncatingIfNeeded: $0) })
        .encoded + FramedStream.endFrame

    /// Data and the end arrive whole however the bytes are cut.
    @Test(arguments: [1, 2, 4, 5, 6, 7, 64, 1 << 16]) func decodesInPiecesOfAnySize(size: Int)
        throws
    {
        let (payload, ended) = try Self.decode(Self.stream, pieceSize: size)
        #expect(payload == Array("hello ".utf8) + (0..<1000).map { UInt8(truncatingIfNeeded: $0) })
        #expect(ended)
    }

    @Test func endFrameIsAnEmptyStreamEndFrame() {
        #expect(FramedStream.endFrame == [0, 0, 0, 0, 0x08])
        #expect(Frame(type: .streamData, payload: [7]).encoded == [0, 0, 0, 1, 0x07, 7])
    }

    @Test func writesTheDataHeaderInPlace() {
        var header = [UInt8](repeating: 0xFF, count: Frame.headerSize)
        header.withUnsafeMutableBytes {
            FramedStream.writeDataHeader(count: 0x0102_03, to: $0.baseAddress!)
        }
        #expect(header == [0, 0x01, 0x02, 0x03, 0x07])
    }

    @Test func refusesBytesAfterTheEnd() {
        #expect(throws: FramedStreamError.bytesAfterEnd) {
            try Self.decode(FramedStream.endFrame + [0], pieceSize: 64)
        }
    }

    @Test func refusesFramesOfOtherTypesAndSizes() {
        #expect(throws: FramedStreamError.unexpectedType(0x02)) {
            try Self.decode(Frame.control(.info).encoded, pieceSize: 64)
        }
        #expect(throws: FramedStreamError.dataSize(0)) {
            try Self.decode(Frame.header(type: .streamData, payloadSize: 0), pieceSize: 64)
        }
        let oversized = UInt32(AgentProtocol.streamChunkSize + 1)
        #expect(throws: FramedStreamError.dataSize(oversized)) {
            try Self.decode(
                Frame.header(type: .streamData, payloadSize: Int(oversized)), pieceSize: 64)
        }
        #expect(throws: FramedStreamError.endSize(2)) {
            try Self.decode(Frame(type: .streamEnd, payload: [0, 0]).encoded, pieceSize: 64)
        }
    }

    /// The general frame decoder applies the same sizes, before the payload arrives.
    @Test func frameDecoderRefusesMalformedStreamFrames() {
        var decoder = FrameDecoder()
        decoder.append(Frame.header(type: .streamEnd, payloadSize: 3))
        #expect(throws: FrameError.malformedStream(.endSize(3))) { try decoder.nextFrame() }
        var empty = FrameDecoder()
        empty.append(Frame.header(type: .streamData, payloadSize: 0))
        #expect(throws: FrameError.malformedStream(.dataSize(0))) { try empty.nextFrame() }
    }

    @Test func reportsWhetherItStandsBetweenFrames() throws {
        var decoder = FramedStreamDecoder()
        #expect(decoder.isBetweenFrames)
        let bytes = Frame(type: .streamData, payload: [1, 2]).encoded
        var offset = 0
        try Array(bytes.prefix(3)).withUnsafeBytes { raw in
            _ = try decoder.next(raw, from: &offset)
        }
        #expect(!decoder.isBetweenFrames)
    }
}
