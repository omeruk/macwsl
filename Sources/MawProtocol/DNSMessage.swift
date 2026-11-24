/// The DNS messages that pass between the guest's resolver, the agent, and the daemon
/// (docs/decisions/0024-dns-through-the-mac.md): queries as the agent receives them, and the
/// responses that the daemon builds from the Mac's answers (RFC 1035, and RFC 6891 for EDNS).
/// Pure, so that both sides use the same rules and its tests run anywhere.

/// A response's RCODE.
public enum DNSResponseCode: UInt8, Sendable, CaseIterable {
    case noError = 0
    case formatError = 1
    case serverFailure = 2
    case nameError = 3
    case notImplemented = 4
    case refused = 5

    public var name: String {
        switch self {
        case .noError: "NOERROR"
        case .formatError: "FORMERR"
        case .serverFailure: "SERVFAIL"
        case .nameError: "NXDOMAIN"
        case .notImplemented: "NOTIMP"
        case .refused: "REFUSED"
        }
    }
}

/// Record types by number.
public enum DNSRecordType {
    public static let a: UInt16 = 1
    public static let ns: UInt16 = 2
    public static let cname: UInt16 = 5
    public static let soa: UInt16 = 6
    public static let ptr: UInt16 = 12
    public static let mx: UInt16 = 15
    public static let txt: UInt16 = 16
    public static let aaaa: UInt16 = 28
    public static let srv: UInt16 = 33
    public static let opt: UInt16 = 41

    /// The types that the Mac's resolver answers for the guest. A query for any other type is
    /// answered NOTIMP.
    public static let answered: Set<UInt16> = [a, aaaa, cname, mx, txt, srv, ptr]

    /// The types that tell whether a name exists when the Mac's resolver reports no record of
    /// the type that was asked for (docs/decisions/0024-dns-through-the-mac.md).
    public static let existenceProbes: [UInt16] = [a, aaaa, txt, mx, srv, ns, soa]

    public static func name(_ type: UInt16) -> String {
        switch type {
        case a: "A"
        case ns: "NS"
        case cname: "CNAME"
        case soa: "SOA"
        case ptr: "PTR"
        case mx: "MX"
        case txt: "TXT"
        case aaaa: "AAAA"
        case srv: "SRV"
        case opt: "OPT"
        default: "TYPE\(type)"
        }
    }
}

/// A domain name as a sequence of labels, each of 1 to 63 bytes, at most 255 bytes on the
/// wire. Comparisons ignore ASCII case, as DNS does.
public struct DNSName: Hashable, Sendable, CustomStringConvertible {
    public static let maximumWireLength = 255
    public static let maximumLabelLength = 63
    public static let root = DNSName(validated: [])

    public let labels: [[UInt8]]

    private init(validated labels: [[UInt8]]) {
        self.labels = labels
    }

    /// `nil` unless every label has 1 to 63 bytes and the name fits in 255 bytes.
    public init?(labels: [[UInt8]]) {
        guard labels.allSatisfy({ !$0.isEmpty && $0.count <= Self.maximumLabelLength }),
            labels.reduce(1, { $0 + 1 + $1.count }) <= Self.maximumWireLength
        else { return nil }
        self.labels = labels
    }

    /// A name in presentation format, such as `www.example.com.` or `www.example.com`, in
    /// which `\.`, `\\`, and `\DDD` (a decimal byte) escape a label's bytes, as `dns_sd.h`
    /// writes and reads them. `.` alone is the root.
    public init?(presentation text: String) {
        var labels: [[UInt8]] = []
        var label: [UInt8] = []
        var bytes = Array(text.utf8)[...]
        if text == "." { bytes = [] }
        while let byte = bytes.popFirst() {
            switch byte {
            case UInt8(ascii: "."):
                guard !label.isEmpty else { return nil }
                labels.append(label)
                label = []
            case UInt8(ascii: "\\"):
                guard let next = bytes.popFirst() else { return nil }
                if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(next) {
                    guard bytes.count >= 2,
                        let second = bytes.popFirst(), let third = bytes.popFirst(),
                        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(second),
                        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(third)
                    else { return nil }
                    let value =
                        Int(next - 48) * 100 + Int(second - 48) * 10 + Int(third - 48)
                    guard value <= 255 else { return nil }
                    label.append(UInt8(value))
                } else {
                    label.append(next)
                }
            default:
                label.append(byte)
            }
        }
        if !label.isEmpty {
            labels.append(label)
        }
        self.init(labels: labels)
    }

    /// The name in presentation format with a final dot, escaped as `init(presentation:)`
    /// reads it: `www.example.com.`, or `.` for the root.
    public var presentation: String {
        guard !labels.isEmpty else { return "." }
        var text = ""
        for label in labels {
            for byte in label {
                switch byte {
                case UInt8(ascii: "."), UInt8(ascii: "\\"):
                    text += "\\" + String(UnicodeScalar(byte))
                case 0x21...0x7E:
                    text += String(UnicodeScalar(byte))
                default:
                    let digits = String(byte)
                    text += "\\" + String(repeating: "0", count: 3 - digits.count) + digits
                }
            }
            text += "."
        }
        return text
    }

    public var description: String { presentation }

    /// The name on the wire, uncompressed.
    public var wire: [UInt8] {
        var bytes: [UInt8] = []
        for label in labels {
            bytes.append(UInt8(label.count))
            bytes += label
        }
        bytes.append(0)
        return bytes
    }

    public var isSingleLabel: Bool { labels.count == 1 }

    /// The name followed by `suffix`, or `nil` if the result is too long.
    public func appending(_ suffix: DNSName) -> DNSName? {
        DNSName(labels: labels + suffix.labels)
    }

    /// Whether the name is `suffix` or a name under it.
    public func isEqualOrUnder(_ suffix: DNSName) -> Bool {
        guard suffix.labels.count <= labels.count else { return false }
        return zip(labels.suffix(suffix.labels.count), suffix.labels).allSatisfy {
            Self.equalIgnoringCase($0, $1)
        }
    }

    public static func == (lhs: DNSName, rhs: DNSName) -> Bool {
        lhs.labels.count == rhs.labels.count
            && zip(lhs.labels, rhs.labels).allSatisfy { equalIgnoringCase($0, $1) }
    }

    public func hash(into hasher: inout Hasher) {
        for label in labels {
            hasher.combine(label.map(Self.lowercased))
        }
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte | 0x20 : byte
    }

    private static func equalIgnoringCase(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { lowercased($0) == lowercased($1) }
    }
}

/// One resource record of an answer.
public struct DNSRecord: Equatable, Sendable {
    public var name: DNSName
    public var type: UInt16
    public var timeToLive: UInt32
    /// The record's data on the wire, uncompressed, as the Mac's resolver returns it.
    public var data: [UInt8]

    public init(name: DNSName, type: UInt16, timeToLive: UInt32, data: [UInt8]) {
        self.name = name
        self.type = type
        self.timeToLive = timeToLive
        self.data = data
    }

    /// For a CNAME record, the name it leads to.
    public var canonicalName: DNSName? {
        guard type == DNSRecordType.cname else { return nil }
        return DNSQuery.readName(data[...], from: 0, compressed: false).flatMap {
            $0.end == data.count ? $0.name : nil
        }
    }
}

/// Why a query is not passed on to the Mac.
public enum DNSQueryError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No answer is possible: fewer than 12 bytes, or a message that is itself a response.
    case unanswerable(String)
    /// Answered FORMERR.
    case malformed(String)
    /// Answered NOTIMP: an operation other than a standard query.
    case notImplemented(String)

    public var description: String {
        switch self {
        case .unanswerable(let reason), .malformed(let reason), .notImplemented(let reason):
            reason
        }
    }

    /// The code of the answer, or `nil` for a message that gets none.
    public var responseCode: DNSResponseCode? {
        switch self {
        case .unanswerable: nil
        case .malformed: .formatError
        case .notImplemented: .notImplemented
        }
    }
}

/// A standard query with one question, as a stub resolver sends it.
public struct DNSQuery: Equatable, Sendable {
    /// The largest query accepted; a larger one is answered FORMERR.
    public static let maximumSize = 512
    static let headerSize = 12

    public var id: UInt16
    /// The query's second header word. A response copies its opcode, RD, and CD bits.
    public var flags: UInt16
    public var name: DNSName
    public var type: UInt16
    public var questionClass: UInt16
    /// The UDP payload size of the query's OPT record, or `nil` without one.
    public var ednsPayloadSize: UInt16?

    public init(
        id: UInt16, flags: UInt16 = 0x0100, name: DNSName, type: UInt16,
        questionClass: UInt16 = 1, ednsPayloadSize: UInt16? = nil
    ) {
        self.id = id
        self.flags = flags
        self.name = name
        self.type = type
        self.questionClass = questionClass
        self.ednsPayloadSize = ednsPayloadSize
    }

    public var opcode: UInt8 { UInt8(truncatingIfNeeded: flags >> 11) & 0x0F }

    /// The largest response that may be sent over UDP: the query's EDNS payload size within
    /// 512 to 4,096 bytes, or 512 without EDNS. A larger one is sent truncated.
    public var maximumUDPResponseSize: Int {
        ednsPayloadSize.map { min(max(Int($0), 512), 4_096) } ?? 512
    }

    /// The query on the wire, with an OPT record if it has an EDNS payload size.
    public var encoded: [UInt8] {
        var bytes = Self.word(id) + Self.word(flags) + Self.word(1) + Self.word(0) + Self.word(0)
        bytes += Self.word(ednsPayloadSize == nil ? 0 : 1)
        bytes += name.wire + Self.word(type) + Self.word(questionClass)
        if let ednsPayloadSize {
            bytes += [0] + Self.word(DNSRecordType.opt) + Self.word(ednsPayloadSize)
            bytes += [0, 0, 0, 0, 0, 0]
        }
        return bytes
    }

    /// Reads a query. Everything but a standard query of one question in class-independent
    /// form, with at most one OPT record and nothing after it, is rejected.
    public static func parse(_ bytes: [UInt8]) -> Result<DNSQuery, DNSQueryError> {
        guard bytes.count >= headerSize else {
            return .failure(.unanswerable("a message of \(bytes.count) bytes has no header"))
        }
        let flags = word(bytes, at: 2)
        guard flags & 0x8000 == 0 else {
            return .failure(.unanswerable("the message is a response"))
        }
        guard bytes.count <= maximumSize else {
            return .failure(.malformed("a query of \(bytes.count) bytes is larger than 512"))
        }
        guard (flags >> 11) & 0x0F == 0 else {
            return .failure(.notImplemented("opcode \((flags >> 11) & 0x0F) is not a query"))
        }
        guard word(bytes, at: 4) == 1, word(bytes, at: 6) == 0, word(bytes, at: 8) == 0 else {
            return .failure(.malformed("a query needs one question and no answers"))
        }
        let additional = word(bytes, at: 10)
        guard additional <= 1 else {
            return .failure(.malformed("a query has at most one additional record"))
        }
        guard let (name, nameEnd) = readName(bytes[...], from: headerSize, compressed: false),
            nameEnd + 4 <= bytes.count
        else {
            return .failure(.malformed("the question is malformed"))
        }
        var query = DNSQuery(
            id: word(bytes, at: 0), flags: flags, name: name, type: word(bytes, at: nameEnd),
            questionClass: word(bytes, at: nameEnd + 2))
        var offset = nameEnd + 4
        if additional == 1 {
            // An OPT record: the root name, type 41, the payload size in the class field, then
            // the extended RCODE, the version, the flags, and the options.
            guard offset + 11 <= bytes.count, bytes[offset] == 0,
                word(bytes, at: offset + 1) == DNSRecordType.opt
            else {
                return .failure(.malformed("the additional record is not an OPT record"))
            }
            guard bytes[offset + 6] == 0 else {
                return .failure(.malformed("EDNS version \(bytes[offset + 6]) is not supported"))
            }
            query.ednsPayloadSize = word(bytes, at: offset + 3)
            offset += 11 + Int(word(bytes, at: offset + 9))
        }
        guard offset == bytes.count else {
            return .failure(.malformed("the query has bytes after its records"))
        }
        return .success(query)
    }

    /// Reads a name at `start`. Compression pointers are refused unless `compressed`, and
    /// followed at most 16 times otherwise. Returns the name and where its wire form ends.
    static func readName(
        _ bytes: ArraySlice<UInt8>, from start: Int, compressed: Bool = true
    ) -> (name: DNSName, end: Int)? {
        let base = bytes.startIndex
        var labels: [[UInt8]] = []
        var offset = start
        var end: Int?
        var jumps = 0
        while true {
            guard base + offset < bytes.endIndex else { return nil }
            let length = Int(bytes[base + offset])
            if length == 0 {
                guard let name = DNSName(labels: labels) else { return nil }
                return (name, end ?? offset + 1)
            }
            if length & 0xC0 == 0xC0, compressed {
                guard base + offset + 1 < bytes.endIndex, jumps < 16 else { return nil }
                if end == nil { end = offset + 2 }
                offset = (length & 0x3F) << 8 | Int(bytes[base + offset + 1])
                jumps += 1
                continue
            }
            guard length <= DNSName.maximumLabelLength,
                base + offset + 1 + length <= bytes.endIndex
            else { return nil }
            labels.append(Array(bytes[(base + offset + 1)..<(base + offset + 1 + length)]))
            guard labels.count <= 127 else { return nil }
            offset += 1 + length
        }
    }

    static func word(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    static func word(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }
}

/// What happens to a query that is well formed.
public enum DNSQueryPolicy {
    public enum Verdict: Equatable, Sendable {
        /// Pass the query on to the Mac's resolver.
        case resolve
        /// Answer at once with this code.
        case answer(DNSResponseCode)
    }

    /// Names that the Mac would look up with multicast DNS, which needs the Local Network
    /// permission: `.local`, and the reverse zones of IPv4 and IPv6 link-local addresses.
    public static let multicastSuffixes: [DNSName] = [
        "local", "254.169.in-addr.arpa", "8.e.f.ip6.arpa", "9.e.f.ip6.arpa", "a.e.f.ip6.arpa",
        "b.e.f.ip6.arpa",
    ].compactMap { DNSName(presentation: $0) }

    public static func verdict(for query: DNSQuery) -> Verdict {
        guard query.questionClass == 1, DNSRecordType.answered.contains(query.type) else {
            return .answer(.notImplemented)
        }
        if multicastSuffixes.contains(where: { query.name.isEqualOrUnder($0) }) {
            return .answer(.refused)
        }
        return .resolve
    }
}

/// Responses to queries.
public enum DNSResponse {
    /// The largest response: what a TCP message can carry.
    public static let maximumSize = 65_535
    /// The UDP payload size that a response's OPT record advertises.
    public static let advertisedPayloadSize: UInt16 = 4_096

    /// A response to `query` with `code` and `answers`, in that order, with an OPT record if
    /// the query had one. Owner names are not compressed.
    public static func encode(
        _ query: DNSQuery, code: DNSResponseCode, answers: [DNSRecord] = []
    ) -> [UInt8] {
        var bytes = DNSQuery.word(query.id) + DNSQuery.word(flags(for: query.flags, code: code))
        bytes += DNSQuery.word(1) + DNSQuery.word(UInt16(clamping: answers.count))
        bytes += DNSQuery.word(0) + DNSQuery.word(query.ednsPayloadSize == nil ? 0 : 1)
        bytes += query.name.wire + DNSQuery.word(query.type) + DNSQuery.word(query.questionClass)
        for record in answers.prefix(Int(UInt16.max)) {
            bytes += record.name.wire + DNSQuery.word(record.type) + DNSQuery.word(1)
            bytes += [
                UInt8(truncatingIfNeeded: record.timeToLive >> 24),
                UInt8(truncatingIfNeeded: record.timeToLive >> 16),
                UInt8(truncatingIfNeeded: record.timeToLive >> 8),
                UInt8(truncatingIfNeeded: record.timeToLive),
            ]
            bytes += DNSQuery.word(UInt16(clamping: record.data.count))
            bytes += record.data.prefix(Int(UInt16.max))
        }
        if query.ednsPayloadSize != nil {
            bytes += [0] + DNSQuery.word(DNSRecordType.opt) + DNSQuery.word(advertisedPayloadSize)
            bytes += [0, 0, 0, 0, 0, 0]
        }
        return bytes
    }

    /// The same response without its records and with the TC bit set, for a response larger
    /// than the transport carries: the resolver asks again over TCP.
    public static func truncated(_ query: DNSQuery, code: DNSResponseCode) -> [UInt8] {
        var bytes = encode(query, code: code)
        bytes[2] |= 0x02
        return bytes
    }

    /// An answer with `code` to a query that could not be parsed, from its header and, when it
    /// can be read, its question; `nil` for a message that gets no answer.
    public static func error(_ code: DNSResponseCode, toQuery bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count >= DNSQuery.headerSize, bytes[2] & 0x80 == 0 else { return nil }
        let flags = flags(for: DNSQuery.word(bytes, at: 2), code: code)
        var question: [UInt8] = []
        if DNSQuery.word(bytes, at: 4) == 1,
            let (_, end) = DNSQuery.readName(
                bytes[...], from: DNSQuery.headerSize, compressed: false),
            end + 4 <= bytes.count
        {
            question = Array(bytes[DNSQuery.headerSize..<(end + 4)])
        }
        return [bytes[0], bytes[1]] + DNSQuery.word(flags)
            + DNSQuery.word(question.isEmpty ? 0 : 1) + [0, 0, 0, 0, 0, 0] + question
    }

    /// The response code of a response's header.
    public static func code(of response: [UInt8]) -> DNSResponseCode? {
        guard response.count >= DNSQuery.headerSize else { return nil }
        return DNSResponseCode(rawValue: response[3] & 0x0F)
    }

    /// The number of answer records in a response's header.
    public static func answerCount(of response: [UInt8]) -> Int {
        response.count >= DNSQuery.headerSize ? Int(DNSQuery.word(response, at: 6)) : 0
    }

    /// QR and RA set, the query's opcode, RD, and CD kept, AA, TC, and AD clear.
    private static func flags(for queryFlags: UInt16, code: DNSResponseCode) -> UInt16 {
        0x8000 | (queryFlags & 0x7900) | 0x0080 | (queryFlags & 0x0010) | UInt16(code.rawValue)
    }
}
