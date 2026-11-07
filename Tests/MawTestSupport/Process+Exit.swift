import Foundation

extension Process {
    /// Waits until the process has exited, at most `timeout`, and kills it after that. Returns
    /// whether it exited within `timeout`.
    ///
    /// Tests use this, never `waitUntilExit()`. Without a `terminationHandler`,
    /// `waitUntilExit()` also waits for a notification that Foundation delivers through a run
    /// loop. In an async test that notification did not arrive: the integration suite waited
    /// for more than an hour for a `yes` process that had already exited. `isRunning` does not
    /// depend on a run loop.
    @discardableResult
    public func waitForExit(within timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while isRunning && ContinuousClock.now < deadline && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard isRunning else { return true }
        // As `reapOrKill`, but sleeping without holding a thread of the cooperative pool.
        kill(processIdentifier, SIGKILL)
        let killed = ContinuousClock.now + .seconds(5)
        while isRunning && ContinuousClock.now < killed {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// `waitForExit(within:)` for code that cannot wait asynchronously, such as a `deinit`.
    @discardableResult
    public func waitForExitSynchronously(within timeout: Duration) -> Bool {
        let deadline = ContinuousClock.now + timeout
        while isRunning && ContinuousClock.now < deadline {
            usleep(10_000)
        }
        return reapOrKill()
    }

    /// Terminates the process after `timeout` unless the returned task is cancelled first, so
    /// that a blocking read of its output cannot wait for ever.
    public func terminate(after timeout: Duration) -> Task<Void, Never> {
        Task.detached { [self] in
            guard (try? await Task.sleep(for: timeout)) != nil, isRunning else { return }
            terminate()
        }
    }

    /// Returns true if the process has exited; otherwise kills it, waits up to five seconds
    /// for it to go, and returns false.
    private func reapOrKill() -> Bool {
        guard isRunning else { return true }
        kill(processIdentifier, SIGKILL)
        let deadline = ContinuousClock.now + .seconds(5)
        while isRunning && ContinuousClock.now < deadline {
            usleep(10_000)
        }
        return false
    }
}
