# The maw daemon

`mawd` owns every virtual machine. `maw`, and from phase 11b the terminal app, are its clients.
They talk to it over XPC. For a session, the daemon connects to the guest agent over vsock and
hands that connection's descriptor to the client, which runs the guest protocol
(`docs/protocol.md`) itself, so terminal bytes never pass through the daemon.

The code is in `Sources/MawXPC` (the interface and the XPC wrapper), `Sources/MawDaemonKit`
(the daemon), `Sources/MawClient` (the client library), and `Sources/mawd/Serve.swift`.

## Machines

A **machine** is one virtual machine and its state, identified by a `MachineID`
(`Sources/MawCore/MachineID.swift`):

- `.distribution(DistroName)`: one per installed distribution, which boots its disk with
  systemd as PID 1 ([decision record 0013](decisions/0013-systemd-and-the-agent.md)).
- `.initramfs`: the guest kernel and initramfs with no disk, as `mawd debug-boot` boots them.
  `maw` no longer uses it; the installer provisions disks with a machine of the same kind that
  it owns itself (see "Installing distributions").

`maw -d <name>` names a distribution's machine; without `-d`, `maw` asks for the default
distribution, which the daemon resolves from `state.json`. With nothing installed, the request
fails with `noDistributionInstalled`, whose suggestion names `maw --install`.

### Lifecycle

`MachineRegistry` (`Sources/MawDaemonKit/MachineRegistry.swift`) holds one slot per machine:

```
stopped ──openSession──▶ starting ──agent answers info──▶ running ──idle / shutdown──▶ stopping
   ▲                        │ start fails                    │ stops unexpectedly          │
   └────────────────────────┴────────────────────────────────┴─────────────────────────────┘
```

- **Start.** A machine starts on its first session. Starting includes waiting, up to 30
  seconds, for the guest agent to answer `info`. Requests that arrive during the start wait
  for the same start; a request that arrives while the machine stops waits for the stop and
  then starts it again. A machine never runs twice.
- **Idle stop.** A machine stops 60 seconds after its last session ends
  (`DaemonTimeouts.machineIdle`; phase 12 makes it configurable in `~/.mawconfig`). A new
  session cancels the timer.
- **Clean stop.** Stopping uses `VirtualMachine.stop(timeout:)`, so the console log records
  `shutdown: clean after <n> ms via the guest agent`, or how it stopped otherwise.
- **Failure.** A machine that fails to start reports the error to every waiting request and
  stays stopped. A machine that stops on its own, or with an error, is marked stopped, its
  sessions end with the reason, and the next session starts it again.
- **Settings.** A distribution's machine gets every CPU of the Mac and half of its memory, its
  disk with full synchronization, and a NAT network device with the MAC address in its
  `distro.json`. Its kernel command line carries `maw.root=/dev/vda` and `maw.clock=<seconds>`.
  The initramfs machine keeps the defaults of phase 03: the smaller of 4 and the number of host
  CPUs, and 2 GiB of memory.

### Console logs

Each machine writes its console to `~/Library/Logs/maw/<machine>.log`, for example
`Ubuntu-24.04.log`, together with the daemon's notes about it (lines starting with `[mawd]`).
The provisioning machine of an installation writes to `install.log`.

## The daemon

- **`mawd serve`** is the daemon. launchd runs it when a client connects; it does not run at
  load.
- **Idle exit.** It exits after 5 minutes with no connected client and no running machine
  (`DaemonTimeouts.daemonIdle`), so that an idle daemon costs nothing.
- **SIGTERM.** On SIGTERM (from launchd, `mawd install`, or `mawd uninstall`), SIGINT, or
  SIGHUP, it stops every machine cleanly before it exits.
- **Running or not.** It holds an exclusive `flock` on
  `~/Library/Application Support/maw/<label>.lock`. Clients that only want to know whether the
  daemon runs, such as `maw --status`, check the lock, because connecting would start the
  daemon.
- **Missing entitlement.** A `mawd` without the virtualization entitlement still starts. It
  logs the problem, `maw --status` shows a warning, and every session fails with
  `virtualizationEntitlementMissing`, whose suggestion names `scripts/sign-dev.sh` and
  `mawd install`.

## Registration with launchd

`mawd install` registers the daemon as a per-user LaunchAgent; `mawd uninstall` removes it.
`docs/decisions/0011-launchctl-registration.md` explains why this is not `SMAppService` yet, and
how phase 13 moves to it.

| | |
|---|---|
| Label and Mach service | `dev.maw.mawd` |
| Plist | `~/Library/LaunchAgents/dev.maw.mawd.plist` |
| Program | the absolute path of the `mawd` that ran `mawd install`, with `serve` |
| Output | `~/Library/Logs/maw/mawd.log` (standard output and error) |
| `RunAtLoad`, `KeepAlive` | absent: launchd starts the daemon on demand and does not restart it |
| `ProcessType` | `Interactive` |

- `mawd install` is idempotent. When the agent is already loaded, it replaces the plist and
  restarts the daemon (`launchctl bootout`, then `bootstrap`), so that a rebuilt `mawd` takes
  effect.
- `mawd uninstall` asks a running daemon to stop its machines, unloads the agent, and removes
  the plist and the lock file.

## The XPC interface

### Messages

Every message is an XPC dictionary (`Sources/MawXPC/InterfaceCoding.swift`):

| Key | Type | Content |
|-----|------|---------|
| `interfaceVersion` | uint64 | `DaemonInterface.version`, currently **2**. This key never changes. |
| `body` | data | the message, JSON-encoded from the `Codable` types in `Sources/MawXPC/DaemonInterface.swift` |
| `descriptor` | fd | only in `sessionOpened`: the guest agent connection |

The receiver checks the version before it decodes the body, so that any two versions can
detect a mismatch even when their bodies differ. Any change to the messages, their fields, or
their meaning increments the version. Clients and the daemon come from the same build, so
there is no negotiation.

**Requests** (client to daemon), each answered by one reply:

| Request | Reply | Meaning |
|---------|-------|---------|
| `hello(clientVersion)` | `welcome(DaemonInfo)` | The first request on every connection. `DaemonInfo` holds the daemon's maw version, process ID, and interface version. |
| `openSession(MachineID?)` | `sessionOpened(SessionInfo)` plus `descriptor` | Starts the machine if needed and connects to its guest agent; `nil` is the default distribution's machine. The client owns the descriptor and runs the guest protocol over it with `GuestAgentClient`. `SessionInfo` names the machine. |
| `status` | `status(DaemonStatus)` | The daemon's version, process ID, and uptime, whether it may run virtual machines, and each machine with its state, uptime, CPUs, memory, and session count. |
| `shutdown` | `shutdownComplete(ShutdownSummary)` | Stops every machine and ends its sessions. Returns once they have stopped. |
| `install(InstallRequest)` | `installed(InstallSummary)` | Installs a distribution. The reply comes when the installation has finished; meanwhile the daemon sends `installProgress` events. `InstallRequest` holds the catalog name, an optional name to install under, the user, the password as a `Secret`, and the Mac's locale. |
| `cancelInstall` | `installCancelled(wasRunning:)` | Cancels this connection's installation, and replies once its traces are removed. The installation's own reply is then `failure(installationCancelled)`. |

Any request can be answered with `failure(MawError)`, which carries the error unchanged; the
client shows its message and suggested fix.

**Events** (daemon to client, without a request):

| Event | Meaning |
|-------|---------|
| `sessionEnded(SessionEnded)` | A session's machine stopped. `reason` says why, for example `maw --shutdown was run`. The daemon sends it before it stops the machine, so it normally arrives before the guest connection closes. |
| `installProgress(InstallProgress)` | This connection's installation started or finished a step (`download`, `verify`, `prepare`, `format`, `extract`, `configure`, `finish`, `start`, with its duration), or downloaded more (bytes, total, rate, and where it resumed), at most five times a second. An event can arrive after the reply it precedes; `maw` waits briefly for the last step's event. |

### The version check

- **The daemon** answers a request whose `interfaceVersion` differs with
  `failure(daemonVersionMismatch)`, and any request before `hello` with
  `failure(daemonProtocolError)`.
- **The client** checks the version of every reply first. A mismatch fails with
  `daemonVersionMismatch`, whose suggested fix is to run `mawd install` again, so that launchd
  runs the daemon from the same build as the client.

### Installing distributions

`Installer` (`Sources/MawDaemonKit/Installer.swift`) runs each installation on a task of its
own, so that the connection can still cancel it. It refuses an installed name, a name being
installed by another connection, an invalid user or password, and too little free space before
it downloads anything. `ImageCache` downloads over HTTPS into `~/Library/Caches/maw/images` and
verifies the SHA-256 before every use. `VirtualProvisioningMachine` boots the initramfs with the
new disk and runs each step as a command through the guest agent; the image is decompressed on
the Mac and streamed to `bsdtar` in the guest. [docs/distributions.md](distributions.md) lists
the steps and what they change.

An installation is cancelled when its client sends `cancelInstall`, when the client's
connection closes, and when the daemon receives SIGTERM: the provisioning machine stops at once,
and the staging directory is removed before the cancellation is confirmed. At start, the daemon
removes staging directories that a crash left behind. The password is in the daemon's memory
only while the installation runs, travels to the guest as `chpasswd`'s standard input, and
never appears in a log, a description, or an error message.

`state.json` in `~/Library/Application Support/maw` records the default distribution: the
first one installed. Phase 06 adds `maw --set-default`.

### The session lease

A session counts as active while the XPC connection that opened it stays open. When the client
exits, crashes, or closes the connection, libxpc invalidates the daemon's side, and the daemon
releases every lease the connection holds. That drives the 60-second idle timer without
trusting the client to report anything.

A connection should therefore open one session. `maw` opens one connection per invocation; the
terminal app will open one per tab.

### The client library

`DaemonClient` (`Sources/MawClient/DaemonClient.swift`) has no AppKit dependency. It connects,
exchanges `hello`, and maps every failure to a `MawError`:

| Situation | Error |
|-----------|-------|
| The plist is missing, or launchd has not loaded it | `daemonNotInstalled`, fix: `mawd install` |
| launchd refused the connection although the agent is loaded | `daemonUnreachable` |
| The daemon exited before it answered `hello` | `daemonUnreachable` |
| The daemon exited, or closed the connection, during a request or a session | `daemonConnectionLost` |
| The interface versions differ | `daemonVersionMismatch`, fix: `mawd install` |
| This process is not signed as the daemon requires | `clientSignatureRejected`, fix: `scripts/sign-dev.sh` |

The daemon-related errors point to `~/Library/Logs/maw/mawd.log`. An interrupted connection is
final: libxpc would send the next message to a new daemon process, which knows neither the
client nor its sessions, so the client cancels the connection and reports the loss.

## Peer validation

The daemon accepts a connection only if both checks pass (`XPCServiceListener`):

1. **Same user.** `xpc_connection_get_euid` of the peer equals the daemon's effective user.
2. **Code signature.** The peer satisfies the code signing requirement
   (`PeerRequirement.codeSigningRequirement`):

   ```
   identifier "dev.maw.maw" or identifier "dev.maw.mawd"
   ```

   It is set with `xpc_connection_set_peer_code_signing_requirement` before the connection is
   activated, and libxpc checks every message against it. `mawd` is included because
   `mawd uninstall` asks the daemon to stop its machines.

`scripts/sign-dev.sh` signs the development builds ad hoc with these identifiers. A plain
`swift build` relinks them with a signature whose identifier is derived from the file name,
such as `maw-5555…`, which the daemon rejects. Because a rejected client sees only an
interrupted connection, `DaemonClient` checks its own identifier first and reports
`clientSignatureRejected`.

### What the requirement protects against

With ad-hoc signing, the identifier requirement guards against accidents, not against a
malicious process: any local program can be signed ad hoc with any identifier, so it can claim
`dev.maw.maw`. It keeps unrelated or stale builds, such as a `maw` relinked by `swift build`,
from driving the daemon. Until phase 13 signs with a team identifier, the same-user check is
the effective boundary: only processes of the user who owns the daemon, who can already run
`mawd` and its virtual machines directly, can use it.

### Tightening in phase 13

Phase 13 signs the executables with a Developer ID. The requirement then names the team as
well, which only Apple's certificate chain can satisfy:

```
anchor apple generic and certificate leaf[subject.OU] = "<TEAM ID>" and
(identifier "dev.maw.maw" or identifier "dev.maw.mawd" or identifier "dev.maw.app")
```

### The terminal app

Phase 11b, which connects the terminal app to the daemon, adds the app's identifier,
`dev.maw.app`, to `PeerRequirement.identifiers`.

## Log files

| File | Content |
|------|---------|
| `~/Library/Logs/maw/mawd.log` | The daemon's own log: start, machines starting and stopping and why, sessions opened and released, errors. launchd sends the daemon's standard output and error here. |
| `~/Library/Logs/maw/<machine>.log` | One machine's console, with the daemon's notes, including how each shutdown went. |
| `~/Library/Logs/maw/install.log` | The console of the last installation's provisioning machine. |

The daemon also logs to the unified log, subsystem `dev.maw`, categories `daemon` and `xpc`:

```sh
log stream --predicate 'subsystem == "dev.maw"'
```

## Testing without the installed daemon

`scripts/integration-test.sh` registers a second daemon with the hidden options of
`mawd install`: the label and Mach service `dev.maw.mawd.integration-test`, logs in a temporary
directory, and a machine idle timeout of 3 seconds. It sets `MAW_DAEMON_LABEL` so that the
`maw` processes of the tests connect to it, and removes the agent when it exits, also when a
test fails or the script is interrupted. `MAW_DAEMON_LABEL` is not meant for users.

## Known limitations

- A connection that arrives while an idle daemon is exiting is interrupted, and the command
  fails with `daemonUnreachable`; running it again starts a new daemon. The window is the time
  between the idle decision and the process's exit.
- launchd starts a job at most once every 10 seconds (the default `ThrottleInterval`). When the
  daemon ends within 10 seconds of its start, for example because it was killed or crashed,
  the next command waits up to the rest of those 10 seconds. A daemon that exits after its
  idle timeout is not affected.
- The daemon does not detect that a client of the same interface version comes from another
  build. `hello` carries the client's maw version, and the daemon logs a difference.
- A distribution's machine and its console log are named after the distribution. The installer
  refuses the name `initramfs`, which would share the initramfs machine's console log.
