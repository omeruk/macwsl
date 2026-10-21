#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// A file descriptor with one owner, which closes it exactly once.
///
/// The descriptor stays a plain `Int32`, so that it can be handed to another process (over XPC
/// in phase 04b) with `take()`.
public final class OwnedDescriptor: @unchecked Sendable, CustomStringConvertible {
    private let lock = ConditionLock()
    private var value: Int32

    /// Takes ownership of `rawValue`.
    public init(_ rawValue: Int32) {
        value = rawValue
    }

    deinit {
        if value >= 0 {
            _ = systemClose(value)
        }
    }

    /// The descriptor, or -1 once it has been closed or taken.
    public var rawValue: Int32 {
        lock.withLock { value }
    }

    /// Closes the descriptor. Safe to call more than once.
    public func close() {
        let descriptor = lock.withLock {
            defer { value = -1 }
            return value
        }
        if descriptor >= 0 {
            _ = systemClose(descriptor)
        }
    }

    /// Gives up ownership and returns the descriptor, which the caller must close.
    public func take() -> Int32 {
        lock.withLock {
            defer { value = -1 }
            return value
        }
    }

    public var description: String {
        "descriptor \(rawValue)"
    }
}
