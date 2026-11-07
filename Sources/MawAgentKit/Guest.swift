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
            AgentConfiguration { () throws(SystemError) in
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
