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

        /// How long, in milliseconds, the probe of a port in use waits for the Mac's own
        /// loopback address.
        static let probeTimeoutMilliseconds: Int32 = 500

        /// Opens a listening socket on 127.0.0.1 or ::1, with SO_REUSEADDR when `reuseAddress`
        /// says so.
        typealias Listen = (_ ipv6: Bool, _ port: UInt16, _ reuseAddress: Bool) -> Result<
            OwnedDescriptor, SystemError
        >

        /// Connects to 127.0.0.1 or ::1 and closes at once, sending nothing: 0 when a listener
        /// accepted, otherwise the errno value (`maw_tcp_probe_loopback`).
        typealias Probe = (_ ipv6: Bool, _ port: UInt16) -> Int32

        /// Binds `port` on 127.0.0.1 and on ::1, or on neither. A port free on only one of them
        /// is not forwarded: a browser's `localhost` would reach the distribution while a Mac
        /// program holds the port.
        ///
        /// Each address is bound without SO_REUSEADDR first. When that fails with EADDRINUSE,
        /// the port is either a Mac program's or held only by connections in TIME_WAIT, which
        /// macOS keeps for 30 seconds after a forwarded connection that the guest's server
        /// closed first. One connection to the same address tells the two apart: only
        /// ECONNREFUSED, nothing listening there, leads to a second bind with SO_REUSEADDR. An
        /// accepted connection, a timeout, or another error leaves the port to the Mac:
        /// `inUse`. SO_REUSEPORT is never set.
        static func bind(
            port: UInt16,
            listen: Listen = { Self.listen(ipv6: $0, port: $1, reuseAddress: $2) },
            probe: Probe = { Self.probe(ipv6: $0, port: $1) }
        ) -> Result<LoopbackListeners, Failure> {
            guard port >= firstUnprivilegedPort else { return .failure(.privileged) }
            let ipv4: OwnedDescriptor
            switch half(ipv6: false, port: port, listen: listen, probe: probe) {
            case .success(let descriptor): ipv4 = descriptor
            case .failure(let failure): return .failure(failure)
            }
            switch half(ipv6: true, port: port, listen: listen, probe: probe) {
            case .success(let ipv6):
                return .success(LoopbackListeners(ipv4: ipv4, ipv6: ipv6))
            case .failure(let failure):
                ipv4.close()
                return .failure(failure)
            }
        }

        private static func half(ipv6: Bool, port: UInt16, listen: Listen, probe: Probe)
            -> Result<OwnedDescriptor, Failure>
        {
            let family = ipv6 ? "::1" : "127.0.0.1"
            switch listen(ipv6, port, false) {
            case .success(let descriptor):
                return .success(descriptor)
            case .failure(let error) where error.code == EADDRINUSE:
                guard probe(ipv6, port) == ECONNREFUSED else { return .failure(.inUse) }
                return listen(ipv6, port, true).mapError { failure($0, family: family) }
            case .failure(let error):
                return .failure(failure(error, family: family))
            }
        }

        private static func failure(_ error: SystemError, family: String) -> Failure {
            switch error.code {
            case EADDRINUSE: .inUse
            case EACCES: .privileged
            default: .other(family: family, code: error.code)
            }
        }

        static func listen(ipv6: Bool, port: UInt16, reuseAddress: Bool = false) -> Result<
            OwnedDescriptor, SystemError
        > {
            var descriptor: Int32 = -1
            let code = maw_tcp_listen_loopback(
                ipv6 ? 1 : 0, port, backlog, reuseAddress ? 1 : 0, &descriptor)
            guard code == 0 else { return .failure(SystemError("bind", code: code)) }
            return .success(OwnedDescriptor(descriptor))
        }

        static func probe(ipv6: Bool, port: UInt16) -> Int32 {
            maw_tcp_probe_loopback(ipv6 ? 1 : 0, port, probeTimeoutMilliseconds)
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
