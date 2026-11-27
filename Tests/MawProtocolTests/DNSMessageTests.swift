import Testing

@testable import MawProtocol

@Suite struct DNSMessageTests {
    static func name(_ text: String) -> DNSName { DNSName(presentation: text)! }

    /// A query as a stub resolver sends it, with RD and, if given, an OPT record.
    static func query(
        _ text: String, type: UInt16 = DNSRecordType.a, id: UInt16 = 0x1234,
        payload: UInt16? = 1_232
    ) -> [UInt8] {
        DNSQuery(id: id, name: name(text), type: type, ednsPayloadSize: payload).encoded
    }

    static func parsed(_ bytes: [UInt8]) throws -> DNSQuery {
        try DNSQuery.parse(bytes).get()
    }

    static func failure(_ bytes: [UInt8]) -> DNSQueryError? {
        if case .failure(let error) = DNSQuery.parse(bytes) { return error }
        return nil
    }

    // MARK: Names

    @Test func readsAndWritesNamesInPresentationFormat() {
        let plain = Self.name("www.Example.com.")
        #expect(
            plain.labels.map { String(decoding: $0, as: UTF8.self) } == ["www", "Example", "com"])
        #expect(plain == Self.name("WWW.example.COM"))
        #expect(plain.presentation == "www.Example.com.")
        #expect(
            plain.wire == [3] + Array("www".utf8) + [7] + Array("Example".utf8) + [3]
                + Array("com".utf8) + [0])
        #expect(DNSName(presentation: ".") == DNSName.root)
        #expect(DNSName.root.presentation == ".")
    }

    @Test func escapesDotsBackslashesAndUnprintableBytes() throws {
        let escaped = Self.name(#"a\.b\\c\032d.example"#)
        #expect(escaped.labels.count == 2)
        #expect(escaped.labels[0] == Array("a.b\\c d".utf8))
        #expect(escaped.presentation == #"a\.b\\c\032d.example."#)
        #expect(DNSName(presentation: escaped.presentation) == escaped)
    }

    @Test func refusesNamesThatDNSCannotCarry() {
        #expect(DNSName(presentation: "a..b") == nil)
        #expect(DNSName(presentation: String(repeating: "x", count: 64) + ".com") == nil)
        #expect(DNSName(presentation: String(repeating: "x", count: 63) + ".com") != nil)
        let long = Array(repeating: String(repeating: "x", count: 63), count: 4).joined(
            separator: ".")
        #expect(DNSName(presentation: long) == nil)
        #expect(DNSName(presentation: #"a\256"#) == nil)
        #expect(DNSName(presentation: #"a\2"#) == nil)
        #expect(DNSName(presentation: "a\\") == nil)
    }

    @Test func comparesSuffixesWithoutCase() {
        #expect(Self.name("printer.LOCAL").isEqualOrUnder(Self.name("local")))
        #expect(Self.name("local").isEqualOrUnder(Self.name("local")))
        #expect(!Self.name("notlocal").isEqualOrUnder(Self.name("local")))
        #expect(Self.name("host").isSingleLabel)
        #expect(
            Self.name("host").appending(Self.name("corp.example")) == Self.name("host.corp.example")
        )
    }

    // MARK: Queries

    @Test func parsesAQueryWithAndWithoutEDNS() throws {
        let withOPT = try Self.parsed(Self.query("github.com", type: DNSRecordType.aaaa))
        #expect(withOPT.id == 0x1234)
        #expect(withOPT.name == Self.name("github.com"))
        #expect(withOPT.type == DNSRecordType.aaaa)
        #expect(withOPT.ednsPayloadSize == 1_232)
        #expect(withOPT.maximumUDPResponseSize == 1_232)
        let without = try Self.parsed(Self.query("github.com", payload: nil))
        #expect(without.ednsPayloadSize == nil)
        #expect(without.maximumUDPResponseSize == 512)
        #expect(try Self.parsed(Self.query("a.b", payload: 100)).maximumUDPResponseSize == 512)
        #expect(try Self.parsed(Self.query("a.b", payload: 65_000)).maximumUDPResponseSize == 4_096)
    }

    @Test func givesNoAnswerToAMessageWithoutAHeaderOrToAResponse() {
        #expect(Self.failure([1, 2, 3])?.responseCode == nil)
        var response = Self.query("a.b")
        response[2] |= 0x80
        #expect(Self.failure(response)?.responseCode == nil)
        #expect(DNSResponse.error(.formatError, toQuery: response) == nil)
        #expect(DNSResponse.error(.formatError, toQuery: [1, 2, 3]) == nil)
    }

    @Test func answersMalformedAndOversizedQueriesFORMERR() {
        let valid = Self.query("example.com")
        // Larger than 512 bytes.
        #expect(
            Self.failure(valid + [UInt8](repeating: 0, count: 600))?.responseCode == .formatError)
        // Bytes after the records.
        #expect(Self.failure(valid + [0])?.responseCode == .formatError)
        // Two questions.
        var two = valid
        two[5] = 2
        #expect(Self.failure(two)?.responseCode == .formatError)
        // An answer record in a query.
        var answered = valid
        answered[7] = 1
        #expect(Self.failure(answered)?.responseCode == .formatError)
        // A compression pointer in the question.
        let pointer: [UInt8] = [0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 0x0C, 0, 1, 0, 1]
        #expect(Self.failure(pointer)?.responseCode == .formatError)
        // A question cut off.
        #expect(Self.failure(Array(valid.prefix(16)))?.responseCode == .formatError)
        // An additional record that is not OPT.
        var notOPT = valid
        notOPT[notOPT.count - 10] = 1
        #expect(Self.failure(notOPT)?.responseCode == .formatError)
        // EDNS version 1.
        var version = valid
        version[version.count - 5] = 1
        #expect(Self.failure(version)?.responseCode == .formatError)
    }

    @Test func answersAnotherOpcodeNOTIMP() {
        var notify = Self.query("example.com")
        notify[2] |= 4 << 3
        #expect(Self.failure(notify)?.responseCode == .notImplemented)
    }

    @Test func passesTheSevenTypesOnAndAnswersOthersOrLocalNamesItself() throws {
        for type in [
            DNSRecordType.a, DNSRecordType.aaaa, DNSRecordType.cname, DNSRecordType.mx,
            DNSRecordType.txt, DNSRecordType.srv, DNSRecordType.ptr,
        ] {
            #expect(
                DNSQueryPolicy.verdict(for: try Self.parsed(Self.query("x.org", type: type)))
                    == .resolve)
        }
        for type: UInt16 in [255, 257, DNSRecordType.ns, DNSRecordType.soa, 46, 65] {
            #expect(
                DNSQueryPolicy.verdict(for: try Self.parsed(Self.query("x.org", type: type)))
                    == .answer(.notImplemented))
        }
        var chaos = try Self.parsed(Self.query("version.bind", type: DNSRecordType.txt))
        chaos.questionClass = 3
        #expect(DNSQueryPolicy.verdict(for: chaos) == .answer(.notImplemented))
        for local in ["printer.local", "1.1.254.169.in-addr.arpa", "1.0.0.0.0.8.e.f.ip6.arpa"] {
            #expect(
                DNSQueryPolicy.verdict(
                    for: try Self.parsed(Self.query(local, type: DNSRecordType.ptr)))
                    == .answer(.refused))
        }
    }

    // MARK: Responses

    /// Splits a response into its header fields, question, and records, as a resolver reads it.
    struct Read {
        var id: UInt16
        var flags: UInt16
        var counts: [UInt16]
        var records: [(name: DNSName, type: UInt16, ttl: UInt32, data: [UInt8])]
        var hasOPT: Bool
    }

    static func read(_ bytes: [UInt8]) throws -> Read {
        let counts = (0..<4).map { DNSQuery.word(bytes, at: 4 + 2 * $0) }
        var offset = 12
        for _ in 0..<counts[0] {
            let (_, end) = try #require(DNSQuery.readName(bytes[...], from: offset))
            offset = end + 4
        }
        var records: [(DNSName, UInt16, UInt32, [UInt8])] = []
        var hasOPT = false
        for index in 0..<Int(counts[1] + counts[2] + counts[3]) {
            let (owner, end) = try #require(DNSQuery.readName(bytes[...], from: offset))
            let type = DNSQuery.word(bytes, at: end)
            let ttl =
                UInt32(DNSQuery.word(bytes, at: end + 4)) << 16
                | UInt32(DNSQuery.word(bytes, at: end + 6))
            let length = Int(DNSQuery.word(bytes, at: end + 8))
            let data = Array(bytes[(end + 10)..<(end + 10 + length)])
            if index >= Int(counts[1] + counts[2]), type == DNSRecordType.opt {
                hasOPT = true
            } else {
                records.append((owner, type, ttl, data))
            }
            offset = end + 10 + length
        }
        #expect(offset == bytes.count)
        return Read(
            id: DNSQuery.word(bytes, at: 0), flags: DNSQuery.word(bytes, at: 2), counts: counts,
            records: records, hasOPT: hasOPT)
    }

    @Test func encodesEveryAnsweredTypeWithItsTTLAndData() throws {
        let owner = Self.name("example.org")
        let target = Self.name("mail.example.org")
        let records = [
            DNSRecord(
                name: owner, type: DNSRecordType.a, timeToLive: 300, data: [93, 184, 215, 14]),
            DNSRecord(
                name: owner, type: DNSRecordType.aaaa, timeToLive: 301,
                data: [UInt8](repeating: 1, count: 16)),
            DNSRecord(
                name: Self.name("www.example.org"), type: DNSRecordType.cname, timeToLive: 302,
                data: owner.wire),
            DNSRecord(
                name: owner, type: DNSRecordType.mx, timeToLive: 303, data: [0, 10] + target.wire),
            DNSRecord(
                name: owner, type: DNSRecordType.txt, timeToLive: 304,
                data: [5] + Array("hello".utf8)),
            DNSRecord(
                name: Self.name("_sip._tcp.example.org"), type: DNSRecordType.srv, timeToLive: 305,
                data: [0, 1, 0, 2, 0x13, 0xC4] + target.wire),
            DNSRecord(
                name: Self.name("14.215.184.93.in-addr.arpa"), type: DNSRecordType.ptr,
                timeToLive: 306,
                data: owner.wire),
        ]
        let query = try Self.parsed(Self.query("example.org", type: DNSRecordType.a))
        let response = DNSResponse.encode(query, code: .noError, answers: records)
        let read = try Self.read(response)
        #expect(read.id == 0x1234)
        // QR, RD copied, RA; AA, TC, AD clear; NOERROR.
        #expect(read.flags == 0x8180)
        #expect(read.counts == [1, 7, 0, 1])
        #expect(read.hasOPT)
        #expect(read.records.map(\.type) == records.map(\.type))
        #expect(read.records.map(\.ttl) == Array(300...306))
        #expect(read.records.map(\.data) == records.map(\.data))
        #expect(read.records.map(\.name) == records.map(\.name))
        #expect(records[2].canonicalName == owner)
        #expect(records[0].canonicalName == nil)
        #expect(DNSResponse.code(of: response) == .noError)
        #expect(DNSResponse.answerCount(of: response) == 7)
    }

    @Test func encodesNXDOMAINAndNOTIMPWithTheQuestion() throws {
        let query = try Self.parsed(Self.query("nx.example.com", payload: nil))
        let nx = try Self.read(DNSResponse.encode(query, code: .nameError))
        #expect(nx.flags == 0x8183)
        #expect(nx.counts == [1, 0, 0, 0])
        #expect(!nx.hasOPT)
        let caa = try Self.parsed(Self.query("example.com", type: 257))
        let notImplemented = DNSResponse.encode(caa, code: .notImplemented)
        #expect(DNSResponse.code(of: notImplemented) == .notImplemented)
        #expect(try Self.read(notImplemented).counts == [1, 0, 0, 1])
    }

    @Test func truncatesToTheQuestionWithTheTCBit() throws {
        let query = try Self.parsed(Self.query("big.example", type: DNSRecordType.txt))
        let truncated = try Self.read(DNSResponse.truncated(query, code: .noError))
        #expect(truncated.flags & 0x0200 != 0)
        #expect(truncated.counts == [1, 0, 0, 1])
        #expect(truncated.hasOPT)
    }

    @Test func answersAnUnparsableQueryFromItsHeader() throws {
        var notify = Self.query("example.com", payload: nil)
        notify[2] |= 4 << 3
        let response = try #require(DNSResponse.error(.notImplemented, toQuery: notify))
        let read = try Self.read(response)
        #expect(read.id == 0x1234)
        #expect(read.flags & 0x000F == 4)
        #expect(read.flags & 0x8000 != 0)
        #expect(read.counts == [1, 0, 0, 0])
        // Without a readable question, the response has none.
        let garbage: [UInt8] = [0xAB, 0xCD, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xFF]
        let bare = try #require(DNSResponse.error(.formatError, toQuery: garbage))
        #expect(bare == [0xAB, 0xCD, 0x81, 0x81, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    // MARK: Frames

    @Test func carriesATagAndAMessageInDNSFrames() throws {
        let message = Self.query("example.com")
        let frame = Frame.dns(.dnsQuery, tag: 0xDEAD_BEEF, message: message)
        var decoder = FrameDecoder()
        decoder.append(frame.encoded)
        let decoded = try #require(try decoder.nextFrame())
        #expect(decoded.type == .dnsQuery)
        let (tag, carried) = try decoded.dnsMessage()
        #expect(tag == 0xDEAD_BEEF)
        #expect(carried == message)
        #expect(throws: FrameError.unexpectedType(0x02, expected: "dnsQuery or dnsAnswer")) {
            try Frame.control(.info).dnsMessage()
        }
    }

    @Test func refusesDNSFramesWithoutAMessageOrLargerThanTCPCarries() {
        for size in [0, 4, AgentProtocol.maximumDNSFramePayload + 1] {
            var decoder = FrameDecoder()
            decoder.append(Frame.header(type: .dnsAnswer, payloadSize: size))
            #expect(throws: FrameError.malformedDNSMessage(size: size)) {
                _ = try decoder.nextFrame()
            }
        }
        var largest = FrameDecoder()
        largest.append(
            Frame.header(type: .dnsAnswer, payloadSize: AgentProtocol.maximumDNSFramePayload))
        #expect((try? largest.nextFrame()) == .some(nil))
    }

    @Test func encodesTheDNSRequest() throws {
        #expect(ControlMessage.dns.encodedJSON() == Array(#"{"dns":{}}"#.utf8))
        #expect(try ControlMessage(json: Array(#"{"dns":{}}"#.utf8)) == .dns)
    }
}
