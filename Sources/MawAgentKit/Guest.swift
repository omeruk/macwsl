#if os(Linux)
    import CMawSystem
    import MawProtocol

    #if canImport(Glibc)
        import Glibc
    #elseif canImport(Musl)
        import Musl
    #endif

    extension AgentConfiguration {
        /// The configuration of the agent in the guest. Power-off goes through busybox `init`,
        /// which is PID 1: SIGUSR2 asks it to run the inittab shutdown actions, which end in
        /// `poweroff -f` (see docs/decisions/0005-init-supervises-the-agent.md).
        public static func guest() -> AgentConfiguration {
            AgentConfiguration { () throws(SystemError) in
                guard kill(1, SIGUSR2) == 0 else {
                    throw SystemError("kill(1, SIGUSR2)")
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
