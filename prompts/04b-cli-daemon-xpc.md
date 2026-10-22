# Phase 04b: CLI and daemon (XPC)

Read `CLAUDE.md`, `docs/decisions/`, and `docs/protocol.md` first. Work on branch
`phase/04b-cli-daemon` from the latest `main`.

Phase 04 runs commands in the guest from a development command, `mawd debug-boot`, which boots
a virtual machine for each command and stops it afterwards. This phase moves virtual machine
ownership into the daemon, `mawd`, and makes the `maw` command line its first client. No Linux
distribution exists until phase 05, so every command in this phase runs in the minimal guest
that the initramfs provides.

## Goal

At the end of this phase, these commands work on the owner's Mac, with `.build/debug` on the
`PATH`:

```sh
scripts/sign-dev.sh && mawd install    # register the daemon with launchd
maw -- uname -a                        # prints the guest's uname and exits 0
maw -e sh -c 'exit 3'; echo $?         # prints 3
echo hello | maw -e cat                # prints hello
maw                                    # an interactive shell with a real terminal
maw --status                           # the daemon, its machines, and their sessions
maw --shutdown                         # stops every machine
```

The first command after the daemon starts boots the virtual machine. Later commands reuse it.
Two `maw` shells in two terminals share one virtual machine.

## Architecture

### Machines

- The daemon owns every virtual machine. A **machine** is one virtual machine and its state,
  identified by a `MachineID`. In this phase the only machine is the **initramfs machine**: the
  kernel and initramfs with no disk, as `debug-boot` boots them today. Phase 05 adds one
  machine per distribution, backed by its disk image, without changing the daemon's interface.
- `MachineID` is a small enum (`.initramfs`, and later `.distribution(DistroName)`), defined in
  a portable module so that the interface can carry it.
- **Choosing the machine.** `maw` resolves the distribution as phase 05 will: `-d <name>`, or
  the default distribution. Until a distribution can be installed, there is none, and:
  - without `-d`, commands run on the initramfs machine. Keep this fallback in one clearly
    marked place, so that phase 05 can replace it with a "no distribution installed" error;
  - with `-d <name>`, `maw` fails with a new `MawError` case saying that no distribution with
    that name is installed, with `maw --install` as the suggested fix.
- **Start and stop.**
  - A machine starts on its first session. Concurrent requests during start wait for the same
    start; they never start a second virtual machine.
  - A machine stops 60 seconds after its last session ends. Phase 12 makes the timeout
    configurable through `~/.mawconfig`; keep it a single named constant until then.
  - Stopping uses `VirtualMachine.stop(timeout:)` from phase 04, so the console log still
    records `shutdown: clean`.
  - A machine that fails or stops unexpectedly is marked stopped, its sessions end with an
    error, and the next session starts it again.
- **Console logs.** Each machine writes its console to `~/Library/Logs/maw/<machine>.log`.

### The daemon and launchd

- `mawd` runs as a per-user LaunchAgent with the label `dev.maw.mawd`, and vends one Mach
  service with the same name. launchd starts it on demand when a client connects. It does not
  run at load.
- **Registration during development.** `CLAUDE.md` names `SMAppService`, which requires the
  daemon to live inside an app bundle. That bundle arrives with packaging in phase 13. Until
  then:
  - `mawd install` writes `~/Library/LaunchAgents/dev.maw.mawd.plist` and loads it with
    `launchctl bootstrap gui/<uid>`. The plist runs the absolute path of the `mawd` that ran
    the command, with `mawd serve` as the arguments, and sends standard output and error to
    `~/Library/Logs/maw/mawd.log`.
  - `mawd install` is idempotent. When the agent is already loaded, it replaces the plist and
    restarts the daemon, so that a rebuilt `mawd` takes effect.
  - `mawd uninstall` unloads the agent, stops its machines cleanly first, and removes the
    plist.
  - Record this in a decision record (next free number), including how phase 13 moves to
    `SMAppService`, and update `CLAUDE.md` to match.
- **`mawd serve`** is the daemon itself. It exits when it has had no client and no running
  machine for 5 minutes, so that an idle daemon costs nothing; launchd starts it again on the
  next connection.
- **Signature.** A `mawd` that lacks the virtualization entitlement must not fail obscurely.
  The client receives `MawError.virtualizationEntitlementMissing`, whose suggestion names
  `scripts/sign-dev.sh` and `mawd install`.
- `SIGTERM` from launchd stops every machine cleanly before the daemon exits.

### The XPC interface

- **API choice.** Use the Swift XPC API (`XPCListener`, `XPCSession`) if it can pass a file
  descriptor on macOS 14; otherwise use the C XPC API, wrapped at the boundary. Do not use
  `NSXPCConnection` unless both fail. Record the choice and the reason in a decision record.
- **Messages.** Requests and replies are `Codable` and versioned. The first exchange on every
  connection carries the interface version; a mismatch fails with a `MawError` that tells the
  user to run `mawd install` again.
- **Requests.**
  - `openSession(machine)`: starts the machine if needed, connects to its guest agent over
    vsock, and returns the connection's file descriptor. The client then runs the phase 04
    protocol itself, with `GuestAgentClient`, so terminal bytes never pass through the daemon.
  - `status`: the daemon's version and process ID, and each machine with its state, uptime,
    memory and CPU configuration, and session count.
  - `shutdown`: stops every machine and ends their sessions.
- **Session lease.** A session counts as active while the client's XPC connection that opened
  it stays open. When the client exits, crashes, or closes the connection, the daemon releases
  the session. This drives the 60-second machine timeout without trusting the client to
  report.
- **Peer validation.** Accept only peers that run as the same user and whose code signature
  satisfies a requirement that names the maw executables. Ad-hoc signed development builds
  must pass. Document the requirement, and how it tightens to a team identifier once phase 13
  signs the binaries.
- **The client library.** Put the client side in a new library target, `MawClient`, without
  AppKit, so that the terminal app can use it in a later phase. It connects, checks the
  version, and maps every failure to a `MawError`:
  - the agent is not installed: suggest `mawd install`;
  - the daemon cannot be reached or exits mid-request: say so, and point to
    `~/Library/Logs/maw/mawd.log`.

### The `maw` command line

- **Actions implemented in this phase:** opening a shell, running a command (`maw <command>`
  and `maw -- <command>`), running a command directly (`-e`), `--status`, `--shutdown`, and
  `--version`. Every other action keeps its `notImplemented` error, which now names the phase
  that adds it.
- **Commands and shells.**
  - `maw` with no command runs `/bin/sh -l`.
  - `maw <command> [<argument>...]` passes the arguments, joined with spaces, to `/bin/sh -c`,
    as `wsl.exe` passes its command line to the shell.
  - `maw -e <command> [<argument>...]` runs the command directly, without a shell.
  - Phase 05 replaces `/bin/sh` with the user's login shell in the distribution.
- **Terminal or pipes.** Use a pseudo-terminal when standard input and standard output are
  both terminals, and pipes otherwise. In terminal mode, put the local terminal in raw mode,
  forward window size changes, and always restore the terminal, also on errors and signals.
  In pipe mode, keep standard output and error separate, and forward `SIGINT`, `SIGTERM`, and
  `SIGHUP`.
- **No escape sequences.** `maw` sessions end when the command or shell exits, as in
  `wsl.exe`. The `~.` escapes stay in `debug-boot`, which keeps its current behavior.
- **Environment and directory.** Pass `TERM` from the host. Run in `/` unless `--cd` names an
  absolute Linux path. Translating macOS paths is phase 07; a relative or macOS path fails with
  an error that says so. `-u` fails with a message that users arrive in phase 05.
- **Exit status.** `maw` exits with the command's exit status, following phase 04 (128 plus
  the signal number for a signal). When the session ends because the machine stopped, `maw`
  prints the reason and exits 1.
- **`--status`** prints the daemon and its machines in the style of `maw --list --verbose`.
  When the daemon is not running, it says so and exits 0; that is a normal state.
- **`--version`** prints the versions of `maw`, of the daemon when it is reachable, and of the
  installed guest files from their `manifest.json`.
- **Shared code.** Move the terminal handling that `debug-boot` already has (raw mode, window
  size, signal routing) into a module both executables use, instead of duplicating it.

## Tests

**Unit tests, run in CI:**
- `Codable` round trips of every interface message, and the version check, including a
  mismatch.
- The daemon's machine registry against a fake machine: concurrent session requests start one
  machine; the last lease released starts the 60-second timer; a new session cancels it; a
  failed machine ends its sessions and starts again on the next request. Use an injectable
  clock, so that no test sleeps for real.
- The daemon's own idle exit, with the same clock.
- The command line: action to request mapping, the `sh -c` command construction (spaces,
  quotes, and empty arguments), terminal-or-pipe selection, and every error message added in
  this phase.
- The LaunchAgent plist that `mawd install` writes, compared with an expected document.

**Integration tests** (`.integration`, through `scripts/integration-test.sh`):
- They must not disturb the owner's installed daemon. Register the daemon under a separate
  test label and Mach service name, and remove it afterwards, also when a test fails.
- `maw -- uname -a` prints a `Linux … 6.18` line and exits 0.
- `maw -e sh -c 'exit 3'` exits 3; standard input reaches `cat`; standard output and error
  stay separate.
- `SIGINT` during `maw -e sleep 100` exits with 130, and the machine keeps running.
- Two concurrent `maw -e sleep 2` share one machine (`--status` shows one machine and two
  sessions).
- The machine stops after the idle timeout, shortened for the test through a hidden option or
  environment variable, and its console log records `shutdown: clean`.
- `--shutdown` stops a machine with an active session; the session's `maw` exits 1 with a
  message.
- A shell through the pty harness: `stty size` follows a resize, `exit` returns, and the
  terminal is restored.
- Killing the daemon with `SIGKILL` during a session: `maw` reports it, and the next command
  starts a new daemon and a new machine.
- **Measurements**, recorded in the PR:
  - cold start: from no daemon and no machine to the end of `maw -e true`;
  - warm latency: the median and p95 of 100 runs of `maw -e true` on a running machine.

  Targets: cold start under 1.5 s, warm median under 50 ms. If a target is missed, report the
  number and where the time goes.

## Docs

- `docs/daemon.md`: machines and their lifecycle, the XPC interface and its messages, the
  session lease, peer validation, registration with launchd, and the log files.
- The decision records named above: the XPC API, and registration during development.
- `README.md`: a "Using maw" section with the install command, putting `.build/debug` on the
  `PATH`, the commands under "Goal", `mawd uninstall`, and where the logs are.
- `CLAUDE.md`: the registration note in the architecture section.
- `docs/ROADMAP.md`: mark 04b as done.

## Out of scope

- Installing distributions, users, and login shells (phase 05).
- `--list`, `--set-default`, `--terminate`, `--export`, `--import`, and `--unregister`
  (phases 05 and 06).
- macOS path translation for `--cd` and the working directory (phase 07).
- Configurable timeouts, memory, and CPUs, and sleep and wake handling (phase 12).
- `SMAppService` and bundling the daemon into the app (phase 13).
- Connecting the terminal app to the daemon (phase 11b).

## Acceptance criteria

- `swift build -Xswiftc -warnings-as-errors`, `swift test`, and `swift format lint --strict`
  pass, and CI is green. `App/MawTerminalKit` is unchanged.
- The commands under "Goal" behave as described on the owner's Mac.
- `scripts/integration-test.sh` passes every integration test, and the PR records the
  measurements.
- `mawd uninstall` leaves no plist and no running daemon, and `maw` then prints the
  not-installed error with its fix.
- The owner confirms the interactive checks on the Turkish keyboard:
  - in a `maw` shell, `vi` and `top` render correctly, Ctrl-C reaches the guest, and resizing
    the window changes `stty size`;
  - two shells in two terminals run at the same time, and `maw --status` shows one machine
    with two sessions;
  - after `exit` in both, the machine stops within about a minute.

## How to work

1. Present a short plan first. It must cover:
   - the XPC API and how the file descriptor reaches the client;
   - the daemon's actors and the machine state machine;
   - how the session lease and the timers work;
   - how integration tests run without touching the installed daemon.

   Wait for approval.
2. Ask the owner to run the interactive checks. You cannot type on their keyboard.
3. Finish with the PR, as described in the Workflow section of `CLAUDE.md`.
