#if os(macOS)
    import MawProtocol
    import os

    /// What the Mac's resolver said about one name and type.
    public struct DNSLookup: Equatable, Sendable {
        public enum Outcome: Equatable, Sendable {
            /// Records of the type asked for.
            case found
            /// No record of that type; whether the name exists is not known (`dns_sd.h`
            /// reports both as `kDNSServiceErr_NoSuchRecord`).
            case noSuchRecord
            /// The name does not exist.
            case noSuchName
            /// No answer: a timeout, or the resolver failed.
            case failed
        }

        public var outcome: Outcome
        /// The records received, the CNAMEs on the way included, in the order they came.
        public var records: [DNSRecord]

        public init(_ outcome: Outcome, records: [DNSRecord] = []) {
            self.outcome = outcome
            self.records = records
        }
    }

    /// The Mac's system resolver, behind a protocol so that tests answer without the network.
    public protocol SystemDNSResolving: Sendable {
        /// Looks `name` up for `type`. Cancelling the task ends the lookup.
        func lookup(_ name: DNSName, type: UInt16) async -> DNSLookup
        /// The Mac's search domains now, in order.
        func searchDomains() -> [DNSName]
    }

    /// Answers one distribution's queries with the Mac's resolver
    /// (docs/decisions/0024-dns-through-the-mac.md).
    ///
    /// - **NXDOMAIN and NODATA.** When the Mac reports no record of the type asked for, the same
    ///   name is looked up for `DNSRecordType.existenceProbes` at once. NXDOMAIN needs evidence:
    ///   every probe without a record. Any record, a failed probe, or no room for the probes
    ///   gives NODATA, because an NXDOMAIN for a name that exists would hide its other records.
    /// - **Single-label names.** For A and AAAA, the Mac's search domains are tried in order;
    ///   the first name that has records is answered as a CNAME from the single label to it,
    ///   followed by its records. Otherwise, and for other types, the name is looked up as it is.
    public final class DNSAnswerer: Sendable {
        /// The Mac's search domains that a single-label name is tried with.
        public static let maximumSearchDomains = 6
        /// Records kept from one lookup.
        public static let maximumRecords = 256
        /// Lookups of the Mac's resolver in flight for one distribution, the probes included.
        public static let maximumLookups = 256
        /// How long a CNAME chain may be followed when the records are put in order.
        static let maximumChain = 16

        private let resolver: any SystemDNSResolving
        private let lookups = OSAllocatedUnfairLock(initialState: 0)
        private let maximumLookups: Int

        public init(resolver: any SystemDNSResolving, maximumLookups: Int = maximumLookups) {
            self.resolver = resolver
            self.maximumLookups = maximumLookups
        }

        /// The code and the answer records for `query`.
        public func answer(_ query: DNSQuery) async -> (code: DNSResponseCode, records: [DNSRecord])
        {
            if case .answer(let code) = DNSQueryPolicy.verdict(for: query) {
                return (code, [])
            }
            if query.name.isSingleLabel,
                query.type == DNSRecordType.a || query.type == DNSRecordType.aaaa
            {
                for domain in resolver.searchDomains().prefix(Self.maximumSearchDomains) {
                    guard let candidate = query.name.appending(domain),
                        let lookup = await lookup(candidate, type: query.type),
                        lookup.outcome == .found
                    else { continue }
                    let records = Self.ordered(lookup.records, from: candidate)
                    let alias = DNSRecord(
                        name: query.name, type: DNSRecordType.cname,
                        timeToLive: records.map(\.timeToLive).min() ?? 0, data: candidate.wire)
                    return (.noError, [alias] + records)
                }
            }
            guard let lookup = await lookup(query.name, type: query.type) else {
                return (.serverFailure, [])
            }
            let records = Self.ordered(lookup.records, from: query.name)
            switch lookup.outcome {
            case .found:
                return (.noError, records)
            case .noSuchName:
                return (.nameError, records)
            case .failed:
                return (.serverFailure, [])
            case .noSuchRecord:
                let end = Self.chainEnd(records, from: query.name)
                return (await exists(end, besides: query.type) ? .noError : .nameError, records)
            }
        }

        /// Whether `name` exists: whether a probe of another type finds a record.
        private func exists(_ name: DNSName, besides type: UInt16) async -> Bool {
            let types = DNSRecordType.existenceProbes.filter { $0 != type }
            return await withTaskGroup(of: DNSLookup.Outcome?.self) { group in
                for probe in types {
                    group.addTask { await self.lookup(name, type: probe)?.outcome }
                }
                var evidence = true
                for await outcome in group {
                    switch outcome {
                    case .found, .failed, nil:
                        group.cancelAll()
                        return true
                    case .noSuchName:
                        group.cancelAll()
                        return false
                    case .noSuchRecord:
                        evidence = false
                    }
                }
                return evidence
            }
        }

        /// A lookup, or `nil` when `maximumLookups` are in flight.
        private func lookup(_ name: DNSName, type: UInt16) async -> DNSLookup? {
            let admitted = lookups.withLock { count in
                guard count < maximumLookups else { return false }
                count += 1
                return true
            }
            guard admitted else { return nil }
            defer { lookups.withLock { $0 -= 1 } }
            var result = await resolver.lookup(name, type: type)
            result.records = Array(result.records.prefix(Self.maximumRecords))
            return result
        }

        /// The CNAME chain from `name` first, in order, then the other records.
        static func ordered(_ records: [DNSRecord], from name: DNSName) -> [DNSRecord] {
            var remaining = records
            var chain: [DNSRecord] = []
            var current = name
            for _ in 0..<maximumChain {
                guard
                    let index = remaining.firstIndex(where: {
                        $0.type == DNSRecordType.cname && $0.name == current
                    }),
                    let target = remaining[index].canonicalName
                else { break }
                chain.append(remaining.remove(at: index))
                current = target
            }
            return chain + remaining
        }

        /// Where the CNAME chain from `name` leads.
        static func chainEnd(_ records: [DNSRecord], from name: DNSName) -> DNSName {
            var current = name
            for _ in 0..<maximumChain {
                guard
                    let target = records.first(where: {
                        $0.type == DNSRecordType.cname && $0.name == current
                    })?.canonicalName
                else { break }
                current = target
            }
            return current
        }
    }
#endif
