#if os(macOS)
    /// Decides when the daemon exits: after `idleTimeout` with no connected client and no
    /// active machine. launchd starts it again on the next connection, so an idle daemon
    /// costs nothing.
    public actor DaemonLifetime<C: Clock> where C.Duration == Duration {
        private let clock: C
        private let idleTimeout: Duration
        private let onIdle: @Sendable () -> Void
        private var clients = 0
        private var machinesActive = false
        private var timer: Task<Void, Never>?
        private var hasExpired = false

        /// `onIdle` runs once, when the timeout expires.
        public init(
            clock: C, idleTimeout: Duration = DaemonTimeouts.daemonIdle,
            onIdle: @escaping @Sendable () -> Void
        ) {
            self.clock = clock
            self.idleTimeout = idleTimeout
            self.onIdle = onIdle
        }

        /// Starts the first timer. launchd starts the daemon for a connection that usually
        /// arrives at once, which cancels it.
        public func begin() {
            update()
        }

        public func clientConnected() {
            clients += 1
            update()
        }

        public func clientDisconnected() {
            clients = max(0, clients - 1)
            update()
        }

        public func setMachinesActive(_ active: Bool) {
            machinesActive = active
            update()
        }

        public var isIdle: Bool {
            clients == 0 && !machinesActive
        }

        private func update() {
            guard !hasExpired else { return }
            guard isIdle else {
                timer?.cancel()
                timer = nil
                return
            }
            guard timer == nil else { return }
            let timeout = idleTimeout
            timer = Task { [clock] in
                do {
                    try await clock.sleep(for: timeout)
                } catch {
                    return
                }
                expire()
            }
        }

        private func expire() {
            guard isIdle, !hasExpired else { return }
            hasExpired = true
            onIdle()
        }
    }
#endif
