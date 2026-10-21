#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Runs `body` on a new detached thread.
///
/// The agent's sessions and the client's I/O loops block in `poll(2)`. Blocking calls must not
/// run on Swift's cooperative thread pool, which has one thread per CPU, so each loop gets a
/// thread of its own. Returns false if the thread could not be created.
@discardableResult
public func startDetachedThread(_ body: @escaping @Sendable () -> Void) -> Bool {
    let box = Unmanaged.passRetained(ThreadBody(body)).toOpaque()
    var attributes = pthread_attr_t()
    pthread_attr_init(&attributes)
    defer { pthread_attr_destroy(&attributes) }
    pthread_attr_setdetachstate(&attributes, Int32(PTHREAD_CREATE_DETACHED))

    // `pthread_t` is an integer in glibc and a pointer in Darwin and musl.
    #if canImport(Glibc)
        var thread = pthread_t()
    #else
        var thread: pthread_t?
    #endif
    let result = pthread_create(
        &thread, &attributes,
        { context in
            #if canImport(Darwin)
                let box = Unmanaged<ThreadBody>.fromOpaque(context).takeRetainedValue()
            #else
                let box = Unmanaged<ThreadBody>.fromOpaque(context!).takeRetainedValue()
            #endif
            box.body()
            return nil
        }, box)
    if result != 0 {
        Unmanaged<ThreadBody>.fromOpaque(box).release()
        return false
    }
    return true
}

/// Runs blocking work on a dedicated thread and returns its result to the calling task.
public func runOnDedicatedThread<Result: Sendable, Failure: Error>(
    _ body: @escaping @Sendable () throws(Failure) -> Result
) async throws(Failure) -> Result {
    let outcome: Swift.Result<Result, Failure> = await withCheckedContinuation { continuation in
        let started = startDetachedThread {
            do throws(Failure) {
                continuation.resume(returning: .success(try body()))
            } catch {
                continuation.resume(returning: .failure(error))
            }
        }
        if !started {
            // Without a thread, run the work here rather than not at all.
            do throws(Failure) {
                continuation.resume(returning: .success(try body()))
            } catch {
                continuation.resume(returning: .failure(error))
            }
        }
    }
    return try outcome.get()
}

private final class ThreadBody {
    let body: @Sendable () -> Void

    init(_ body: @escaping @Sendable () -> Void) {
        self.body = body
    }
}
