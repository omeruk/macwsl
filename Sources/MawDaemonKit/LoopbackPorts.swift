#if os(macOS)
    import CMawSystem
    import Darwin
    import MawCore
    import MawProtocol
    import MawXPC
    import os

    /// The pair of listening sockets that forward one port: 127.0.0.1 and ::1
    /// (docs/decisions/0023-localhost-forwarding.md).
    struct LoopbackListeners: Sendable {
        let ipv4: OwnedDescriptor
        let ipv6: OwnedDescriptor

        var descriptors: [OwnedDescriptor] { [ipv4, ipv6] }

        /// Why `bind(port:)` did not forward a port.
        enum Failure: Error, Equatable, Sendable {
            /// The port is below 1024; nothing was bound.
            case privileged
            /// A Mac program holds the port on 127.0.0.1, on ::1, or on both.
            case inUse
            /// Another error, with the family and its errno value, for `mawd.log`.
            case other(family: String, code: Int32)

            var reason: PortForwarding.Reason {
                switch self {
                case .privileged: .privilegedOnMac
                case .inUse: .inUseOnMac
                case .other: .bindFailed
                }
            }
        }

        /// The first port that a program that is not root may use on the Mac's loopback
        /// addresses. Phase 08 Part 1 measured `bind` failing with EACCES below it, on both.
        static let firstUnprivilegedPort: UInt16 = 1024

        /// The listen backlog of each socket.
        static let backlog: Int32 = 128

        /// Binds `port` on 127.0.0.1 and on ::1, or on neither. A port free on only one of them
        /// is not forwarded: a browser's `localhost` would reach the distribution while a Mac
        /// program holds the port. Neither socket sets SO_REUSEADDR or SO_REUSEPORT
        /// (`maw_tcp_listen_loopback`).
        static func bind(
            port: UInt16,
            listen: (_ ipv6: Bool, _ port: UInt16) -> Result<OwnedDescriptor, SystemError> =
                { Self.listen(ipv6: $0, port: $1) }
        ) -> Result<LoopbackListeners, Failure> {
            guard port >= firstUnprivilegedPort else { return .failure(.privileged) }
            let ipv4: OwnedDescriptor
            switch listen(false, port) {
            case .success(let descriptor): ipv4 = descriptor
            case .failure(let error): return .failure(failure(error, family: "127.0.0.1"))
            }
            switch listen(true, port) {
            case .success(let ipv6):
                return .success(LoopbackListeners(ipv4: ipv4, ipv6: ipv6))
            case .failure(let error):
                ipv4.close()
                return .failure(failure(error, family: "::1"))
            }
        }

        private static func failure(_ error: SystemError, family: String) -> Failure {
            switch error.code {
            case EADDRINUSE: .inUse
            case EACCES: .privileged
            default: .other(family: family, code: error.code)
            }
        }

        static func listen(ipv6: Bool, port: UInt16) -> Result<OwnedDescriptor, SystemError> {
            var descriptor: Int32 = -1
            let code = maw_tcp_listen_loopback(ipv6 ? 1 : 0, port, backlog, &descriptor)
            guard code == 0 else { return .failure(SystemError("bind", code: code)) }
            return .success(OwnedDescriptor(descriptor))
        }

        func close() {
            ipv4.close()
            ipv6.close()
        }
    }

    /// The ports that each running distribution forwards, across the daemon, so that one port
    /// is forwarded for one distribution at a time: the first to claim it keeps it until it
    /// releases it.
    public final class ForwardedPortRegistry: Sendable {
        private let owners = OSAllocatedUnfairLock<[UInt16: MachineID]>(initialState: [:])

        public init() {}

        /// Claims `port` for `machine`. Returns `nil`, or the machine that holds it.
        func claim(_ port: UInt16, for machine: MachineID) -> MachineID? {
            owners.withLock { owners in
                if let owner = owners[port], owner != machine { return owner }
                owners[port] = machine
                return nil
            }
        }

        func release(_ port: UInt16, for machine: MachineID) {
            owners.withLock { owners in
                if owners[port] == machine { owners[port] = nil }
            }
        }

        /// The machine that forwards `port`; for tests.
        func owner(of port: UInt16) -> MachineID? {
            owners.withLock { $0[port] }
        }
    }
#endif
