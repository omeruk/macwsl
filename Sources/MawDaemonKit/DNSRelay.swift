#if os(macOS)
    import MawCore
    import MawProtocol
    import os

    /// One running distribution's DNS (docs/decisions/0024-dns-through-the-mac.md): it keeps
    /// the machine's DNS channel open and answers each query that the agent passes on it with
    /// the Mac's resolver. It ends with its machine.
    ///
    /// Every query is checked again here, since it comes from the guest: a query that is not
    /// well formed is answered FORMERR, and one beyond `maximumInFlight` or beyond the rate
    /// REFUSED. Nothing from the guest chooses a server: the daemon only asks the Mac's
    /// resolver. Names are never logged; a line every `reportInterval` counts the answers.
    public actor DNSRelay {
        public struct Environment: Sendable {
            /// Opens a connection that the agent dialed, positioned before its version exchange.
            public var openChannel: @Sendable () async throws(MawError) -> OwnedDescriptor
            public var resolver: any SystemDNSResolving
            public var reopenDelay: Duration
            public var maximumInFlight: Int
            /// Queries per second, on average, and in a burst.
            public var rate: Int
            public var burst: Int
            /// A query not answered within this is answered SERVFAIL, before the agent's own
            /// deadline of 5 seconds.
            public var answerTimeout: Duration
            public var reportInterval: Duration

            public init(
                openChannel: @escaping @Sendable () async throws(MawError) -> OwnedDescriptor,
                resolver: any SystemDNSResolving, reopenDelay: Duration = .seconds(1),
                maximumInFlight: Int = AgentProtocol.maximumDNSQueriesInFlight,
                rate: Int = 500, burst: Int = 1_000, answerTimeout: Duration = .seconds(4),
                reportInterval: Duration = .seconds(60)
            ) {
                self.openChannel = openChannel
                self.resolver = resolver
                self.reopenDelay = reopenDelay
                self.maximumInFlight = maximumInFlight
                self.rate = rate
                self.burst = burst
                self.answerTimeout = answerTimeout
                self.reportInterval = reportInterval
            }
        }

        /// The answers given, by kind, for the log line.
        struct Counts: Equatable {
            var records = 0
            var noData = 0
            var nameError = 0
            var serverFailure = 0
            var other = 0
            var total: Int { records + noData + nameError + serverFailure + other }

            mutating func count(_ response: [UInt8]) {
                switch DNSResponse.code(of: response) {
                case .noError:
                    if DNSResponse.answerCount(of: response) > 0 {
                        records += 1
                    } else {
                        noData += 1
                    }
                case .nameError: nameError += 1
                case .serverFailure: serverFailure += 1
                default: other += 1
                }
            }

            /// `dns: answered 42 queries in 60 s: 30 with records, 8 NODATA, 3 NXDOMAIN,
            /// 1 SERVFAIL, 0 refused, not supported, or malformed`.
            func line(seconds: Int64, stopping: Bool) -> String {
                "dns: answered \(total) \(total == 1 ? "query" : "queries") in "
                    + (stopping
                        ? "the last \(seconds) s before the machine stopped" : "\(seconds) s")
                    + ": \(records) with records, \(noData) NODATA, \(nameError) NXDOMAIN, "
                    + "\(serverFailure) SERVFAIL, \(other) refused, not supported, or malformed"
            }
        }

        static let channelOpenTimeout = Duration.seconds(5)

        public nonisolated let machine: MachineID
        private let environment: Environment
        private let answerer: DNSAnswerer
        private let log: DaemonLog
        private let console: @Sendable (String) -> Void
        private var isStopped = false
        private var link: ChannelLink?
        private var channelTask: Task<Void, Never>?
        private var reportTask: Task<Void, Never>?
        private var inFlight = 0
        private var tokens: Double
        private var lastRefill = ContinuousClock.now
        private var counts = Counts()
        private var countingSince = ContinuousClock.now

        public init(
            machine: MachineID, environment: Environment, log: DaemonLog,
            console: @escaping @Sendable (String) -> Void
        ) {
            self.machine = machine
            self.environment = environment
            self.log = log
            self.console = console
            answerer = DNSAnswerer(resolver: environment.resolver)
            tokens = Double(environment.burst)
        }

        /// The queries in flight; for tests.
        var queriesInFlight: Int { inFlight }

        public func start() {
            guard !isStopped, channelTask == nil else { return }
            channelTask = Task { [weak self] in await self?.keepChannelOpen() }
            reportTask = Task { [weak self, interval = environment.reportInterval] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    await self?.report(stopping: false)
                }
            }
        }

        /// Closes the channel and writes the last count.
        public func stop() {
            guard !isStopped else { return }
            isStopped = true
            channelTask?.cancel()
            reportTask?.cancel()
            link?.close()
            link = nil
            report(stopping: true)
        }

        private func report(stopping: Bool) {
            let seconds = (ContinuousClock.now - countingSince).components.seconds
            countingSince = .now
            guard counts.total > 0 else { return }
            let line = counts.line(seconds: max(1, seconds), stopping: stopping)
            counts = Counts()
            log.notice("\(machine): \(line)")
            console(line)
        }

        // MARK: The channel

        private func keepChannelOpen() async {
            while !isStopped && !Task.isCancelled {
                if let ending = await runChannel() {
                    log.notice("\(machine): the DNS channel ended: \(ending)")
                    console("dns: the DNS channel ended: \(ending)")
                }
                guard !isStopped else { return }
                try? await Task.sleep(for: environment.reopenDelay)
            }
        }

        private func runChannel() async -> String? {
            let descriptor: OwnedDescriptor
            do {
                descriptor = try await environment.openChannel()
            } catch {
                return isStopped ? nil : "it could not be opened: \(error.description)"
            }
            let connection: FrameConnection
            do {
                connection = try await runOnDedicatedThread {
                    () throws(ConnectionError) -> FrameConnection in
                    let connection = try FrameConnection(descriptor)
                    let version = try connection.exchangeVersions(
                        until: .now + Self.channelOpenTimeout, thenSending: [.control(.dns)])
                    guard version == ProtocolVersion.current else {
                        throw .versionMismatch(local: ProtocolVersion.current, remote: version)
                    }
                    return connection
                }
            } catch {
                descriptor.close()
                return isStopped ? nil : "it could not be opened: \(error)"
            }
            let (endings, endingContinuation) = AsyncStream.makeStream(of: ChannelLink.Ending.self)
            let link: ChannelLink
            do {
                link = try ChannelLink(connection: connection) { ending in
                    endingContinuation.yield(ending)
                    endingContinuation.finish()
                }
            } catch {
                connection.descriptor.close()
                return "it could not be served: \(error)"
            }
            guard !isStopped else {
                link.close()
                return nil
            }
            self.link = link
            for await frame in link.frames {
                guard frame.type == .dnsQuery, let query = try? frame.dnsMessage() else {
                    // The agent refused the channel, or broke the protocol: nothing after it is
                    // acted on.
                    link.close()
                    let reason =
                        (try? frame.controlMessage()).map { message -> String in
                            if case .error(let error) = message {
                                return "the agent refused it: \(error.code.rawValue)"
                            }
                            return "unexpected \(message.name)"
                        } ?? "a frame of type 0x\(String(frame.type.rawValue, radix: 16))"
                    log.notice("\(machine): closing the DNS channel: \(reason)")
                    break
                }
                received(query.message, tag: query.tag, on: link)
            }
            if self.link === link {
                self.link = nil
            }
            var ending = ChannelLink.Ending.closed
            for await value in endings {
                ending = value
            }
            if isStopped { return nil }
            switch ending {
            case .closed: return "it was closed"
            case .failed(let reason): return reason
            }
        }

        // MARK: Queries

        /// Answers one query from the agent.
        func received(_ message: [UInt8], tag: UInt32, on link: ChannelLink) {
            let query: DNSQuery
            switch DNSQuery.parse(message) {
            case .failure(let error):
                // The agent passes on only queries that it parsed; answer what can be answered.
                if let code = error.responseCode,
                    let response = DNSResponse.error(code, toQuery: message)
                {
                    send(response, tag: tag, on: link)
                }
                return
            case .success(let parsed):
                query = parsed
            }
            refill()
            guard tokens >= 1, inFlight < environment.maximumInFlight else {
                send(DNSResponse.encode(query, code: .refused), tag: tag, on: link)
                return
            }
            tokens -= 1
            inFlight += 1
            let answerer = self.answerer
            let timeout = environment.answerTimeout
            Task { [weak self] in
                let response = await Self.respond(to: query, with: answerer, within: timeout)
                await self?.answered(response, tag: tag, on: link)
            }
        }

        private func answered(_ response: [UInt8], tag: UInt32, on link: ChannelLink) {
            inFlight -= 1
            send(response, tag: tag, on: link)
        }

        private func send(_ response: [UInt8], tag: UInt32, on link: ChannelLink) {
            counts.count(response)
            link.send(.dns(.dnsAnswer, tag: tag, message: response))
        }

        private func refill() {
            let now = ContinuousClock.now
            let elapsed = now - lastRefill
            lastRefill = now
            let seconds =
                Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            tokens = min(Double(environment.burst), tokens + seconds * Double(environment.rate))
        }

        /// The response to `query`, or SERVFAIL when the answer does not come within `timeout`
        /// or does not fit in a DNS message.
        static func respond(
            to query: DNSQuery, with answerer: DNSAnswerer, within timeout: Duration
        ) async -> [UInt8] {
            let answer = await withTaskGroup(of: (DNSResponseCode, [DNSRecord])?.self) { group in
                group.addTask { await answerer.answer(query) }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let (code, records) = answer else {
                return DNSResponse.encode(query, code: .serverFailure)
            }
            let response = DNSResponse.encode(query, code: code, answers: records)
            return response.count <= DNSResponse.maximumSize
                ? response : DNSResponse.encode(query, code: .serverFailure)
        }
    }
#endif
