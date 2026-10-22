/// Bytes appended at the end and consumed from the front: the queue in front of a socket or a
/// pipe that accepts data in pieces.
///
/// Consumed bytes are dropped once they are at least `compactionThreshold` bytes and at least
/// half of the storage. The bytes held therefore stay proportional to the unconsumed bytes, even
/// when a slow reader keeps the queue from ever emptying, at the cost of one copy of the
/// unconsumed bytes each time. The allocated capacity keeps its largest size until the buffer
/// empties; callers bound it by limiting how much they append before the reader catches up.
public struct ByteBuffer: Sendable {
    public static let compactionThreshold = 64 << 10

    private var storage: [UInt8] = []
    private var start = 0

    public init() {}

    /// The bytes not consumed yet.
    public var count: Int { storage.count - start }

    public var isEmpty: Bool { count == 0 }

    /// The bytes held, consumed or not.
    var storageCount: Int { storage.count }

    public mutating func append(_ byte: UInt8) {
        storage.append(byte)
    }

    public mutating func append(contentsOf bytes: some Sequence<UInt8>) {
        storage.append(contentsOf: bytes)
    }

    /// Calls `body` with the bytes not consumed yet.
    public func withUnsafeBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try storage.withUnsafeBytes { buffer in
            try body(UnsafeRawBufferPointer(rebasing: buffer[start...]))
        }
    }

    /// Drops the first `byteCount` unconsumed bytes.
    public mutating func consume(_ byteCount: Int) {
        precondition(byteCount >= 0 && byteCount <= count, "consumed more than was buffered")
        start += byteCount
        if start == storage.count {
            storage.removeAll(keepingCapacity: storage.capacity <= 1 << 20)
            start = 0
        } else if start >= Self.compactionThreshold && start * 2 >= storage.count {
            storage.removeSubrange(0..<start)
            start = 0
        }
    }

    public mutating func removeAll() {
        storage.removeAll()
        start = 0
    }
}
