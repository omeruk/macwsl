# 0004: The VM actor runs on the virtual machine's dispatch queue

- Status: Accepted
- Date: 2026-10-20

## Context

`VZVirtualMachine` is not thread-safe. It is created with a dispatch queue, and every call
to it must be made on that queue. The framework also calls back on that queue: the completion
handlers of `start` and `stop`, and the `VZVirtualMachineDelegate` methods.

MacWSL is written in Swift 6 with strict concurrency, and `CLAUDE.md` asks for actors rather
than dispatch queues, except where an Apple API requires a queue, wrapped at the boundary.

The options considered:

1. **A class that dispatches every call onto the queue by hand.** The compiler cannot check
   that each call goes through the queue, and the class's own state needs separate locking.
2. **`@MainActor`, with the VM created on the main queue.** The daemon has no reason to run VM
   work on its main thread, and the app's UI would share it with every VM.
3. **An actor with the default executor that hops to the queue for each framework call.**
   This creates two serialization domains, so state is split between them, and every call
   pays for two hops.
4. **An actor whose executor is the VM's queue.**

## Decision

Option 4. `VirtualMachine` owns one `DispatchSerialQueue`. The same queue is passed to
`VZVirtualMachine(configuration:queue:)` and returned as the actor's executor:

```swift
public nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
}
```

Every actor-isolated method therefore runs on the queue that Virtualization.framework
requires. "Only touch the VM from its queue" becomes "only touch the VM from the actor", which
the compiler enforces. There is no `DispatchQueue.async` in MacWSL's code.

`DispatchSerialQueue` conforms to `SerialExecutor` from macOS 14, which is MacWSL's minimum.

## Rules that follow

- **Framework objects stay inside the actor.** The `VZVirtualMachineConfiguration` and the
  `VZVirtualMachine` are created inside `start()` and never leave the actor. Its public
  interface uses `Sendable` values only: `VMConfiguration`, `State`, `StopOutcome`, and
  `MacWSLError`.
- **Completion handlers become continuations.** `start()` and `stop(timeout:)` wrap the
  framework's completion handlers in checked continuations. While the actor waits, it is
  suspended and the queue is free, so the framework can run the handler on it. This cannot
  deadlock.
- **Delegate callbacks are forwarded, not assumed to be isolated.** The delegate methods run on
  the queue, but outside any Swift task. `assumeIsolated` would have to prove at run time that
  the current thread is executing the actor's queue. Rather than depend on how the runtime
  performs that check on each supported macOS version, the delegate yields events into an
  `AsyncStream`, and a task isolated to the actor handles them in order.
- **Reentrancy.** The actor can be re-entered at every `await` in `start()` and `stop()`. Code
  after an `await` re-checks the state. For example, `stop(timeout:)` handles a guest that
  powers off on its own while the stop request is outstanding.
- **Nothing blocks the queue.** A blocking call on the actor would block the queue, and with
  it the framework's callbacks. Console I/O therefore runs on dedicated threads, outside the
  actor.
- **One queue per virtual machine.** VMs do not serialize behind one another.
