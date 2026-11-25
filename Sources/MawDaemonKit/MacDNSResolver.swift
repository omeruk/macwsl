#if os(macOS)
    import Dispatch
    import Foundation
    import MawProtocol
    import SystemConfiguration
    import dnssd

    /// The Mac's system resolver through `DNSServiceQueryRecord` (`dns_sd.h`), which asks
    /// mDNSResponder and so applies the Mac's scoped resolvers, VPNs, and DNS settings, with
    /// its cache (docs/decisions/0024-dns-through-the-mac.md). Each lookup has a connection of
    /// its own: on one shared connection, about one in fifty sets of concurrent lookups got no
    /// reply until every one of them reached its deadline.
    ///
    /// `dns_sd.h` delivers its callbacks on a dispatch queue (`DNSServiceSetDispatchQueue`);
    /// every use of a `DNSServiceRef` happens on that queue, and the lookups reach `async` code
    /// through continuations. A lookup only queries: nothing here registers, reconfirms, or
    /// flushes a record.
    public final class MacDNSResolver: SystemDNSResolving, @unchecked Sendable {
        /// How long a lookup may take before it fails; below the daemon's deadline for a query,
        /// so that a probe that the daemon waits for ends first.
        public static let lookupTimeout = DispatchTimeInterval.milliseconds(3_500)
        static let flags = DNSServiceFlags(
            kDNSServiceFlagsReturnIntermediates | kDNSServiceFlagsTimeout)

        private let queue = DispatchQueue(label: "dev.maw.mawd.dns")
        // On `queue` only.
        private var queries: [ObjectIdentifier: Query] = [:]
        private let store = SCDynamicStoreCreate(nil, "mawd" as CFString, nil, nil)

        public init() {}

        public func lookup(_ name: DNSName, type: UInt16) async -> DNSLookup {
            let query = Query(type: type)
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    queue.async { [self] in
                        start(query, name: name, continuation: continuation)
                    }
                }
            } onCancel: {
                queue.async { [self] in finish(query, .failed) }
            }
        }

        public func searchDomains() -> [DNSName] {
            guard let store,
                let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString)
                    as? [String: Any],
                let domains = value["SearchDomains"] as? [String]
            else { return [] }
            return domains.compactMap { DNSName(presentation: $0) }.filter { !$0.labels.isEmpty }
        }

        // MARK: On the queue

        private func start(
            _ query: Query, name: DNSName, continuation: CheckedContinuation<DNSLookup, Never>
        ) {
            // A task cancelled before the lookup began has already finished the query, with no
            // continuation to resume.
            guard !query.isFinished else {
                continuation.resume(returning: DNSLookup(.failed))
                return
            }
            query.continuation = continuation
            query.resolver = self
            var reference: DNSServiceRef?
            let context = Unmanaged.passUnretained(query).toOpaque()
            let error = Int(
                queryRecord(&reference, Self.flags, name.presentation, query.type, context))
            guard error == kDNSServiceErr_NoError, let reference else {
                finish(query, .failed)
                return
            }
            DNSServiceSetDispatchQueue(reference, queue)
            query.reference = reference
            queries[ObjectIdentifier(query)] = query
            queue.asyncAfter(deadline: .now() + Self.lookupTimeout) { [self, weak query] in
                if let query { finish(query, .failed) }
            }
        }

        fileprivate func receive(
            _ query: Query, flags: DNSServiceFlags, error: DNSServiceErrorType,
            name: UnsafePointer<CChar>?, type: UInt16, data: [UInt8], timeToLive: UInt32
        ) {
            guard !query.isFinished else { return }
            switch Int(error) {
            case kDNSServiceErr_NoError:
                guard flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let name,
                    let owner = DNSName(presentation: String(cString: name))
                else { return }
                if query.records.count < DNSAnswerer.maximumRecords {
                    query.records.append(
                        DNSRecord(name: owner, type: type, timeToLive: timeToLive, data: data))
                }
                if type == query.type,
                    flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0
                {
                    finish(query, .found)
                }
            case kDNSServiceErr_NoSuchRecord:
                finish(query, .noSuchRecord)
            case kDNSServiceErr_NoSuchName:
                finish(query, .noSuchName)
            default:
                // kDNSServiceErr_ServiceNotRunning among them: mDNSResponder restarted, and the
                // next lookup connects again.
                finish(query, .failed)
            }
        }

        private func finish(_ query: Query, _ outcome: DNSLookup.Outcome) {
            guard !query.isFinished else { return }
            query.isFinished = true
            queries[ObjectIdentifier(query)] = nil
            if let reference = query.reference {
                DNSServiceRefDeallocate(reference)
                query.reference = nil
            }
            query.continuation?.resume(returning: DNSLookup(outcome, records: query.records))
            query.continuation = nil
        }

        /// One lookup's state; on the queue only.
        fileprivate final class Query: @unchecked Sendable {
            let type: UInt16
            var reference: DNSServiceRef?
            var continuation: CheckedContinuation<DNSLookup, Never>?
            var records: [DNSRecord] = []
            var isFinished = false
            weak var resolver: MacDNSResolver?

            init(type: UInt16) {
                self.type = type
            }
        }
    }

    /// `DNSServiceQueryRecord` on every interface, class IN, with the callback that hands each
    /// reply to its query.
    private func queryRecord(
        _ reference: inout DNSServiceRef?, _ flags: DNSServiceFlags, _ name: String,
        _ type: UInt16, _ context: UnsafeMutableRawPointer
    ) -> DNSServiceErrorType {
        DNSServiceQueryRecord(
            &reference, flags, 0, name, type, UInt16(kDNSServiceClass_IN),
            { _, flags, _, error, name, type, _, length, data, timeToLive, context in
                guard let context else { return }
                let query = Unmanaged<MacDNSResolver.Query>.fromOpaque(context)
                    .takeUnretainedValue()
                let bytes =
                    data.map { Array(UnsafeRawBufferPointer(start: $0, count: Int(length))) }
                    ?? []
                query.resolver?.receive(
                    query, flags: flags, error: error, name: name, type: type, data: bytes,
                    timeToLive: timeToLive)
            }, context)
    }
#endif
