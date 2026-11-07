import CMawSystem

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// A failed system call: the operation and its errno value.
public struct SystemError: Error, Equatable, Sendable, CustomStringConvertible {
    public var operation: String
    public var code: Int32

    public init(_ operation: String, code: Int32 = errno) {
        self.operation = operation
        self.code = code
    }

    public var description: String {
        "\(operation): \(Self.message(for: code))"
    }

    /// The C library's description of an errno value, such as "No such file or directory".
    public static func message(for code: Int32) -> String {
        guard let text = strerror(code) else { return "error \(code)" }
        return String(cString: text)
    }
}

/// `dup(2)` with close-on-exec set on the duplicate (`F_DUPFD_CLOEXEC`), so that no program the
/// process starts inherits it. `dup` leaves the flag clear. Returns the duplicate, or -1 with
/// `errno` set.
public func duplicateClosingOnExec(_ descriptor: Int32) -> Int32 {
    maw_duplicate(descriptor)
}

/// Repeats a system call that failed with EINTR. Returns the call's result.
@inline(__always)
func retryingOnInterrupt<Result: BinaryInteger>(_ call: () -> Result) -> Result {
    while true {
        let result = call()
        if result >= 0 || errno != EINTR {
            return result
        }
    }
}

/// `poll(2)` that retries on EINTR. `timeout` is in milliseconds; -1 waits indefinitely.
public func pollDescriptors(_ descriptors: inout [pollfd], timeout: Int32) throws(SystemError)
    -> Int32
{
    let count = descriptors.count
    let result = descriptors.withUnsafeMutableBufferPointer { buffer in
        retryingOnInterrupt { poll(buffer.baseAddress, nfds_t(count), timeout) }
    }
    guard result >= 0 else { throw SystemError("poll") }
    return result
}

/// Milliseconds until `deadline`, rounded up and clamped for `poll`: 0 once it has passed,
/// -1 for no deadline.
public func pollTimeout(until deadline: ContinuousClock.Instant?) -> Int32 {
    guard let deadline else { return -1 }
    let remaining = deadline - .now
    if remaining <= .zero {
        return 0
    }
    let (seconds, attoseconds) = remaining.components
    let milliseconds = seconds * 1_000 + (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
    return Int32(clamping: milliseconds)
}

/// Writes all of `bytes` to a blocking descriptor. Throws on any error other than EINTR.
public func writeAll(_ bytes: some Collection<UInt8>, to descriptor: Int32) throws(SystemError) {
    let array = Array(bytes)
    var offset = 0
    while offset < array.count {
        let written = array.withUnsafeBytes { buffer in
            retryingOnInterrupt {
                write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
            }
        }
        guard written > 0 else { throw SystemError("write") }
        offset += written
    }
}

/// A pollfd that asks for `events` on `descriptor`.
@inline(__always)
func pollRequest(_ descriptor: Int32, _ events: Int32) -> pollfd {
    pollfd(fd: descriptor, events: Int16(events), revents: 0)
}

extension pollfd {
    /// Whether `poll` reported any of `events`.
    @inline(__always)
    public func returned(_ events: Int32) -> Bool {
        Int32(revents) & events != 0
    }
}

// `close(2)` and `write(2)` under names that methods called `close()` and `write(_:)` do not
// shadow.

@inline(__always)
func systemClose(_ descriptor: Int32) -> Int32 {
    close(descriptor)
}

@inline(__always)
func systemWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    write(descriptor, buffer, count)
}
