import MawProtocol
import Testing
import os

@testable import MawDaemonKit

/// A resolver that answers from a table, records what it was asked, and can wait forever.
final class FakeResolver: SystemDNSResolving, @unchecked Sendable {
    struct Key: Hashable {
        var name: DNSName
        var type: UInt16
    }

    private let state = OSAllocatedUnfairLock(
        initialState: (answers: [Key: DNSLookup](), asked: [Key](), domains: [DNSName]()))
    /// Lookups not in the table: wait until cancelled when true, `noSuchRecord` otherwise.
    let hangs: Bool

    init(hangs: Bool = false) {
        self.hangs = hangs
    }

    func set(_ name: String, _ type: UInt16, _ lookup: DNSLookup) {
        state.withLock { $0.answers[Key(name: DNSName(presentation: name)!, type: type)] = lookup }
    }

    func setSearchDomains(_ domains: [String]) {
        state.withLock { $0.domains = domains.map { DNSName(presentation: $0)! } }
    }

    var asked: [Key] { state.withLock { $0.asked } }

    func lookup(_ name: DNSName, type: UInt16) async -> DNSLookup {
        let key = Key(name: name, type: type)
        let answer = state.withLock { state in
            state.asked.append(key)
            return state.answers[key]
        }
        if let answer { return answer }
        if hangs {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return DNSLookup(.failed)
        }
        return DNSLookup(.noSuchRecord)
    }

    func searchDomains() -> [DNSName] { state.withLock { $0.domains } }
}

@Suite struct DNSAnswererTests {
    static func name(_ text: String) -> DNSName { DNSName(presentation: text)! }

    static func record(_ owner: String, _ type: UInt16, _ data: [UInt8], ttl: UInt32 = 60)
        -> DNSRecord
    {
        DNSRecord(name: name(owner), type: type, timeToLive: ttl, data: data)
    }

    static func cname(_ owner: String, _ target: String) -> DNSRecord {
        record(owner, DNSRecordType.cname, name(target).wire)
    }

    static func query(_ text: String, _ type: UInt16 = DNSRecordType.a) -> DNSQuery {
        DNSQuery(id: 1, name: name(text), type: type)
    }

    /// docs/security.md: no name under `.local` or a link-local reverse zone reaches the
    /// Mac's resolver, also one built from a search domain or a CNAME chain.
    @Test func neverLooksUpAMulticastNameItBuilt() async {
        let resolver = FakeResolver()
        resolver.setSearchDomains(["local", "example.com"])
        resolver.set(
            "printer.example.com", DNSRecordType.a,
            DNSLookup(.found, records: [Self.record("printer.example.com", 1, [192, 0, 2, 7])]))
        resolver.set(
            "alias.example.com", DNSRecordType.aaaa,
            DNSLookup(.noSuchRecord, records: [Self.cname("alias.example.com", "box.local")]))
        let answerer = DNSAnswerer(resolver: resolver)
        let found = await answerer.answer(Self.query("printer"))
        #expect(found.code == .noError && found.records.count == 2)
        let alias = await answerer.answer(Self.query("alias.example.com", DNSRecordType.aaaa))
        #expect(alias.code == .noError)
        #expect(
            !resolver.asked.contains {
                $0.name.isEqualOrUnder(Self.name("local"))
            })
    }

    /// A lookup from a task cancelled before it began returns at once, as the existence
    /// probes' and the relay's cancellations need; it never reaches mDNSResponder.
    @Test(.timeLimit(.minutes(1))) func returnsALookupCancelledBeforeItBegan() async {
        let resolver = MacDNSResolver()
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await resolver.lookup(Self.name("example.com"), type: DNSRecordType.a).outcome
        }.value
        #expect(outcome == .failed)
    }

    @Test func answersWithTheMacsRecords() async {
        let resolver = FakeResolver()
        let a = Self.record("github.com", DNSRecordType.a, [140, 82, 121, 3], ttl: 37)
        resolver.set("github.com", DNSRecordType.a, DNSLookup(.found, records: [a]))
        let (code, records) = await DNSAnswerer(resolver: resolver).answer(Self.query("github.com"))
        #expect(code == .noError)
        #expect(records == [a])
    }

    @Test func putsTheCNAMEChainFirstInOrder() async {
        let resolver = FakeResolver()
        let a = Self.record("b.example", DNSRecordType.a, [192, 0, 2, 7])
        // The Mac delivers the CNAMEs in any order.
        resolver.set(
            "www.example", DNSRecordType.a,
            DNSLookup(
                .found,
                records: [
                    Self.cname("a.example", "b.example"), a, Self.cname("www.example", "a.example"),
                ]))
        let (_, records) = await DNSAnswerer(resolver: resolver).answer(Self.query("www.example"))
        #expect(
            records == [
                Self.cname("www.example", "a.example"), Self.cname("a.example", "b.example"), a,
            ])
    }

    @Test func answersNXDOMAINWhenNoTypeHasARecord() async {
        let resolver = FakeResolver()
        let (code, records) = await DNSAnswerer(resolver: resolver).answer(Self.query("nx.example"))
        #expect(code == .nameError)
        #expect(records.isEmpty)
        // The A lookup, then every probe but A.
        #expect(Set(resolver.asked.map(\.type)) == Set(DNSRecordType.existenceProbes))
        #expect(resolver.asked.count == DNSRecordType.existenceProbes.count)
    }

    @Test func answersNODATAForANameWithAnotherType() async {
        let resolver = FakeResolver()
        resolver.set(
            "github.com", DNSRecordType.a,
            DNSLookup(.found, records: [Self.record("github.com", DNSRecordType.a, [1, 2, 3, 4])]))
        let (code, records) = await DNSAnswerer(resolver: resolver).answer(
            Self.query("github.com", DNSRecordType.aaaa))
        #expect(code == .noError)
        #expect(records.isEmpty)
    }

    @Test func answersNODATAWithoutEvidenceThatTheNameDoesNotExist() async {
        let resolver = FakeResolver()
        resolver.set("unsure.example", DNSRecordType.txt, DNSLookup(.failed))
        let (code, _) = await DNSAnswerer(resolver: resolver).answer(
            Self.query("unsure.example", DNSRecordType.aaaa))
        #expect(code == .noError)
    }

    @Test func answersNXDOMAINWhenTheMacSaysTheNameDoesNotExist() async {
        let resolver = FakeResolver()
        resolver.set("gone.example", DNSRecordType.mx, DNSLookup(.noSuchName))
        let (code, _) = await DNSAnswerer(resolver: resolver).answer(
            Self.query("gone.example", DNSRecordType.mx))
        #expect(code == .nameError)
        #expect(resolver.asked.count == 1)
    }

    @Test func probesWhereTheCNAMEChainEnds() async {
        let resolver = FakeResolver()
        resolver.set(
            "alias.example", DNSRecordType.aaaa,
            DNSLookup(.noSuchRecord, records: [Self.cname("alias.example", "target.example")]))
        resolver.set(
            "target.example", DNSRecordType.a,
            DNSLookup(
                .found, records: [Self.record("target.example", DNSRecordType.a, [1, 1, 1, 1])]))
        let (code, records) = await DNSAnswerer(resolver: resolver).answer(
            Self.query("alias.example", DNSRecordType.aaaa))
        #expect(code == .noError)
        #expect(records == [Self.cname("alias.example", "target.example")])
        #expect(resolver.asked.dropFirst().allSatisfy { $0.name == Self.name("target.example") })
    }

    @Test func answersSERVFAILWhenTheMacDoesNotAnswer() async {
        let resolver = FakeResolver()
        resolver.set("broken.example", DNSRecordType.a, DNSLookup(.failed))
        let (code, _) = await DNSAnswerer(resolver: resolver).answer(Self.query("broken.example"))
        #expect(code == .serverFailure)
    }

    @Test func answersSERVFAILOrNODATAWithoutRoomForLookups() async {
        let resolver = FakeResolver(hangs: true)
        resolver.set("x.example", DNSRecordType.a, DNSLookup(.noSuchRecord))
        let none = DNSAnswerer(resolver: resolver, maximumLookups: 0)
        #expect(await none.answer(Self.query("x.example")).code == .serverFailure)
        // Room for one lookup at a time: the first probe waits, the others find no room, and
        // without their evidence the name is not called missing.
        let one = DNSAnswerer(resolver: resolver, maximumLookups: 1)
        #expect(await one.answer(Self.query("x.example")).code == .noError)
    }

    @Test func triesTheMacsSearchDomainsForASingleLabel() async {
        let resolver = FakeResolver()
        resolver.setSearchDomains(["first.example", "corp.example"])
        let a = Self.record("build.corp.example", DNSRecordType.a, [10, 1, 2, 3], ttl: 30)
        resolver.set("build.corp.example", DNSRecordType.a, DNSLookup(.found, records: [a]))
        let (code, records) = await DNSAnswerer(resolver: resolver).answer(Self.query("build"))
        #expect(code == .noError)
        #expect(
            records == [
                DNSRecord(
                    name: Self.name("build"), type: DNSRecordType.cname, timeToLive: 30,
                    data: Self.name("build.corp.example").wire),
                a,
            ])
        #expect(
            resolver.asked.prefix(2).map(\.name) == [
                Self.name("build.first.example"), Self.name("build.corp.example"),
            ])
    }

    @Test func looksASingleLabelUpAsItIsOtherwise() async {
        let resolver = FakeResolver()
        resolver.setSearchDomains(["corp.example"])
        _ = await DNSAnswerer(resolver: resolver).answer(Self.query("com", DNSRecordType.mx))
        #expect(
            resolver.asked.first == FakeResolver.Key(name: Self.name("com"), type: DNSRecordType.mx)
        )
        let resolver2 = FakeResolver()
        resolver2.setSearchDomains(["corp.example"])
        _ = await DNSAnswerer(resolver: resolver2).answer(Self.query("nowhere"))
        #expect(
            resolver2.asked.map(\.name).prefix(2) == [
                Self.name("nowhere.corp.example"), Self.name("nowhere"),
            ])
    }

    @Test func asksTheMacNothingForWhatItAnswersItself() async {
        let resolver = FakeResolver()
        let answerer = DNSAnswerer(resolver: resolver)
        #expect(await answerer.answer(Self.query("example.com", 257)).code == .notImplemented)
        #expect(await answerer.answer(Self.query("printer.local")).code == .refused)
        #expect(resolver.asked.isEmpty)
    }
}
