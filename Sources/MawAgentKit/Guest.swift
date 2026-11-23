#if os(Linux)
    import CMawSystem
    import MawProtocol

    #if canImport(Glibc)
        import Glibc
    #elseif canImport(Musl)
        import Musl
    #endif

    extension AgentConfiguration {
        /// The configuration of the agent in the guest. Power-off goes through PID 1, which is
        /// busybox `init` or systemd; see `InitSystem`.
        public static func guest() -> AgentConfiguration {
            AgentConfiguration(forwarding: .guest()) { () throws(SystemError) in
                let initSystem = InitSystem.detect { path in
                    var status = stat()
                    return stat(path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFDIR
                }
                let signal = initSystem.powerOffSignal
                guard kill(1, signal) == 0 else {
                    throw SystemError("kill(1, \(signal))")
                }
            }
        }
    }

    extension ForwardingEnvironment {
        /// The guest's listeners through sock_diag, a scanner per channel. The agent itself
        /// listens on no TCP socket, so none is excluded.
        public static func guest() -> ForwardingEnvironment {
            let scanner = LazyScanner()
            return ForwardingEnvironment(scanListeners: {
                () throws(ListenerScanner.ScanError) -> Set<GuestListener> in
                try scanner.scan()
            })
        }
    }

    /// Opens the netlink socket at the first scan, and again after a scan that failed.
    private final class LazyScanner: @unchecked Sendable {
        private let lock = ConditionLock()
        private var scanner: ListenerScanner?

        func scan() throws(ListenerScanner.ScanError) -> Set<GuestListener> {
            try lock.withLock { () throws(ListenerScanner.ScanError) -> Set<GuestListener> in
                if scanner == nil {
                    let transport: ListenerScanner.Transport
                    do throws(SystemError) {
                        transport = try .kernel()
                    } catch {
                        throw .system(error)
                    }
                    scanner = ListenerScanner(transport: transport)
                }
                do throws(ListenerScanner.ScanError) {
                    return try scanner!.scan()
                } catch {
                    scanner = nil
                    throw error
                }
            }
        }
    }

    /// Opens the agent's listening vsock socket on `AgentProtocol.vsockPort`.
    public func listenOnVsock(port: UInt32 = AgentProtocol.vsockPort) throws(SystemError)
        -> OwnedDescriptor
    {
        let descriptor = maw_vsock_listen(port, 64)
        guard descriptor >= 0 else {
            throw SystemError("listening on vsock port \(port)")
        }
        return OwnedDescriptor(descriptor)
    }
#endif
