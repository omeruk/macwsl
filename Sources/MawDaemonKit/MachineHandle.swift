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

        /// The kernel release that the guest agent reported when the machine started, made
        /// safe to show (`ForegroundAnswer.displayableName`); `nil` before it has.
        var kernelRelease: String? { get }
        /// The time from the start of the machine to its agent's answer, as `start()` logs it;
        /// `nil` before the agent has answered.
        var bootMilliseconds: UInt64? { get }

        /// Boots the machine and returns once its guest agent answers.
        func start() async throws(MawError)

        /// Opens a new session's connection to the guest agent, which the caller owns. The
        /// agent dials it in reply to a `dialBack` request (docs/protocol.md).
        func openSessionConnection() async throws(MawError) -> OwnedDescriptor

        /// Asks the guest agent for the guest's figures (docs/protocol.md, "Sample"), on a
        /// connection of its own, within about a second. Takes no lease and starts nothing.
        func sample() async throws(MawError) -> GuestSample

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
