#if os(macOS)
    import Dispatch
    import XPC
    import os

    /// One XPC connection, with its events as an async stream.
    ///
    /// This wraps libxpc's C connection API (docs/decisions/0010-xpc-c-connection-api.md). The
    /// connection's dispatch queue stays inside this type: libxpc requires one, and every
    /// callback is forwarded to `events` or to a continuation.
    public final class XPCConnection: @unchecked Sendable {
        public enum Event: Sendable {
            /// A message that is not a reply: a request on the daemon's side, a pushed event on
            /// the client's.
            case message(XPCObject)
            /// The remote side exited or crashed. For a client connection to a Mach service,
            /// the next message starts the service again.
            case interrupted
            /// The connection cannot be used again: it was cancelled, the service does not
            /// exist, or the peer closed it. The stream finishes after this event.
            case invalidated
        }

        /// Why a request got no reply.
        public enum Failure: Error, Equatable, Sendable {
            case interrupted
            case invalidated
        }

        /// Every event, in order. Finishes after `invalidated`.
        public let events: AsyncStream<Event>

        let raw: xpc_connection_t
        private let queue: DispatchQueue
        private let continuation: AsyncStream<Event>.Continuation

        /// Wraps `raw` and installs its event handler. The connection stays inactive until
        /// `activate()`.
        init(_ raw: xpc_connection_t, label: String) {
            self.raw = raw
            queue = DispatchQueue(label: "dev.maw.xpc.\(label)")
            (events, continuation) = AsyncStream.makeStream(of: Event.self)
            xpc_connection_set_target_queue(raw, queue)
            let continuation = continuation
            xpc_connection_set_event_handler(raw) { event in
                if xpc_get_type(event) == XPC_TYPE_ERROR {
                    if event === XPC_ERROR_CONNECTION_INTERRUPTED {
                        continuation.yield(.interrupted)
                    } else {
                        // XPC_ERROR_CONNECTION_INVALID, or a peer that failed the code
                        // signing requirement, after which libxpc invalidates the connection.
                        continuation.yield(.invalidated)
                        continuation.finish()
                    }
                } else {
                    continuation.yield(.message(XPCObject(event)))
                }
            }
        }

        /// A connection to the Mach service `name`, as a client. Call `activate()` before use.
        public convenience init(machService name: String) {
            self.init(xpc_connection_create_mach_service(name, nil, 0), label: name)
        }

        /// A connection to an anonymous listener's endpoint (see `XPCServiceListener.anonymous`).
        public convenience init(endpoint: XPCListenerEndpoint) {
            self.init(xpc_connection_create_from_endpoint(endpoint.raw), label: "endpoint")
        }

        public func activate() {
            xpc_connection_activate(raw)
        }

        /// Closes the connection. The peer sees it invalidated.
        public func cancel() {
            xpc_connection_cancel(raw)
        }

        /// Closes a connection that was never activated. libxpc does not allow releasing an
        /// inactive connection, so it is activated first; no message is handled.
        func reject() {
            activate()
            cancel()
        }

        /// The peer's effective user ID.
        public var peerUserID: uid_t {
            xpc_connection_get_euid(raw)
        }

        /// The peer's process ID, for logging only; process IDs are reused.
        public var peerProcessID: pid_t {
            xpc_connection_get_pid(raw)
        }

        /// Sends a message that expects no reply.
        public func send(_ message: XPCObject) {
            xpc_connection_send_message(raw, message.raw)
        }

        /// Sends a message and waits for its reply.
        public func request(_ message: XPCObject) async -> Result<XPCObject, Failure> {
            await withCheckedContinuation { continuation in
                xpc_connection_send_message_with_reply(raw, message.raw, queue) { reply in
                    if xpc_get_type(reply) == XPC_TYPE_ERROR {
                        continuation.resume(
                            returning: .failure(
                                reply === XPC_ERROR_CONNECTION_INTERRUPTED
                                    ? .interrupted : .invalidated))
                    } else {
                        continuation.resume(returning: .success(XPCObject(reply)))
                    }
                }
            }
        }
    }

    /// An anonymous listener's address, which `XPCConnection(endpoint:)` connects to. Used by
    /// the unit tests, which have no launchd service.
    public struct XPCListenerEndpoint: @unchecked Sendable {
        let raw: xpc_endpoint_t
    }

    /// Accepts connections to a Mach service, or anonymous ones in tests.
    ///
    /// Each peer is checked before it is activated: it must run as the same user as this
    /// process, and, when `codeSigningRequirement` is set, satisfy it. libxpc enforces the
    /// requirement on every message and invalidates a connection that fails it.
    public final class XPCServiceListener: @unchecked Sendable {
        /// Accepted, activated peer connections.
        public let peers: AsyncStream<XPCConnection>

        private let connection: XPCConnection
        private let consumer: Task<Void, Never>

        /// Listens on the Mach service `name`, which launchd must have registered for this
        /// process (the LaunchAgent's `MachServices`).
        public convenience init(machService name: String, codeSigningRequirement: String?) {
            self.init(
                XPCConnection(
                    xpc_connection_create_mach_service(
                        name, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)),
                    label: name),
                codeSigningRequirement: codeSigningRequirement)
        }

        /// A listener without a name, reachable only through `endpoint`.
        public static func anonymous(codeSigningRequirement: String? = nil) -> XPCServiceListener {
            XPCServiceListener(
                XPCConnection(xpc_connection_create(nil, nil), label: "anonymous"),
                codeSigningRequirement: codeSigningRequirement)
        }

        private init(_ connection: XPCConnection, codeSigningRequirement: String?) {
            self.connection = connection
            let (peers, continuation) = AsyncStream.makeStream(of: XPCConnection.self)
            self.peers = peers
            let logger = Logger.xpc
            consumer = Task { [events = connection.events] in
                for await event in events {
                    // A listener's messages are its new peers.
                    guard case .message(let object) = event,
                        xpc_get_type(object.raw) == XPC_TYPE_CONNECTION
                    else { continue }
                    let peer = XPCConnection(object.raw, label: "peer")
                    guard peer.peerUserID == geteuid() else {
                        logger.error(
                            "rejected process \(peer.peerProcessID): it runs as user \(peer.peerUserID)"
                        )
                        peer.reject()
                        continue
                    }
                    if let codeSigningRequirement {
                        let status = xpc_connection_set_peer_code_signing_requirement(
                            peer.raw, codeSigningRequirement)
                        guard status == 0 else {
                            logger.fault(
                                "the code signing requirement was refused (\(status)); rejecting peers"
                            )
                            peer.reject()
                            continue
                        }
                    }
                    peer.activate()
                    continuation.yield(peer)
                }
                continuation.finish()
            }
        }

        deinit {
            consumer.cancel()
        }

        public func activate() {
            connection.activate()
        }

        public func cancel() {
            connection.cancel()
        }

        /// The address of an anonymous listener.
        public var endpoint: XPCListenerEndpoint {
            XPCListenerEndpoint(raw: xpc_endpoint_create(connection.raw))
        }
    }
#endif
