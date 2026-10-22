import Testing

@testable import MawProtocol

@Suite struct ByteBufferTests {
    @Test func consumesFromTheFront() {
        var buffer = ByteBuffer()
        buffer.append(contentsOf: [1, 2, 3, 4])
        buffer.append(5)
        buffer.consume(2)
        #expect(buffer.count == 3)
        #expect(buffer.withUnsafeBytes { Array($0) } == [3, 4, 5])
    }

    @Test func releasesItsBytesOnceEverythingIsConsumed() {
        var buffer = ByteBuffer()
        buffer.append(contentsOf: [UInt8](repeating: 1, count: 1000))
        buffer.consume(1000)
        #expect(buffer.isEmpty)
        #expect(buffer.storageCount == 0)
    }

    /// A reader slower than the writer keeps a backlog that never drains. The storage must stay
    /// proportional to the backlog, not grow with everything ever appended.
    @Test func staysBoundedWhileABacklogPersists() {
        var buffer = ByteBuffer()
        let chunk = [UInt8](repeating: 7, count: 32 << 10)
        var largestStorage = 0
        for _ in 0..<1_000 {
            buffer.append(contentsOf: chunk)
            // Consume half of each chunk until the backlog is about 256 KiB, then all of it.
            buffer.consume(buffer.count > 256 << 10 ? chunk.count : chunk.count / 2)
            largestStorage = max(largestStorage, buffer.storageCount)
        }
        #expect(buffer.count > 200 << 10)
        #expect(largestStorage < 2 * (buffer.count + ByteBuffer.compactionThreshold + chunk.count))
    }

    @Test func keepsTheUnconsumedBytesInOrderAcrossCompaction() {
        var buffer = ByteBuffer()
        var expected: [UInt8] = []
        var next: UInt8 = 0
        for _ in 0..<200 {
            let piece = (0..<1_000).map { _ in
                next &+= 1
                return next
            }
            buffer.append(contentsOf: piece)
            expected.append(contentsOf: piece)
            buffer.consume(700)
            expected.removeFirst(700)
        }
        #expect(buffer.withUnsafeBytes { Array($0) } == expected)
    }

    @Test func removesEverything() {
        var buffer = ByteBuffer()
        buffer.append(contentsOf: [1, 2, 3])
        buffer.consume(1)
        buffer.removeAll()
        #expect(buffer.isEmpty)
        #expect(buffer.storageCount == 0)
    }
}
