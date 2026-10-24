#if os(macOS)
    import MawCore
    import MawProtocol

    /// One virtual machine as the registry sees it. `VirtualMachineHandle` is the real one; the
    /// unit tests use a fake.
    ///
    /// A handle boots at most once. After it stops, the registry creates a new one.
    public protocol MachineHandle: AnyObject, Sendable {
        var machine: MachineID { get }
        var cpuCount: Int { get }
        var memoryBytes: UInt64 { get }

        /// Boots the machine and returns once its guest agent answers.
        func start() async throws(MawError)

        /// Opens a new session's connection to the guest agent, which the caller owns. The
        /// agent dials it in reply to a `dialBack` request (docs/protocol.md).
        func openSessionConnection() async throws(MawError) -> OwnedDescriptor

        /// Stops the machine cleanly, or forcibly if the guest does not power off in time.
        /// Returns once it has stopped, with a description of how for the log.
        func stop() async -> String

        /// Yields once, with the reason, if the machine stops without `stop()`: the guest
        /// powered off or crashed, or Virtualization.framework reported an error.
        var unexpectedStops: AsyncStream<String> { get }
    }

    /// Creates the handle for a machine. Throws if the machine cannot exist, for example
    /// because the guest files are missing.
    public typealias MachineFactory = @Sendable (MachineID) throws(MawError) -> any MachineHandle

    /// The timings of machine and daemon lifetimes. Phase 12 makes them configurable through
    /// `~/.mawconfig`.
    public enum DaemonTimeouts {
        /// A machine stops this long after its last session ends.
        public static let machineIdle = Duration.seconds(60)
        /// The daemon exits after this long with no client and no running machine.
        public static let daemonIdle = Duration.seconds(300)
    }
#endif
