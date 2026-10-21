#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// A mutex with a condition variable, for state shared between the I/O threads of the guest
/// agent and the agent client and the tasks that use them.
///
/// `Synchronization.Mutex` needs macOS 15, and neither it nor `os_unfair_lock` offers a
/// condition variable, which the client needs to apply back-pressure to writers.
public final class ConditionLock: @unchecked Sendable {
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>
    private let condition: UnsafeMutablePointer<pthread_cond_t>

    public init() {
        mutex = .allocate(capacity: 1)
        mutex.initialize(to: pthread_mutex_t())
        pthread_mutex_init(mutex, nil)
        condition = .allocate(capacity: 1)
        condition.initialize(to: pthread_cond_t())
        pthread_cond_init(condition, nil)
    }

    deinit {
        pthread_cond_destroy(condition)
        condition.deinitialize(count: 1)
        condition.deallocate()
        pthread_mutex_destroy(mutex)
        mutex.deinitialize(count: 1)
        mutex.deallocate()
    }

    public func withLock<Result, Failure: Error>(
        _ body: () throws(Failure) -> Result
    ) throws(Failure) -> Result {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return try body()
    }

    /// Waits for a broadcast. Call only inside `withLock`.
    public func wait() {
        pthread_cond_wait(condition, mutex)
    }

    /// Wakes every thread in `wait()`. Call inside `withLock`.
    public func broadcast() {
        pthread_cond_broadcast(condition)
    }
}
