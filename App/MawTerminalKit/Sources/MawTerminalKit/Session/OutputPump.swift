import Foundation

/// Carries a session's output from the thread that reads it to the terminal view on the main
/// actor, with flow control, then how the session ended.
///
/// The reading thread's `write` blocks while `capacity` bytes wait, so a flood of output slows
/// the program that writes it instead of growing a buffer. The main actor takes at most
/// `sliceLimit` bytes per turn and yields between slices, so that drawing, typing, and resizing
/// stay responsive during a flood.
final class OutputPump<End: Sendable>: @unchecked Sendable {
    static var capacity: Int { 1 << 20 }
    static var sliceLimit: Int { 128 << 10 }

    private enum Item: Sendable {
        case bytes([UInt8])
        case end(End)
        case closed
    }

    // Guarded by `condition`.
    private let condition = NSCondition()
    private var buffer: [UInt8] = []
    /// Where the bytes not yet taken start in `buffer`.
    private var start = 0
    private var end: End?
    private var isClosed = false
    private var waiter: CheckedContinuation<Void, Never>?

    private let capacity: Int
    private let sliceLimit: Int

    init(capacity: Int = OutputPump.capacity, sliceLimit: Int = OutputPump.sliceLimit) {
        self.capacity = capacity
        self.sliceLimit = sliceLimit
    }

    /// The bytes waiting for the main actor.
    var pending: Int {
        condition.withLock { buffer.count - start }
    }

    /// Adds output, waiting while the buffer is full. Returns false once the reader has closed
    /// the pump, so that the writing thread can stop reading.
    @discardableResult
    func write(_ bytes: UnsafeRawBufferPointer) -> Bool {
        let resumed = condition.withLock { () -> CheckedContinuation<Void, Never>?? in
            while !isClosed, end == nil, buffer.count - start > 0,
                buffer.count - start + bytes.count > capacity
            {
                condition.wait()
            }
            guard !isClosed, end == nil else { return .none }
            buffer.append(contentsOf: bytes)
            defer { waiter = nil }
            return .some(waiter)
        }
        guard let resumed else { return false }
        resumed?.resume()
        return true
    }

    /// Records how the session ended. The main actor receives it after the bytes written
    /// before it. Later writes and ends are ignored.
    func finish(_ end: End) {
        condition.withLock { () -> CheckedContinuation<Void, Never>? in
            guard !isClosed, self.end == nil else { return nil }
            self.end = end
            condition.broadcast()
            defer { waiter = nil }
            return waiter
        }?.resume()
    }

    /// Stops delivery and drops what waits, for example when the pane closes. A blocked
    /// `write` returns false.
    func close() {
        condition.withLock { () -> CheckedContinuation<Void, Never>? in
            isClosed = true
            buffer = []
            start = 0
            condition.broadcast()
            defer { waiter = nil }
            return waiter
        }?.resume()
    }

    /// Delivers the output to `receive` slice by slice, yielding after each, and returns how the
    /// session ended, or `nil` if the pump was closed first.
    @MainActor
    func deliver(to receive: @MainActor (ArraySlice<UInt8>) -> Void) async -> End? {
        while true {
            switch await next() {
            case .bytes(let slice):
                receive(slice[...])
                await Task.yield()
            case .end(let end):
                return end
            case .closed:
                return nil
            }
        }
    }

    private func next() async -> Item {
        while true {
            let item = condition.withLock { () -> Item? in
                if isClosed { return .closed }
                let available = buffer.count - start
                if available == 0 {
                    return end.map(Item.end)
                }
                let count = min(available, sliceLimit)
                let slice = Array(buffer[start..<start + count])
                start += count
                // Moves the rest to the front once at least half the buffer has been taken, so
                // that each byte is moved at most once on average.
                if start == buffer.count {
                    buffer.removeAll(keepingCapacity: true)
                    start = 0
                } else if start >= capacity / 2 {
                    buffer.removeFirst(start)
                    start = 0
                }
                condition.broadcast()
                return .bytes(slice)
            }
            if let item { return item }
            await withCheckedContinuation { continuation in
                let ready = condition.withLock {
                    guard !isClosed, end == nil, buffer.count == start else { return true }
                    waiter = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        }
    }
}
