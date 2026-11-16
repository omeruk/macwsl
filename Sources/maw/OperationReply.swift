import MawCore

/// The reply of a long operation, `maw --install` or `maw --export`, after maw has asked the
/// daemon to cancel it.
///
/// When the daemon answers `cancel`, it has already sent the operation's own reply: the
/// operation's task sends that reply before it ends, and the daemon answers `cancel` only after
/// the task has ended (`DaemonService.serve`). The two replies resume tasks of their own here,
/// though, which can run in either order, so maw waits for the operation's reply instead of
/// assuming that it has arrived.
enum OperationReply {
    /// The operation's reply, or `nil` if it has not arrived within `timeout`.
    static func reply<Value: Sendable>(
        of operation: Task<Result<Value, MawError>, Never>, timeout: Duration
    ) async -> Result<Value, MawError>? {
        let first = FirstResult<Result<Value, MawError>?>()
        return await withCheckedContinuation { continuation in
            first.onResult { continuation.resume(returning: $0) }
            Task {
                first.settle(await operation.value)
            }
            Task {
                try? await Task.sleep(for: timeout)
                first.settle(nil)
            }
        }
    }
}
