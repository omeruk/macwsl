import Foundation
import Testing
import os

@testable import MawTerminalKit

@MainActor
@Suite struct OutputPumpTests {
    /// Writes `chunks` from a thread of its own, as a session's reading thread does, and
    /// records how far it got.
    final class Writer: Sendable {
        private struct Progress {
            var written = 0
            var refused = false
            var done = false
        }
        private let progress = OSAllocatedUnfairLock(initialState: Progress())
        var written: Int { progress.withLock { $0.written } }
        var refused: Bool { progress.withLock { $0.refused } }
        var done: Bool { progress.withLock { $0.done } }

        init(_ pump: OutputPump<Int32>, chunks: [[UInt8]], end: Int32? = nil) {
            Thread.detachNewThread { [self] in
                for chunk in chunks {
                    let accepted = chunk.withUnsafeBytes { pump.write($0) }
                    guard accepted else {
                        progress.withLock { $0.refused = true }
                        break
                    }
                    progress.withLock { $0.written += chunk.count }
                }
                if let end { pump.finish(end) }
                progress.withLock { $0.done = true }
            }
        }
    }

    static func chunks(_ count: Int, of size: Int) -> [[UInt8]] {
        (0..<count).map { index in [UInt8](repeating: UInt8(truncatingIfNeeded: index), count: size)
        }
    }

    @Test func aWriterBlocksWhileTheBufferIsFull() async throws {
        let pump = OutputPump<Int32>(capacity: 4096, sliceLimit: 1024)
        let writer = Writer(pump, chunks: Self.chunks(16, of: 1024))
        #expect(await waitUntil(seconds: 5) { writer.written == 4096 })
        try await Task.sleep(for: .milliseconds(200))
        // Nothing has been delivered, so the fifth chunk waits.
        #expect(writer.written == 4096)
        #expect(pump.pending == 4096)
        #expect(!writer.done)
        pump.close()
        #expect(await waitUntil(seconds: 5) { writer.done })
        #expect(writer.refused)
    }

    @Test func deliversInOrderInBoundedSlicesThenTheEnd() async {
        let pump = OutputPump<Int32>(capacity: 4096, sliceLimit: 1000)
        let chunks = Self.chunks(40, of: 700)
        _ = Writer(pump, chunks: chunks, end: 7)
        var received: [UInt8] = []
        var largest = 0
        var peak = 0
        let end = await pump.deliver { slice in
            received += slice
            largest = max(largest, slice.count)
            peak = max(peak, pump.pending)
        }
        #expect(end == 7)
        #expect(received == chunks.flatMap { $0 })
        #expect(largest <= 1000)
        #expect(peak <= 4096)
    }

    @Test func theMainActorStaysResponsiveDuringAFlood() async {
        let pump = OutputPump<Int32>()
        _ = Writer(pump, chunks: Self.chunks(256, of: 64 << 10), end: 0)
        var turns = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                turns += 1
                await Task.yield()
            }
        }
        var slices = 0
        _ = await pump.deliver { _ in slices += 1 }
        ticker.cancel()
        // 16 MiB in slices of at most 128 KiB, with other work running between them.
        #expect(slices >= 128)
        #expect(turns >= slices / 2)
    }

    @Test func closingStopsDeliveryAndUnblocksTheWriter() async {
        let pump = OutputPump<Int32>(capacity: 1024, sliceLimit: 256)
        let writer = Writer(pump, chunks: Self.chunks(64, of: 512), end: 1)
        var slices = 0
        let end = await pump.deliver { _ in
            slices += 1
            if slices == 3 { pump.close() }
        }
        #expect(end == nil)
        #expect(await waitUntil(seconds: 5) { writer.done })
        #expect(writer.refused)
        #expect(pump.pending == 0)
    }

    @Test func theEndUnblocksAWaitingWriterAndLaterWritesAreRefused() async {
        let pump = OutputPump<Int32>(capacity: 1024, sliceLimit: 256)
        let writer = Writer(pump, chunks: Self.chunks(4, of: 1024))
        #expect(await waitUntil(seconds: 5) { pump.pending == 1024 })
        pump.finish(5)
        #expect(await waitUntil(seconds: 5) { writer.done })
        #expect(writer.refused)
        var received = 0
        let end = await pump.deliver { received += $0.count }
        #expect(end == 5)
        #expect(received == 1024)
    }
}
