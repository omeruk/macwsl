import CMawSystem
import Logging
import MawCore
import MawProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// What the DNS server needs from the guest. `guest()` is the real one; tests supply their own
/// address and port.
public struct DNSEnvironment: Sendable {
    /// The IPv4 address to answer on, 4 bytes in network order.
    public var address: [UInt8]
    public var port: UInt16
    /// Makes `address` a local address before the sockets bind to it.
    public var prepareAddress: @Sendable () throws(SystemError) -> Void
    /// How long a query waits for the DNS channel to open before it is answered SERVFAIL.
    public var holdTimeout: Duration
    /// How long a query passed to the host waits for its answer before it is answered SERVFAIL.
    public var answerTimeout: Duration
    /// Queries that wait for the channel.
    public var maximumHeld: Int
    /// Queries passed to the host or waiting for the channel.
    public var maximumInFlight: Int
    public var maximumTCPConnections: Int
    /// A TCP connection without a query in flight and without input for this long is closed.
    public var tcpIdleTimeout: Duration

    public init(
        address: [UInt8] = AgentProtocol.dnsAddress, port: UInt16 = AgentProtocol.dnsPort,
        prepareAddress: @escaping @Sendable () throws(SystemError) -> Void = {},
        holdTimeout: Duration = .milliseconds(500), answerTimeout: Duration = .seconds(5),
        maximumHeld: Int = 64,
        maximumInFlight: Int = AgentProtocol.maximumDNSQueriesInFlight,
        maximumTCPConnections: Int = 16, tcpIdleTimeout: Duration = .seconds(10)
    ) {
        self.address = address
        self.port = port
        self.prepareAddress = prepareAddress
        self.holdTimeout = holdTimeout
        self.answerTimeout = answerTimeout
        self.maximumHeld = maximumHeld
        self.maximumInFlight = maximumInFlight
        self.maximumTCPConnections = maximumTCPConnections
        self.tcpIdleTimeout = tcpIdleTimeout
    }

    /// The guest's: `AgentProtocol.dnsAddress` on the dummy link `AgentProtocol.dnsLink`.
    public static func guest() -> DNSEnvironment {
        DNSEnvironment(prepareAddress: { () throws(SystemError) in
            let code = AgentProtocol.dnsAddress.withUnsafeBufferPointer {
                maw_add_dummy_link_address(AgentProtocol.dnsLink, $0.baseAddress!)
            }
            guard code == 0 else {
                throw SystemError(
                    "adding \(AgentProtocol.dnsAddressText) on the link \(AgentProtocol.dnsLink)",
                    code: code)
            }
        })
    }
}

/// The agent's DNS server (docs/decisions/0024-dns-through-the-mac.md): systemd-resolved, and
/// any program or container in the guest, sends queries to it on UDP and TCP port 53, and it
/// passes each one to the host over the machine's DNS channel (docs/protocol.md, "DNS").
///
/// It runs from the agent's start, before the channel opens, so that the first query of a
/// boot waits for the channel instead of being lost. One thread owns every socket and the
/// channel; `attach(_:)` hands it a channel and returns when that channel has ended.
///
/// What it answers itself, without the host: FORMERR to a malformed query or one larger than
/// 512 bytes, NOTIMP to an opcode or a type that it does not pass on, REFUSED to a `.local`
/// or link-local reverse name and beyond `maximumInFlight`, and SERVFAIL to a query that the
/// channel did not take within `holdTimeout` or that the host did not answer within
/// `answerTimeout`. It never asks another server.
public final class DNSServer: @unchecked Sendable {
    private enum Origin {
        case datagram(peer: sockaddr_storage, length: socklen_t)
        case stream(connection: Int)
    }

    private struct Pending {
        var origin: Origin
        var query: DNSQuery
        var deadline: ContinuousClock.Instant
        var sent: Bool
        var datagramKey: [UInt8]?
    }

    private struct StreamClient {
        var descriptor: OwnedDescriptor
        var input: [UInt8] = []
        var output = ByteBuffer()
        var inFlight = 0
        var lastActivity: ContinuousClock.Instant
        var isAtEndOfInput = false
    }

    /// Queries in flight on one TCP connection; beyond them, its input waits.
    static let maximumStreamQueries = 16
    /// Output waiting on one TCP connection beyond which its input waits.
    static let maximumStreamOutput = 256 << 10

    private let environment: DNSEnvironment
    private let logger: Logger
    private let lock = ConditionLock()
    private let wake: (read: OwnedDescriptor, write: OwnedDescriptor)
    // Shared with `attach(_:)`, under `lock`.
    private var offered: FrameConnection?
    private var attachedEnded = false
    private var attachFailure: ConnectionError?
    // The thread's own.
    private var datagramSocket: OwnedDescriptor?
    private var streamListener: OwnedDescriptor?
    private var channel: FrameConnection?
    private var clients: [Int: StreamClient] = [:]
    private var nextClient = 0
    private var pending: [UInt32: Pending] = [:]
    private var datagramTags: [[UInt8]: UInt32] = [:]
    private var nextTag: UInt32 = 1
    private var nextBindAttempt = ContinuousClock.now
    private var bindFailureReport: ContinuousClock.Instant?
    private var failedWithoutChannel = 0
    private var failureReport = ContinuousClock.now

    public init(environment: DNSEnvironment, logger: Logger) throws(SystemError) {
        self.environment = environment
        self.logger = logger
        var pipe: [Int32] = [-1, -1]
        let code = maw_pipe(&pipe)
        guard code == 0 else { throw SystemError("pipe", code: code) }
        wake = (OwnedDescriptor(pipe[0]), OwnedDescriptor(pipe[1]))
        _ = maw_set_nonblocking(pipe[0])
        _ = maw_set_nonblocking(pipe[1])
    }

    /// Starts the server's thread. Returns false if it could not start.
    public func start() -> Bool {
        startDetachedThread { [self] in run() }
    }

    /// Whether the server answers on its address now; for tests.
    public var isListening: Bool {
        lock.withLock { listening }
    }
    private var listening = false

    /// Serves `connection` as the DNS channel until it ends, and then returns, or throws why
    /// it ended. Queries that waited for a channel are sent on it at once.
    public func attach(_ connection: FrameConnection) throws(ConnectionError) {
        let failure = lock.withLock { () -> ConnectionError? in
            offered = connection
            attachedEnded = false
            attachFailure = nil
            signal()
            while !attachedEnded {
                lock.wait()
            }
            return attachFailure
        }
        if let failure {
            throw failure
        }
    }

    private func signal() {
        var byte: UInt8 = 1
        _ = write(wake.write.rawValue, &byte, 1)
    }

    // MARK: The thread

    private func run() {
        while true {
            let now = ContinuousClock.now
            if datagramSocket == nil, now >= nextBindAttempt {
                bind()
            }
            if let connection = lock.withLock({ () -> FrameConnection? in
                defer { offered = nil }
                return offered
            }) {
                open(connection)
            }
            expire(now: now)
            flushChannel()

            var requests: [pollfd] = [
                pollfd(fd: wake.read.rawValue, events: Int16(POLLIN), revents: 0)
            ]
            if let datagramSocket {
                requests.append(
                    pollfd(fd: datagramSocket.rawValue, events: Int16(POLLIN), revents: 0))
            }
            if let streamListener {
                requests.append(
                    pollfd(fd: streamListener.rawValue, events: Int16(POLLIN), revents: 0))
            }
            if let channel {
                requests.append(
                    pollfd(
                        fd: channel.rawDescriptor,
                        events: Int16(POLLIN)
                            | (channel.pendingOutputCount > 0 ? Int16(POLLOUT) : 0),
                        revents: 0))
            }
            let clientIDs = Array(clients.keys)
            for id in clientIDs {
                let client = clients[id]!
                var events: Int16 = 0
                if !client.isAtEndOfInput, client.inFlight < Self.maximumStreamQueries,
                    client.output.count < Self.maximumStreamOutput
                {
                    events |= Int16(POLLIN)
                }
                if client.output.count > 0 {
                    events |= Int16(POLLOUT)
                }
                // poll reports POLLHUP and POLLERR without being asked, so a reset connection
                // that waits only for its answers would wake the loop at once, again and again;
                // poll skips a negative descriptor.
                requests.append(
                    pollfd(
                        fd: events == 0 ? -1 : client.descriptor.rawValue, events: events,
                        revents: 0))
            }
            _ = try? pollDescriptors(&requests, timeout: pollTimeout(until: nextDeadline()))

            var index = 0
            if requests[index].revents != 0 {
                var bytes = [UInt8](repeating: 0, count: 64)
                while read(wake.read.rawValue, &bytes, bytes.count) > 0 {}
            }
            index += 1
            if datagramSocket != nil {
                if requests[index].revents != 0 { receiveDatagrams() }
                index += 1
            }
            if streamListener != nil {
                if requests[index].revents != 0 { acceptClients() }
                index += 1
            }
            if channel != nil {
                if requests[index].revents != 0 { receiveFromChannel() }
                index += 1
            }
            for id in clientIDs {
                if requests[index].revents != 0 {
                    serviceClient(id, events: requests[index].revents)
                }
                index += 1
            }
        }
    }

    /// Prepares the address and binds both sockets; on failure, tries again in a second.
    private func bind() {
        do throws(SystemError) {
            try environment.prepareAddress()
            var datagram: Int32 = -1
            var code = environment.address.withUnsafeBufferPointer {
                maw_inet4_bind(0, $0.baseAddress!, environment.port, 0, &datagram)
            }
            guard code == 0 else { throw SystemError("binding the UDP socket", code: code) }
            let datagramDescriptor = OwnedDescriptor(datagram)
            var stream: Int32 = -1
            code = environment.address.withUnsafeBufferPointer {
                maw_inet4_bind(1, $0.baseAddress!, environment.port, 64, &stream)
            }
            guard code == 0 else {
                datagramDescriptor.close()
                throw SystemError("binding the TCP socket", code: code)
            }
            datagramSocket = datagramDescriptor
            streamListener = OwnedDescriptor(stream)
            lock.withLock { listening = true }
            logger.info("dns: answering on \(addressText):\(environment.port)")
        } catch {
            // The first failure, and then one a minute.
            if bindFailureReport.map({ $0 <= .now }) ?? true {
                logger.warning("dns: cannot answer on \(addressText): \(error); trying again")
                bindFailureReport = .now + .seconds(60)
            }
            nextBindAttempt = .now + .seconds(1)
        }
    }

    private var addressText: String {
        environment.address.map(String.init).joined(separator: ".")
    }

    private func nextDeadline() -> ContinuousClock.Instant {
        var deadline = ContinuousClock.now + .seconds(1)
        for entry in pending.values where entry.deadline < deadline {
            deadline = entry.deadline
        }
        return deadline
    }

    // MARK: The channel

    private func open(_ connection: FrameConnection) {
        if let channel {
            end(channel, failure: nil)
        }
        channel = connection
        for (tag, entry) in pending where !entry.sent {
            connection.enqueue(.dns(.dnsQuery, tag: tag, message: entry.query.encoded))
            pending[tag]?.sent = true
            pending[tag]?.deadline = .now + environment.answerTimeout
        }
    }

    private func flushChannel() {
        guard let channel else { return }
        do throws(ConnectionError) {
            try channel.flush()
        } catch {
            end(channel, failure: error)
        }
    }

    private func receiveFromChannel() {
        guard let channel else { return }
        do throws(ConnectionError) {
            try channel.receive()
            while let frame = try channel.nextFrame() {
                guard frame.type == .dnsAnswer else {
                    throw .unexpectedMessage(
                        "expected dnsAnswer on the DNS channel, received a frame of type "
                            + "0x\(String(frame.type.rawValue, radix: 16))")
                }
                let (tag, response) = try { () throws(ConnectionError) in
                    do throws(FrameError) { return try frame.dnsMessage() } catch {
                        throw .frame(error)
                    }
                }()
                answer(tag, with: response)
            }
            if channel.isAtEndOfInput {
                end(channel, failure: nil)
            }
        } catch {
            end(channel, failure: error)
        }
    }

    /// Ends the channel: the queries passed on it are answered SERVFAIL, since the host will
    /// not answer them, and `attach(_:)` returns.
    private func end(_ connection: FrameConnection, failure: ConnectionError?) {
        guard channel === connection else { return }
        channel = nil
        for (tag, entry) in pending where entry.sent {
            fail(tag, entry)
        }
        lock.withLock {
            attachedEnded = true
            attachFailure = failure
            lock.broadcast()
        }
    }

    // MARK: Queries

    private func receiveDatagrams() {
        guard let datagramSocket else { return }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        for _ in 0..<64 {
            var peer = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = buffer.withUnsafeMutableBytes {
                maw_datagram_receive(
                    datagramSocket.rawValue, $0.baseAddress, $0.count, &peer, &length)
            }
            guard count >= 0 else { return }
            // A datagram cut off at the buffer is larger than any query accepted, and is still
            // answered FORMERR from its header.
            handle(
                Array(buffer[..<min(count, buffer.count)]),
                from: .datagram(peer: peer, length: length))
        }
    }

    private func handle(_ message: [UInt8], from origin: Origin) {
        let query: DNSQuery
        switch DNSQuery.parse(message) {
        case .failure(let error):
            if let code = error.responseCode,
                let response = DNSResponse.error(code, toQuery: message)
            {
                send(response, to: origin, limit: 512)
            }
            return
        case .success(let parsed):
            query = parsed
        }
        if case .answer(let code) = DNSQueryPolicy.verdict(for: query) {
            reply(DNSResponse.encode(query, code: code), to: query, origin: origin)
            return
        }
        // A resolver that asks again over UDP before the first answer: one query is enough.
        var key: [UInt8]?
        if case .datagram(var peer, let length) = origin {
            key =
                withUnsafeBytes(of: &peer) { Array($0.prefix(Int(length))) } + [
                    UInt8(query.id >> 8), UInt8(query.id & 0xFF),
                ]
            if datagramTags[key!] != nil { return }
        }
        guard pending.count < environment.maximumInFlight,
            channel != nil || pending.values.filter({ !$0.sent }).count < environment.maximumHeld
        else {
            reply(
                DNSResponse.encode(query, code: channel == nil ? .serverFailure : .refused),
                to: query, origin: origin)
            return
        }
        let tag = nextTag
        nextTag = nextTag &+ 1 == 0 ? 1 : nextTag &+ 1
        let sent = channel != nil
        pending[tag] = Pending(
            origin: origin, query: query,
            deadline: .now + (sent ? environment.answerTimeout : environment.holdTimeout),
            sent: sent, datagramKey: key)
        if let key { datagramTags[key] = tag }
        if case .stream(let id) = origin { clients[id]?.inFlight += 1 }
        channel?.enqueue(.dns(.dnsQuery, tag: tag, message: query.encoded))
    }

    private func answer(_ tag: UInt32, with response: [UInt8]) {
        guard let entry = take(tag) else { return }
        guard response.count >= 12, response[0] == UInt8(entry.query.id >> 8),
            response[1] == UInt8(entry.query.id & 0xFF)
        else {
            reply(
                DNSResponse.encode(entry.query, code: .serverFailure), to: entry.query,
                origin: entry.origin)
            return
        }
        reply(response, to: entry.query, origin: entry.origin)
    }

    private func take(_ tag: UInt32) -> Pending? {
        guard let entry = pending.removeValue(forKey: tag) else { return nil }
        if let key = entry.datagramKey { datagramTags[key] = nil }
        if case .stream(let id) = entry.origin { clients[id]?.inFlight -= 1 }
        return entry
    }

    private func fail(_ tag: UInt32, _ entry: Pending) {
        _ = take(tag)
        if !entry.sent || channel == nil {
            failedWithoutChannel += 1
        }
        reply(
            DNSResponse.encode(entry.query, code: .serverFailure), to: entry.query,
            origin: entry.origin)
    }

    private func expire(now: ContinuousClock.Instant) {
        for (tag, entry) in pending where entry.deadline <= now {
            fail(tag, entry)
        }
        for (id, client) in clients
        where client.inFlight == 0 && client.output.count == 0
            && (client.isAtEndOfInput || now - client.lastActivity >= environment.tcpIdleTimeout)
        {
            client.descriptor.close()
            clients[id] = nil
        }
        if failedWithoutChannel > 0, now >= failureReport {
            logger.warning(
                """
                dns: answered \(failedWithoutChannel) queries SERVFAIL because the DNS channel to \
                the host was not open or did not answer in time
                """)
            failedWithoutChannel = 0
            failureReport = now + .seconds(10)
        }
    }

    /// Sends a response to `query`, cut down with the TC bit when it exceeds what UDP may carry.
    private func reply(_ response: [UInt8], to query: DNSQuery, origin: Origin) {
        if case .datagram = origin, response.count > query.maximumUDPResponseSize {
            send(
                DNSResponse.truncated(
                    query, code: DNSResponse.code(of: response) ?? .serverFailure),
                to: origin, limit: query.maximumUDPResponseSize)
        } else {
            send(response, to: origin, limit: DNSResponse.maximumSize)
        }
    }

    private func send(_ response: [UInt8], to origin: Origin, limit: Int) {
        guard response.count <= limit else { return }
        switch origin {
        case .datagram(var peer, let length):
            guard let datagramSocket else { return }
            _ = response.withUnsafeBytes {
                maw_datagram_send(datagramSocket.rawValue, $0.baseAddress, $0.count, &peer, length)
            }
        case .stream(let id):
            guard clients[id] != nil else { return }
            clients[id]!.output.append(contentsOf: [
                UInt8(response.count >> 8), UInt8(response.count & 0xFF),
            ])
            clients[id]!.output.append(contentsOf: response)
            flushClient(id)
        }
    }

    // MARK: TCP

    private func acceptClients() {
        guard let streamListener else { return }
        while true {
            var descriptor: Int32 = -1
            guard maw_tcp_accept(streamListener.rawValue, &descriptor) == 0 else { return }
            guard clients.count < environment.maximumTCPConnections else {
                close(descriptor)
                continue
            }
            _ = maw_set_nonblocking(descriptor)
            clients[nextClient] = StreamClient(
                descriptor: OwnedDescriptor(descriptor), lastActivity: .now)
            nextClient += 1
        }
    }

    private func serviceClient(_ id: Int, events: Int16) {
        if events & Int16(POLLOUT) != 0 {
            flushClient(id)
        }
        guard events & Int16(POLLIN | POLLHUP | POLLERR) != 0, var client = clients[id] else {
            return
        }
        var buffer = [UInt8](repeating: 0, count: 16 << 10)
        let count = buffer.withUnsafeMutableBytes {
            read(client.descriptor.rawValue, $0.baseAddress, $0.count)
        }
        if count <= 0 {
            if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                client.isAtEndOfInput = true
                // Answers still owed to a closed connection have nowhere to go.
                if count < 0 { client.output.removeAll() }
            }
            clients[id] = client
            return
        }
        client.input += buffer[..<count]
        client.lastActivity = .now
        clients[id] = client
        // Each message: a 2-byte length, then the query.
        while let current = clients[id], current.input.count >= 2 {
            let length = Int(current.input[0]) << 8 | Int(current.input[1])
            guard current.input.count >= 2 + length else { break }
            let message = Array(current.input[2..<(2 + length)])
            clients[id]!.input.removeFirst(2 + length)
            handle(message, from: .stream(connection: id))
        }
    }

    private func flushClient(_ id: Int) {
        guard var client = clients[id] else { return }
        while client.output.count > 0 {
            let sent = client.output.withUnsafeBytes {
                maw_send(client.descriptor.rawValue, $0.baseAddress!, $0.count)
            }
            if sent < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    client.output.removeAll()
                    client.isAtEndOfInput = true
                }
                break
            }
            client.output.consume(sent)
        }
        clients[id] = client
    }
}
