# 0005: busybox init is PID 1 and supervises the guest agent

- Status: Accepted
- Date: 2026-10-21

## Context

Every MacWSL VM runs `macwsl-agent`, which serves exec sessions and control requests over
vsock (see `docs/protocol.md`). Something in the guest has to be PID 1, and Linux places
special demands on it:

- If PID 1 exits or crashes, the kernel panics and the VM is lost.
- PID 1 inherits every orphaned process and must reap it, or zombies accumulate.
- PID 1 receives signals only for which it has installed a handler; the default actions do
  not apply to it.
- Shutting down cleanly means stopping the other processes, syncing, unmounting, and calling
  `reboot(2)` from PID 1 or with its cooperation.

The options considered:

1. **The agent is PID 1.** It would handle reaping, signals, and shutdown itself. Any bug in
   the agent, including a Swift runtime trap on unexpected input, would panic the kernel.
   Reaping by PID 1 also collects the exit status of the agent's own children, so the agent's
   per-session `waitpid` and a global reaper would compete for the same processes.
2. **A minimal init written for MacWSL.** It would have to be written, tested, and
   maintained, and it would duplicate what busybox already provides in the initramfs.
3. **busybox `init`, with the agent as a supervised child.**

## Decision

Option 3. `/init` keeps its steps: it mounts the pseudo-file systems, prints the banner, and
runs the `macwsl.test=` hooks. It then writes `/etc/inittab` and executes `/sbin/init`
(busybox), which becomes PID 1.

```
::respawn:/sbin/macwsl-agent
hvc0::respawn:/bin/cttyhack /bin/sh -l      only with macwsl.debug=shell
::shutdown:/sbin/macwsl-shutdown
```

- **Supervision.** `init` restarts the agent whenever it exits. An agent crash costs the
  open sessions, not the VM.
- **Reaping.** `init` reaps orphans. The agent waits only for its own direct children, by
  process ID, through a pidfd.
- **Console.** Without `macwsl.debug=shell`, `hvc0` carries only console output: the
  kernel log, the banner, the agent's log, and `macwsl-agent ready <version>`. With it, `init`
  also runs a shell there. `macwsld debug-boot --interactive` adds the option, so that the
  console stays usable when the agent does not start. A guest built without the agent runs
  the shell instead of the agent.
- **Shutdown.** The agent's `shutdown` request sends SIGUSR2 to PID 1, busybox's power-off
  signal, and then acknowledges. `init` runs the `::shutdown:` action, `macwsl-shutdown`,
  which sends SIGTERM to every other process, waits up to one second for them to exit,
  sends SIGKILL to the rest, syncs, unmounts, and calls `poweroff -f`.

## Why the shutdown action powers off itself

After the shutdown actions, busybox 1.37 `init` sends SIGTERM and SIGKILL to every process
itself, but it sleeps for one second after SIGTERM and one more before `reboot(2)`, whether or
not anything is left (`run_shutdown_and_kill_processes` and `pause_and_low_level_reboot` in
`init/init.c`). That alone exceeds the two seconds the host allows for a clean shutdown.
`macwsl-shutdown` performs the same steps, but waits only while processes remain, and powers
off at the end, so `init`'s own sequence never runs. A clean shutdown measured 56 to 89 ms
from the host's request to the VM stopping.

## Consequences

- PID 1 is code that MacWSL does not write, configured by a generated inittab of three lines.
- The agent runs as an ordinary process. It ignores SIGPIPE, and children it starts get
  default signal dispositions again (see 0006).
- Phase 05 boots real distributions, whose PID 1 may be systemd. The agent does not assume it
  is PID 1 or a child of busybox, so the same binary can run under another init.
