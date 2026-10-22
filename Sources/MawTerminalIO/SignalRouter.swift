import MawProtocol
import os

/// Routes the signals that `SignalMonitor` observes. Once a guest process is attached, they
/// are forwarded to it. Until then, or if none is ever attached, they are recorded and yielded
/// on `unrouted`, where they end the session.
public final class SignalRouter: Sendable {
    public let unrouted: AsyncStream<Int32>
    private let state = OSAllocatedUnfairLock<(process: GuestProcess?, pending: Int32?)>(
        initialState: (nil, nil))
    private let monitor: SignalMonitor

    public init(_ monitor: SignalMonitor) {
        self.monitor = monitor
        let (stream, continuation) = AsyncStream.makeStream(of: Int32.self)
        unrouted = stream
        Task { [state] in
            for await number in monitor.signals {
                let process = state.withLock { state -> GuestProcess? in
                    if state.process == nil {
                        state.pending = state.pending ?? number
                    }
                    return state.process
                }
                if let process {
                    process.send(Signal(localNumber: number) ?? .term)
                } else {
                    continuation.yield(number)
                }
            }
        }
    }

    /// The first signal received while no process was attached.
    public var pendingSignal: Int32? {
        state.withLock { $0.pending }
    }

    /// Forwards later signals to `process`. A signal that arrived before is forwarded now.
    public func attach(_ process: GuestProcess) {
        let pending = state.withLock { state -> Int32? in
            state.process = process
            defer { state.pending = nil }
            return state.pending
        }
        if let pending {
            process.send(Signal(localNumber: pending) ?? .term)
        }
    }
}
