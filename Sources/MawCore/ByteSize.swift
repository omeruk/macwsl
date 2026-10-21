/// A size in bytes, written the way users write memory and disk sizes: `512M`, `4G`, `4GB`, or
/// `4GiB`.
///
/// Units are binary (1K is 1024 bytes), as in WSL's `.wslconfig`. The unit is required: a bare
/// number is rejected, because "4" could mean bytes or gigabytes.
public struct ByteSize: Hashable, Comparable, Sendable {
    public let bytes: UInt64

    public init(bytes: UInt64) {
        self.bytes = bytes
    }

    public static func kibibytes(_ count: UInt64) -> ByteSize { ByteSize(bytes: count << 10) }
    public static func mebibytes(_ count: UInt64) -> ByteSize { ByteSize(bytes: count << 20) }
    public static func gibibytes(_ count: UInt64) -> ByteSize { ByteSize(bytes: count << 30) }

    /// Parses `<digits><unit>`, where the unit is K, M, G, or T, optionally followed by `B` or
    /// `iB`, in any letter case. The size must be greater than zero.
    public init(parsing text: String) throws(MawError) {
        let trimmed = text.trimmingWhitespace()
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        let unit = trimmed.dropFirst(digits.count).uppercased()

        guard !digits.isEmpty else {
            throw .invalidSize(text, reason: "it must start with a whole number")
        }
        guard !unit.isEmpty else {
            throw .invalidSize(text, reason: "it has no unit")
        }
        let shifts: [String: UInt64] = ["K": 10, "M": 20, "G": 30, "T": 40]
        let letter = String(unit.prefix(1))
        let rest = unit.dropFirst()
        guard let shift = shifts[letter], rest.isEmpty || rest == "B" || rest == "IB" else {
            throw .invalidSize(text, reason: "'\(trimmed.dropFirst(digits.count))' is not a unit")
        }
        guard let count = UInt64(digits) else {
            throw .invalidSize(text, reason: "it is too large")
        }
        guard count > 0 else {
            throw .invalidSize(text, reason: "it must be greater than zero")
        }
        guard count <= UInt64.max >> shift else {
            throw .invalidSize(text, reason: "it is too large")
        }
        self.bytes = count << shift
    }

    public static func < (lhs: ByteSize, rhs: ByteSize) -> Bool {
        lhs.bytes < rhs.bytes
    }

    /// This size rounded down to a whole number of mebibytes.
    public var roundedDownToMebibytes: ByteSize {
        ByteSize(bytes: bytes & ~((1 << 20) - 1))
    }
}

extension ByteSize: CustomStringConvertible {
    /// The largest unit that represents the size exactly, for example `512M` or `2G`.
    public var description: String {
        for (shift, unit) in [(40, "T"), (30, "G"), (20, "M"), (10, "K")] as [(UInt64, String)]
        where bytes != 0 && bytes & ((1 << shift) - 1) == 0 {
            return "\(bytes >> shift)\(unit)"
        }
        return "\(bytes) bytes"
    }
}

extension String {
    fileprivate func trimmingWhitespace() -> Substring {
        let start = firstIndex { !$0.isWhitespace } ?? endIndex
        let end = lastIndex { !$0.isWhitespace }.map(index(after:)) ?? start
        return self[start..<end]
    }
}
