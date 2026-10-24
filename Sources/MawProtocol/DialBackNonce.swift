/// The one-time value that pairs a `dialBack` request with the connection the agent dials in
/// reply. The host creates it from the system's cryptographically secure generator, sends it
/// in the request, and accepts the dialed connection only if its first frame carries the same
/// value.
///
/// It is the boundary between the host's listener and any other process in the guest, so it
/// is compared in constant time and never printed.
public struct DialBackNonce: Sendable, Hashable, CustomStringConvertible {
    public let bytes: [UInt8]

    /// A nonce of `AgentProtocol.dialBackNonceSize` bytes, or `nil` for any other size.
    public init?(bytes: [UInt8]) {
        guard bytes.count == AgentProtocol.dialBackNonceSize else { return nil }
        self.bytes = bytes
    }

    /// A new nonce from `SystemRandomNumberGenerator`: `arc4random_buf` on macOS, `getrandom`
    /// on Linux.
    public static func random() -> DialBackNonce {
        var generator = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(AgentProtocol.dialBackNonceSize)
        for _ in 0..<AgentProtocol.dialBackNonceSize / 8 {
            withUnsafeBytes(of: generator.next() as UInt64) { bytes.append(contentsOf: $0) }
        }
        return DialBackNonce(bytes: bytes)!
    }

    /// Compares in constant time (`constantTimeEqual`).
    public static func == (lhs: DialBackNonce, rhs: DialBackNonce) -> Bool {
        constantTimeEqual(lhs.bytes, rhs.bytes)
    }

    /// Compares every byte, whatever the first difference, so that the time taken does not
    /// tell how much of a guess was right. Byte sequences of different lengths are unequal.
    static func constantTimeEqual<Bytes: RandomAccessCollection<UInt8>>(
        _ lhs: Bytes, _ rhs: Bytes
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bytes)
    }

    public var description: String { "<nonce>" }

    /// Lowercase hexadecimal, as `dialBack` carries it in JSON.
    public var hexadecimal: String {
        let digits = Array("0123456789abcdef".utf8)
        var text: [UInt8] = []
        text.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: text, as: UTF8.self)
    }

    /// Reads lowercase hexadecimal of exactly twice the nonce's size.
    public init?(hexadecimal text: String) {
        let characters = Array(text.utf8)
        guard characters.count == AgentProtocol.dialBackNonceSize * 2 else { return nil }
        func value(_ character: UInt8) -> UInt8? {
            switch character {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
            default: nil
            }
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(AgentProtocol.dialBackNonceSize)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let high = value(characters[index]), let low = value(characters[index + 1])
            else { return nil }
            bytes.append(high << 4 | low)
        }
        self.init(bytes: bytes)
    }
}
