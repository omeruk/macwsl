#if os(macOS)
    import Darwin
    import MawCore
    import MawProtocol
    import os

    /// Decides which connections to a machine's dial-back port (`AgentProtocol.dialBackPort`)
    /// become sessions, and hands each accepted one to the session that asked for it.
    ///
    /// A session asks the agent to dial back with a fresh nonce (`expect()`), and waits for the
    /// connection that sends that nonce first (`connection(for:)`). Any process in the guest can
    /// connect to the port, so a connection is checked in two stages:
    ///
    /// 1. `admit(sourcePort:)`, on the virtual machine's queue, before anything is read: it
    ///    refuses a source port of 1024 or above, any connection while no session waits, and
    ///    any connection once as many admitted connections have not yet sent their nonce as
    ///    there are waiting sessions plus `Limits.extraUnauthenticatedConnections`. Each
    ///    waiting session's own dial therefore finds a place, however many open at once.
    /// 2. `authenticate(_:)`, on a thread of its own: it reads exactly the nonce frame, within
    ///    `Limits.nonceReadTimeout`, and never a byte more, so that the session's own bytes stay
    ///    in the socket for the client. A connection whose nonce matches no waiting session is
    ///    closed.
    ///
    /// The source port only filters: a guest process with CAP_NET_BIND_SERVICE, such as root
    /// in a container, can bind such a port too. The nonce is the boundary. Nonces are single
    /// use, expire after `Limits.nonceLifetime`, are compared in constant time, and are never
    /// logged. `state` is guarded by its lock.
    public final class DialBackGate: Sendable {
        public struct Limits: Sendable {
            /// Connections admitted that have not yet sent their nonce, beyond one for each
            /// waiting session.
            public var extraUnauthenticatedConnections = 4
            /// Sessions waiting for their connection: the agent's own connection limit.
            public var pendingRequests = AgentProtocol.maximumConnections
            /// How long a session's nonce stays valid after `expect()`.
            public var nonceLifetime = Duration.seconds(5)
            /// How long an admitted connection may take to send its nonce frame.
            public var nonceReadTimeout = Duration.seconds(2)
            /// Refusals reported per `refusalReportInterval`; the rest are counted.
            public var refusalReports = 5
            public var refusalReportInterval = Duration.seconds(10)

            public init() {}
        }

        /// Why a connection was refused.
        public enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
            /// The source port is 1024 or above, which any guest process can bind.
            case unprivilegedSourcePort(UInt32)
            /// No session is waiting for a connection.
            case noPendingRequest
            /// `limit` admitted connections have not yet sent their nonce: one for each waiting
            /// session, and `Limits.extraUnauthenticatedConnections` more.
            case tooManyUnauthenticated(limit: Int)
            /// The connection did not send a whole nonce frame in time.
            case nonceNotReceived(String)
            /// The connection's first frame is not a well-formed nonce frame.
            case malformedNonceFrame(String)
            /// The nonce belongs to no waiting session: unknown, expired, or already used.
            case unknownNonce
            /// The machine has stopped.
            case closed

            public var description: String {
                switch self {
                case .unprivilegedSourcePort(let port):
                    "source port \(port) is not below 1024"
                case .noPendingRequest:
                    "no session is waiting for a connection"
                case .tooManyUnauthenticated(let limit):
                    "\(limit) connections have not yet sent their nonce"
                case .nonceNotReceived(let reason):
                    "no nonce frame: \(reason)"
                case .malformedNonceFrame(let reason):
                    "the first frame is not a nonce frame: \(reason)"
                case .unknownNonce:
                    "the nonce matches no waiting session"
                case .closed:
                    "the virtual machine has stopped"
                }
            }
        }

        /// A session's claim on the connection that the agent dials with `nonce`.
        public struct Pending: Sendable {
            let id: UInt64
            public let nonce: DialBackNonce
            /// When the nonce expires.
            let expiry: ContinuousClock.Instant
        }

        private struct Entry {
            let id: UInt64
            let nonce: DialBackNonce
            let expiry: ContinuousClock.Instant
            var waiter: CheckedContinuation<OwnedDescriptor?, Never>?
        }

        private struct State {
            var pending: [Entry] = []
            /// Connections that matched before their session waited for them, by entry ID.
            var arrived: [UInt64: OwnedDescriptor] = [:]
            var unauthenticated = 0
            var nextID: UInt64 = 1
            var isClosed = false
            var reportWindowStart: ContinuousClock.Instant?
            var reportsInWindow = 0
            var unreported = 0
        }

        public let limits: Limits
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let now: @Sendable () -> ContinuousClock.Instant
        private let report: @Sendable (String) -> Void

        /// - Parameters:
        ///   - now: The clock for nonce lifetimes and the report rate; tests move it forward.
        ///   - report: Receives refusals, at most `Limits.refusalReports` per interval. Never
        ///     receives a nonce.
        public init(
            limits: Limits = Limits(),
            now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
            report: @escaping @Sendable (String) -> Void
        ) {
            self.limits = limits
            self.now = now
            self.report = report
        }

        // MARK: Sessions

        /// Opens a session's connection: registers a nonce, asks the agent through `client` to
        /// dial back with it, and returns the connection that the agent dialed, positioned after
        /// the nonce frame. There is no fallback to a connection that the host opens, whose
        /// unread output would stall the machine's vsock device (docs/protocol.md).
        public func openSessionConnection(through client: GuestAgentClient)
            async throws(MawError) -> OwnedDescriptor
        {
            let pending = try expect()
            do {
                try await client.dialBack(pending.nonce)
            } catch {
                cancel(pending)
                throw error
            }
            guard let descriptor = await connection(for: pending) else {
                throw .sessionDialBackMissing(
                    milliseconds: Int(limits.nonceLifetime.milliseconds))
            }
            return descriptor
        }

        /// Registers a new nonce for a session's `dialBack` request.
        public func expect() throws(MawError) -> Pending {
            let instant = now()
            let result: Result<Pending, MawError> = state.withLock { state in
                guard !state.isClosed else {
                    return .failure(
                        .guestAgentUnavailable(reason: "the virtual machine is not running"))
                }
                Self.expire(&state, at: instant)
                guard state.pending.count < limits.pendingRequests else {
                    return .failure(.sessionDialBackBusy(limit: limits.pendingRequests))
                }
                let pending = Pending(
                    id: state.nextID, nonce: .random(), expiry: instant + limits.nonceLifetime)
                state.nextID += 1
                state.pending.append(
                    Entry(id: pending.id, nonce: pending.nonce, expiry: pending.expiry))
                return .success(pending)
            }
            return try result.get()
        }

        /// Waits for the connection that sends `pending`'s nonce, until the nonce expires.
        /// Returns it positioned after the nonce frame, or `nil` once the nonce has expired, the
        /// machine has stopped, or the task is cancelled.
        public func connection(for pending: Pending) async -> OwnedDescriptor? {
            await withTaskCancellationHandler {
                let remaining = pending.expiry - now()
                let expiry = Task { [weak self] in
                    try? await Task.sleep(for: remaining)
                    self?.cancel(pending)
                }
                defer { expiry.cancel() }
                return await withCheckedContinuation { continuation in
                    let ready: OwnedDescriptor?? = state.withLock { state in
                        if let descriptor = state.arrived.removeValue(forKey: pending.id) {
                            return .some(descriptor)
                        }
                        guard let index = state.pending.firstIndex(where: { $0.id == pending.id })
                        else {
                            return .some(nil)
                        }
                        state.pending[index].waiter = continuation
                        return .none
                    }
                    if let ready {
                        continuation.resume(returning: ready)
                    }
                }
            } onCancel: {
                cancel(pending)
            }
        }

        /// Withdraws `pending`: its nonce no longer matches, a session waiting for it receives
        /// `nil`, and a connection that already matched it is closed.
        public func cancel(_ pending: Pending) {
            let (waiter, arrived) = state.withLock { state in
                var waiter: CheckedContinuation<OwnedDescriptor?, Never>?
                if let index = state.pending.firstIndex(where: { $0.id == pending.id }) {
                    waiter = state.pending.remove(at: index).waiter
                }
                return (waiter, state.arrived.removeValue(forKey: pending.id))
            }
            waiter?.resume(returning: nil)
            arrived?.close()
        }

        /// Refuses every connection from now on and ends every wait, when the machine stops.
        public func close() {
            let (waiters, arrived) = state.withLock { state in
                state.isClosed = true
                let waiters = state.pending.compactMap(\.waiter)
                let arrived = Array(state.arrived.values)
                state.pending.removeAll()
                state.arrived.removeAll()
                return (waiters, arrived)
            }
            for waiter in waiters {
                waiter.resume(returning: nil)
            }
            for descriptor in arrived {
                descriptor.close()
            }
        }

        // MARK: Connections

        /// Decides, before anything is read, whether to accept a connection from `sourcePort`.
        /// Returns `nil` to accept it; the caller must then pass it to `authenticate(_:)`, or
        /// call `abandon()` if it cannot. Cheap and non-blocking: it runs on the virtual
        /// machine's queue.
        public func admit(sourcePort: UInt32) -> Refusal? {
            let instant = now()
            let (refusal, waiters) = state.withLock { state -> (Refusal?, [Waiter]) in
                let waiters = Self.expire(&state, at: instant)
                if state.isClosed {
                    return (.closed, waiters)
                }
                if sourcePort > 1023 {
                    return (.unprivilegedSourcePort(sourcePort), waiters)
                }
                if state.pending.isEmpty {
                    return (.noPendingRequest, waiters)
                }
                let limit = state.pending.count + limits.extraUnauthenticatedConnections
                if state.unauthenticated >= limit {
                    return (.tooManyUnauthenticated(limit: limit), waiters)
                }
                state.unauthenticated += 1
                return (nil, waiters)
            }
            Self.resume(waiters)
            if let refusal {
                refuse(refusal)
            }
            return refusal
        }

        /// Gives back the place of an admitted connection that will not be authenticated.
        public func abandon() {
            state.withLock { $0.unauthenticated -= 1 }
        }

        /// Reads the nonce frame of an admitted connection and hands the connection to the
        /// session whose nonce it carries. Closes it if the frame does not arrive in time, is
        /// malformed, or carries no waiting session's nonce. Blocks for up to
        /// `Limits.nonceReadTimeout`; never call it on the virtual machine's queue.
        @discardableResult
        public func authenticate(_ descriptor: OwnedDescriptor) -> Refusal? {
            let received = Self.readNonce(
                from: descriptor.rawValue,
                until: ContinuousClock.now + limits.nonceReadTimeout)
            let instant = now()
            let (outcome, waiters) = state.withLock {
                state -> (Result<CheckedContinuation<OwnedDescriptor?, Never>?, Refusal>, [Waiter])
                in
                state.unauthenticated -= 1
                let waiters = Self.expire(&state, at: instant)
                guard !state.isClosed else { return (.failure(.closed), waiters) }
                let nonce: DialBackNonce
                switch received {
                case .success(let value): nonce = value
                case .failure(let refusal): return (.failure(refusal), waiters)
                }
                // Single use: a matched nonce leaves the table.
                guard let index = state.pending.firstIndex(where: { $0.nonce == nonce }) else {
                    return (.failure(.unknownNonce), waiters)
                }
                let entry = state.pending.remove(at: index)
                if entry.waiter == nil {
                    state.arrived[entry.id] = descriptor
                }
                return (.success(entry.waiter), waiters)
            }
            Self.resume(waiters)
            switch outcome {
            case .success(let waiter):
                waiter?.resume(returning: descriptor)
                return nil
            case .failure(let refusal):
                descriptor.close()
                refuse(refusal)
                return refusal
            }
        }

        /// Reads exactly one nonce frame: its 5-byte header, checked before its payload, and
        /// its 32-byte payload.
        static func readNonce(from descriptor: Int32, until deadline: ContinuousClock.Instant)
            -> Result<DialBackNonce, Refusal>
        {
            var decoder = FrameDecoder()
            do throws(Refusal) {
                let header = try readExactly(Frame.headerSize, from: descriptor, until: deadline)
                let type = header[Frame.headerSize - 1]
                guard type == FrameType.dialBackNonce.rawValue else {
                    throw .malformedNonceFrame("its type is 0x\(String(type, radix: 16))")
                }
                // The decoder checks the declared size from the header alone.
                decoder.append(header)
                do {
                    _ = try decoder.nextFrame()
                } catch {
                    throw .malformedNonceFrame(error.description)
                }
                decoder.append(
                    try readExactly(
                        AgentProtocol.dialBackNonceSize, from: descriptor, until: deadline))
                guard let frame = try? decoder.nextFrame(), let nonce = try? frame.dialBackNonce()
                else {
                    throw .malformedNonceFrame("the frame cannot be decoded")
                }
                return .success(nonce)
            } catch {
                return .failure(error)
            }
        }

        /// Reads `count` bytes, and no more, by `deadline`.
        private static func readExactly(
            _ count: Int, from descriptor: Int32, until deadline: ContinuousClock.Instant
        ) throws(Refusal) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: count)
            var received = 0
            while received < count {
                var request = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)]
                let ready: Int32
                do {
                    ready = try pollDescriptors(&request, timeout: pollTimeout(until: deadline))
                } catch {
                    throw .nonceNotReceived(error.description)
                }
                guard ready > 0 else {
                    throw .nonceNotReceived("timed out after \(received) bytes")
                }
                let result = bytes.withUnsafeMutableBytes { buffer in
                    read(descriptor, buffer.baseAddress! + received, count - received)
                }
                if result > 0 {
                    received += result
                } else if result == 0 {
                    throw .nonceNotReceived("the connection closed after \(received) bytes")
                } else if errno != EINTR && errno != EAGAIN {
                    throw .nonceNotReceived(SystemError("read").description)
                }
            }
            return bytes
        }

        // MARK: Expiry and reports

        private typealias Waiter = CheckedContinuation<OwnedDescriptor?, Never>

        /// Removes expired nonces and returns their waiters, to be resumed outside the lock.
        @discardableResult
        private static func expire(_ state: inout State, at instant: ContinuousClock.Instant)
            -> [Waiter]
        {
            var waiters: [Waiter] = []
            state.pending.removeAll { entry in
                guard entry.expiry <= instant else { return false }
                if let waiter = entry.waiter {
                    waiters.append(waiter)
                }
                return true
            }
            return waiters
        }

        private static func resume(_ waiters: [Waiter]) {
            for waiter in waiters {
                waiter.resume(returning: nil)
            }
        }

        /// Reports a refusal, at most `Limits.refusalReports` per interval. The first report of
        /// a new interval says how many were left out.
        private func refuse(_ refusal: Refusal) {
            let instant = now()
            let message: String? = state.withLock { state in
                var prefix = ""
                if let start = state.reportWindowStart,
                    instant - start < limits.refusalReportInterval
                {
                    guard state.reportsInWindow < limits.refusalReports else {
                        state.unreported += 1
                        return nil
                    }
                } else {
                    if state.unreported > 0 {
                        prefix = "\(state.unreported) further refusals were not logged; "
                    }
                    state.reportWindowStart = instant
                    state.reportsInWindow = 0
                    state.unreported = 0
                }
                state.reportsInWindow += 1
                return "\(prefix)refused a dial-back connection: \(refusal)"
            }
            if let message {
                report(message)
            }
        }
    }
#endif
