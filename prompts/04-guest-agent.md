# Phase 04: Guest agent and exec protocol

Read `CLAUDE.md` and `docs/decisions/` first. Work on branch `phase/04-guest-agent` from the
latest `main`.

This phase is the first of two. Phase 04 lets the host run commands in the guest through an
agent over vsock, and gives the virtual machine a clean shutdown. Phase 04b connects the
`macwsl` CLI to the daemon over XPC. Do not start on XPC or on the `macwsl` CLI actions here.

## Goal

At the end of this phase, these commands work on the owner's Mac. `macwsld` stands for
`.build/debug/macwsld`.

```sh
macwsld debug-boot --exec -- uname -a           # prints the guest's uname and exits 0
macwsld debug-boot --exec -- sh -c 'exit 3'     # exits 3
echo hello | macwsld debug-boot --exec -- cat   # prints hello
macwsld debug-boot --shell                      # an interactive shell with a real PTY
```

In both modes the virtual machine shuts down cleanly. The console log records
`shutdown: clean`, not `forced`.

## Architecture

### Guest side

1. **`MacWSLAgentKit`** is a new library target holding the agent's logic.
   - It is portable POSIX code, so that its unit tests run on macOS in CI.
   - Linux-only parts (vsock, `reboot(2)`, mounting) live behind `#if os(Linux)`, in small
     files.
2. **`macwsl-agent`** stays a thin executable that depends on `MacWSLAgentKit`. It is built
   with the Swift Static Linux SDK (`aarch64-swift-linux-musl`).
   - Keep the binary small. Prefer `FoundationEssentials` or plain `Musl`/`Glibc` APIs over
     full `Foundation`.
   - Record the stripped binary size in the PR. If it exceeds 15 MB, explain why.
3. **PID 1 and supervision.** Do not make the agent PID 1. `/init` keeps its current steps
   (mounts, banner, test hooks). It then writes `/etc/inittab` and `exec`s busybox `init`,
   which becomes PID 1.
   - `inittab` respawns `/sbin/macwsl-agent`, so that an agent crash does not panic the
     kernel. busybox `init` also reaps orphaned processes.
   - With `macwsl.debug=shell` on the kernel command line, `inittab` additionally runs a
     respawning shell on `hvc0`. This keeps the phase 03 `debug-boot --interactive` console
     useful for debugging.
   - Without it, `hvc0` carries only console output.
   - Shutdown runs through busybox `init`'s own shutdown actions: sync, unmount, power off.
   - Record this decision in a new record in `docs/decisions/` (use the next free number).
     Explain why `init` supervises the agent instead of the agent running as PID 1.

### Wire protocol

Put the protocol in `MacWSLProtocol` (portable) and specify it in `docs/protocol.md`.

**Transport**
- vsock. The agent listens on a fixed port, defined once in `MacWSLProtocol` and documented.
- Each exec session uses its own connection.
- Control requests (`info`, `shutdown`) each use a short connection of their own.

**Framing**
- Length-prefixed frames: 4-byte big-endian length, 1-byte type, then the payload.
- Reject frames larger than a documented maximum.
- Data frames carry raw bytes. Control frames carry JSON-encoded `Codable` messages.

**Handshake**
- Each side sends its protocol version first. On a mismatch, the connection is closed with
  an error frame that names both versions.
- The host maps that error to a `MacWSLError` that tells the user to update the guest files
  with `scripts/fetch-guest.sh`.

**Exec request**
- `argv`
- environment additions (`TERM`, `LANG`, plus explicit ones)
- working directory, with `/` as the default
- PTY or pipes
- initial terminal size

There is no user switching yet. Commands run as root until phase 05.

**After an exec starts**
- Host to guest: stdin data, stdin EOF, signal, resize.
- Guest to host: `started(pid)`, stdout data, stderr data, and a final `exited` with either
  an exit code or a signal number.

**Exec modes**
- **PTY mode:**
  - `openpty`, `setsid`, `TIOCSCTTY`, and `TIOCSWINSZ` on resize.
  - stdout and stderr are the PTY.
  - Signals go to the foreground process group.
- **Pipe mode:**
  - Separate stdin, stdout, and stderr pipes.
  - Signals go to the process group.
- **Exit codes** follow ssh: the process's exit code, or 128 plus the signal number.

**Control requests**
- `info` returns the agent version, protocol version, kernel release, and uptime.
- `shutdown` makes the agent ask `init` to power off, then acknowledge.

**Robustness**
- A malformed, truncated, or oversized frame closes that connection only.
- The agent keeps serving other connections and never crashes on bad input.
- Back-pressure comes from the stream itself. Do not buffer without bounds on either side.

**Readiness**
- When the agent is listening, it writes `macwsl-agent ready <version>` to the console.
- Hosts do not depend on that line, though. They wait for the agent by retrying the vsock
  connection, with a deadline.

### Host side

- **`GuestAgentClient`** (in `MacWSLProtocol`, transport-independent): it runs a session over
  any connected file descriptor.
  - Unit tests drive it against the real agent session code through a `socketpair` on macOS.
- **`VirtualMachine` connects to the agent.** In `MacWSLVirtualization`, `VirtualMachine`
  gains `connectToAgent(timeout:)`. It uses `VZVirtioSocketDevice.connect(toPort:)` and
  returns the connection's file descriptor wrapped for the client.
  - Phase 04b will hand this descriptor to the CLI over XPC. Keep it a plain descriptor.
- **New stop order.** `stop(timeout:)` now:
  1. sends the agent's `shutdown` and waits for `guestDidStop`;
  2. falls back to `requestStop()`;
  3. finally forces the stop.

  The console log records which path was taken.
- **`macwsld debug-boot` options.**
  - `--exec -- <argv...>` runs one command in pipe mode:
    - It forwards stdin, stdout, and stderr.
    - It forwards SIGINT, SIGTERM, and SIGHUP to the guest process.
    - It exits with the command's exit code after a clean shutdown.
  - `--shell` runs `/bin/sh -l` in PTY mode, using:
    - the phase 03 raw mode;
    - the escape handling (`~.`, `~?`, the detach key);
    - `SIGWINCH` forwarding for window resizes.
  - `--interactive` keeps its phase 03 meaning: the raw `hvc0` console. It now adds
    `macwsl.debug=shell` automatically.
- **Timing lines.** Print `boot: agent ready after <n> ms` next to the existing banner line.

## Build and CI

- **Guest workflow** (`.github/workflows/guest.yml`):
  - It installs a Swift toolchain and the matching Static Linux SDK, both pinned by version
    and verified by checksum.
  - It builds `macwsl-agent` for `aarch64-swift-linux-musl` and passes it to
    `Guest/build.sh --agent`, so that every Guest artifact contains the agent.
  - It records the agent's sha256 in `manifest.json`. This was already prepared in phase 02.
- **Reproducibility.** The reproducibility check must still pass with the agent included. If
  the Swift build is not byte-reproducible, say so with evidence. In that case, compare the
  two builds while excluding the agent, and record the gap under "Known limitations". Do not
  weaken the check silently.
- **QEMU smoke test.** Boot with `macwsl.test=agent`. With that flag, `/init` runs the
  agent's self-test instead of supervision:
  - it spawns `/bin/true` in pipe mode and `tty` in PTY mode, and checks both exit codes;
  - it prints `macwsl-agent self-test: ok`;
  - it powers off.

  The smoke test asserts that line. QEMU on the runner has no vsock, so this exercises
  everything except the transport.
- **CI on macOS** runs the `MacWSLAgentKit` and `MacWSLProtocol` unit tests.
- **Local agent builds.**
  - Document in `Guest/README.md` how to build the agent locally with a swift.org toolchain
    and the Static Linux SDK. Xcode's toolchain cannot use that SDK.
  - Add `scripts/build-guest-agent.sh` for owners who install it.
  - Local agent builds are optional. `scripts/fetch-guest.sh` remains the normal path.

## Tests

**Unit tests, run in CI:**
- Framing: round trips; partial reads split at every byte; oversized and truncated frames;
  unknown types.
- Every message type's `Codable` round trip.
- The version handshake, including a mismatch.
- `GuestAgentClient` against the agent session code over a `socketpair` on macOS, covering:
  - pipe mode with stdin, stdout, stderr, and an exit code;
  - PTY mode and resize;
  - a signal forwarded to a `sleep`, which exits with 128 plus the signal number.
- A fuzz-style test: 10,000 random frames thrown at the session code. It must not crash and
  must close only the connection.

**Integration tests** (`.integration`, run on the owner's Mac through
`scripts/integration-test.sh`):
- `--exec -- uname -a` prints a `Linux … 6.18` line and exits 0.
- `--exec -- sh -c 'exit 3'` exits 3.
- stdin: piping `hello` into `cat` prints `hello`.
- stdout and stderr stay separate.
- SIGINT during `--exec -- sleep 100` exits with 130, then the VM shuts down cleanly.
- `--shell` through the pty harness:
  - `stty size` reflects the initial size, and changes after a resize;
  - `~.` detaches;
  - the terminal is restored.
- Clean shutdown: the console log shows `shutdown: clean` within 2 seconds of the request.
- Latency: within one running VM, run `true` 100 times through the client and record the
  median and p95 round-trip time.

## Docs

- `docs/protocol.md`: transport, framing, every message with its fields, the handshake,
  exit-code semantics, limits, and versioning rules.
- The new decision record for PID 1 and supervision.
- `README.md`: update "Booting the guest" for `--exec` and `--shell`.
- `docs/ROADMAP.md`: split row 04 into **04 Guest agent** and **04b CLI and daemon (XPC)**,
  and mark 04 as done when finished.

## Out of scope

- XPC, the `macwsl` CLI actions, and LaunchAgent registration (phase 04b).
- Users and login shells of a real distribution (phase 05).
- `/mnt/mac` and working-directory translation (phase 07).
- Networking and port forwarding (phase 08).

## Acceptance criteria

- `swift build -Xswiftc -warnings-as-errors`, `swift test`, and
  `swift format lint --strict` pass, and CI and the Guest workflow are green.
- The four commands under "Goal" behave as described on the owner's Mac, and each leaves
  `shutdown: clean` in the console log.
- `scripts/integration-test.sh` passes every integration test.
- The PR records the following:
  - the agent binary size and the initramfs size before and after;
  - the boot-to-agent-ready time (median of 5);
  - the exec latency (median and p95 of 100);
  - the clean shutdown time.
- The owner confirms `--shell` on the Turkish keyboard:
  - `~.` detaches;
  - `vi` and `top` render correctly;
  - resizing the window changes `stty size`.

## How to work

1. Present a short plan first. It must cover:
   - the frame layout and the message list;
   - how the agent multiplexes connections and child processes;
   - how PTY and signal handling work on Linux;
   - how CI obtains the Static Linux SDK.

   Wait for approval.
2. Guest builds take about 10 minutes. Push early as a draft PR so that the Guest workflow
   runs while you write host-side code.
3. Ask the owner to run the interactive acceptance checks. You cannot type on their
   keyboard.
4. Finish with the PR, as described in the Workflow section of `CLAUDE.md`.
