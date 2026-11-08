# The maw daemon

`mawd` owns every virtual machine. `maw`, and from phase 11b the terminal app, are its clients.
They talk to it over XPC. For a session, the daemon has the guest agent open a vsock
connection to it and hands that connection's descriptor to the client, which runs the guest
protocol (`docs/protocol.md`) itself, so terminal bytes never pass through the daemon.

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

The daemon matches a name against the installed distributions without regard to case, and
uses the stored spelling from then on, so that one disk never gets two machines
(`DistributionStore.installedDistribution(named:)`). The exact lookup comes first; on a
case-insensitive APFS volume it already finds `Ubuntu-24.04` for `ubuntu-24.04`. Only when it
finds nothing does the daemon read every installed distribution's metadata and compare the names
lowercased, which covers case-sensitive volumes. A session that names its distribution exactly
therefore reads only that distribution's metadata. `-d`, `--set-default`, and `--terminate`
resolve names this way; a name that matches no installed distribution, including one that is
only being installed, fails with `distributionNotInstalled`.

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
- **Terminate.** `maw --terminate <name>` stops one distribution's machine the same way (see
  "Terminating one distribution").
- **Failure.** A machine that fails to start reports the error to every waiting request and
  stays stopped. A machine that stops on its own, or with an error, is marked stopped, its
  sessions end with the reason, and the next session starts it again. A guest that powers off
  before its agent answers fails the start with `vmFailed`, "the guest powered off before its
  agent answered", unless the initramfs reported a failed root file system check (below).
- **Settings.** A distribution's machine gets every CPU of the Mac and half of its memory, its
  disk with full synchronization, and a NAT network device with the MAC address in its
  `distro.json`. Its kernel command line carries `maw.root=/dev/vda` and `maw.clock=<seconds>`.
  The initramfs machine keeps the defaults of phase 03: the smaller of 4 and the number of host
  CPUs, and 2 GiB of memory.
- **The dial-back listener.** When a machine reaches the running state, the daemon sets a
  `VZVirtioSocketListener` on its vsock port 19800 (`AgentProtocol.dialBackPort`). When the
  machine stops, it removes the listener and ends the wait of every session that has not
  received its connection yet. The listener exists only inside the daemon's process; only the
  machine's guest can reach it (docs/security.md).

### Terminating one distribution

`maw --terminate <name>` sends `terminate(name)`; launchd starts the daemon if it is not
running. The daemon resolves the name (see "Machines"), logs the request with the client's
process ID, and calls `MachineRegistry.terminate(_:reason:)` for that distribution's machine
with the reason `maw --terminate was run`. By the machine's state:

| State | What happens | `wasRunning` |
|-------|--------------|--------------|
| Stopped | Nothing; no machine starts. | false |
| Stopping | The request waits for that stop. | false |
| Starting | The request waits for the start to finish, and then continues as for Running. If the start fails, the machine is stopped already. | true, or false after a failed start |
| Running | The idle timer is cancelled, every lease ends and its client receives `sessionEnded` with the reason, and the machine stops as on `shutdown`: a clean shutdown through the guest agent, then Virtualization.framework's stop request, then a forced stop, with the limits of `VirtualMachine.stop(timeout:)`. | true |

The daemon replies `terminated` once the machine has stopped, and `maw` prints nothing. Other
machines are not affected. A session on the terminated distribution ends with `machineStopped`
naming the reason, after its terminal is restored; the next session starts the machine again,
as after an idle stop.

- **Why a start is not cancelled.** `VirtualMachine.forceStop` does nothing while a machine
  starts (CR-8, [docs/known-limitations.md](known-limitations.md), phase 12b). Waiting costs the
  rest of the boot: about 0.4 s normally, and up to 30 s if the agent never answers.
- **A request during the stop** waits for it and then starts the machine again, as under
  "Lifecycle".
- **A session that waits for the same start.** When the start finishes, the waiting session
  and the terminate request resume in the registry in an order that is not defined. If the
  session resumes first, it takes a lease and then ends with `machineStopped` naming
  `maw --terminate`. If the terminate request resumes first, the session finds the machine
  stopping, waits, and starts a new machine. Either outcome is correct; no test depends on
  which occurs.
- **Installations.** A distribution that is being installed has nothing in `distros/` under its
  name until the installer registers it, so `--terminate` of that name fails with
  `distributionNotInstalled` and does not affect the installation. Once it is registered, it is
  installed: a `--terminate` during the installer's first boot (the `start` step) waits for
  that boot and then stops the machine, and the installation still reports success.

### A root file system that fails its check

Before it mounts a distribution's disk, the initramfs runs `Guest/initramfs/maw-check-root`,
which runs `e2fsck -p` and prints e2fsck's exit status on the console in a line of its own:

```
maw-initramfs: root-check e2fsck-status=<status>
```

A line that explains the status follows it, and e2fsck's own messages precede it; all of them
are in the machine's console log. The distribution boots with a status below 4, and otherwise
the initramfs powers the machine off without mounting the disk:

| Status | e2fsck(8) | Outcome |
|--------|-----------|---------|
| 0 | no errors | boots |
| 1 to 3 | errors corrected (2: reboot requested, which a file system that is not mounted does not need) | boots; the console log records the status |
| 4 to 7 | errors left uncorrected | `rootFileSystemCheckFailed` |
| 8 to 15 | operational error, which includes a disk that cannot be opened and a superblock that cannot be read | `rootFileSystemCheckFailed` |
| 16 and more | usage error (16), cancelled (32), library error (128), or a shell's status for a program that could not run or was killed | `rootFileSystemCheckFailed` |

`VirtualMachineHandle` follows a distribution machine's console from its start until the line
`maw-initramfs: starting systemd`, and keeps the last marker before it
(`RootFileSystemCheckScanner`). Only the exact marker line is read, never e2fsck's free-form
output. If the guest powers off before its agent answers, the daemon waits until the console
has passed on every line, and fails the start with `rootFileSystemCheckFailed` if the marker's
status did not allow the boot. Without a marker, as with guest files from before it, or after a
status that allowed the boot, the error is `vmFailed` as before. The marker only selects the
error; the daemon takes no action on it.

The error names the distribution and the path of its console log, and says what the status
establishes: errors that e2fsck left uncorrected for 4 to 7, and for 8 and more only that the
check could not be completed, which is not proof that the disk is damaged. Its suggestion says
that the disk image is kept where it is and that nothing but `e2fsck -p` has written to it,
that it should be copied to a safe place before any repair by hand, and that maw has no repair
command yet. maw never deletes, reformats, or writes to the disk image on this path.

### Opening a session

Every session, whether `maw`'s, the installer's, or `mawd debug-boot`'s, runs on a connection
that the guest agent dials ([decision record 0017](decisions/0017-dial-back-for-sessions.md)):

1. The daemon opens a connection to the agent (port 19799).
2. Once that connection exists, it registers a new 32-byte nonce with the machine's
   `DialBackGate`, so that the time the connect takes does not count against the nonce. The
   nonce is valid for 5 seconds from then; at most 64 sessions of a machine wait at once. The
   daemon then sends its version and `dialBack` with the nonce, and checks the agent's version
   before it reads the reply.
3. The agent binds a source port below 1024, connects to port 19800 within 2 seconds, sends
   the nonce first, replies `dialedBack`, and closes the request connection.
4. The listener admits the connection, reads exactly its 37-byte nonce frame within 2 seconds,
   and gives the connection to the session whose nonce it carries. Connections from a source
   port of 1024 or above, connections while no session waits, connections beyond the waiting
   sessions plus 4 that have not sent their nonce, and connections with any other nonce are
   refused or closed; the console log records each refusal, at most 5 in 10 seconds.
5. The daemon hands the connection's descriptor, positioned after the nonce frame, to the
   client in `sessionOpened`.

The connections that the daemon opens itself carry only `info`, `shutdown`, and `dialBack`,
whose replies it reads in full at once. A session's output on such a connection could stop the
machine's vsock device while the client did not read it (docs/protocol.md, "Flow control and
ordering").

A dial-back can fail in three ways, each with its own error:

| Error | Situation | Suggested fix |
|-------|-----------|---------------|
| `sessionDialBackFailed` | The agent replied `dialBackFailed`: no source port below 1024 was free, binding one failed, or its connection was refused or did not complete within 2 seconds. The message gives the agent's reason. | Run the command again. If it fails again, restart the virtual machines with `maw --shutdown`; the console log in `~/Library/Logs/maw` has the agent's warning. |
| `sessionDialBackMissing` | The agent replied `dialedBack`, but no connection with the session's nonce arrived within the nonce's 5 seconds. | Run the command again. If it fails again, restart the virtual machines with `maw --shutdown`; the virtual machine's console log in `~/Library/Logs/maw` lists the connections that were refused. |
| `sessionDialBackBusy` | 64 sessions of the machine were already waiting for their connections. | Wait for other sessions to start, then run the command again. |

### Console logs

Each machine writes its console to `~/Library/Logs/maw/<machine>.log`, for example
`Ubuntu-24.04.log`, together with the daemon's notes about it (lines starting with `[mawd]`).
The provisioning machine of an installation writes to `install/<name>.log`, in a directory of
its own, so that it never shares a file with a distribution's console log: a distribution named
`install-foo` writes `install-foo.log`. No distribution may be named after another file there
(`mawd`, `debug-boot-console`, `initramfs`, in any case).

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
  effect. Between the two, it waits until launchd has removed the previous job, which launchd
  keeps until the daemon has exited, for up to 30 seconds of time that the Mac is awake.
- `mawd uninstall` asks a running daemon to stop its machines, unloads the agent, and removes
  the plist and the lock file.

## The XPC interface

### Messages

Every message is an XPC dictionary (`Sources/MawXPC/InterfaceCoding.swift`):

| Key | Type | Content |
|-----|------|---------|
| `interfaceVersion` | uint64 | `DaemonInterface.version`, currently **3**. This key never changes. |
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
| `openSession(MachineID?)` | `sessionOpened(SessionInfo)` plus `descriptor` | Starts the machine if needed and has its guest agent dial a connection (see "Opening a session"); `nil` is the default distribution's machine. The client owns the descriptor and runs the guest protocol over it with `GuestAgentClient`. `SessionInfo` names the machine. |
| `status` | `status(DaemonStatus)` | The daemon's version, process ID, and uptime, whether it may run virtual machines, and each machine with its state, uptime, CPUs, memory, and session count. |
| `shutdown` | `shutdownComplete(ShutdownSummary)` | Stops every machine and ends its sessions. Returns once they have stopped. |
| `install(InstallRequest)` | `installed(InstallSummary)` | Installs a distribution. The reply comes when the installation has finished; meanwhile the daemon sends `installProgress` events. `InstallRequest` holds the catalog name, an optional name to install under, the user, the password as a `Secret`, and the Mac's locale. |
| `checkInstall(distribution:name:)` | `installPossible` | Checks what can be checked before the account is known: the distribution is in the catalog, the name is free and not being installed, and the volume has room. `maw --install` sends it before it asks for the account; `install` checks the same again. |
| `cancelInstall` | `installCancelled(wasRunning:)` | Cancels this connection's installation, and replies once its traces are removed; the installation's own reply is then `failure(installationCancelled)`. An installation that has already registered the distribution finishes instead, and `wasRunning` is false; so is it for one that had already ended, successfully or not. The daemon sends the installation's own reply before this one, but in `maw` the two replies resume different tasks, which run in either order. When `wasRunning` is false, `maw` therefore waits up to 500 ms for the installation's reply and reports what it says: installed, or the failure. Without the reply, it reports that whether the distribution was installed is not known (`installationOutcomeUnknown`). |
| `listDistributions` | `distributions(DistributionList)` | Every installed distribution, by stored name and sorted by name, each with a `DistributionState` (`stopped`, `starting`, `running`, or `stopping`), and the effective default: the one `state.json` names if it is installed, otherwise the first installed one by name. With nothing installed, the list is empty and the default is absent; clients report that. It starts no machine. |
| `setDefault(DistroName)` | `defaultSet(DistroName)` | Resolves the name (see "Machines") and records the stored spelling in `state.json`, which is written atomically. The reply carries the stored spelling. It starts no machine. |
| `terminate(DistroName)` | `terminated(TerminateSummary)` | Resolves the name and stops that one machine (see "Terminating one distribution"). The reply comes once the machine has stopped. `TerminateSummary` holds whether this request stopped the machine and how many sessions ended. |

Any request can be answered with `failure(MawError)`, which carries the error unchanged; the
client shows its message and suggested fix. A daemon without a distribution store, as in some
unit tests, lists nothing and answers `setDefault` and `terminate` with
`distributionNotInstalled`.

Version 3 added `listDistributions`, `setDefault`, and `terminate`.

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
own, so that the connection can still cancel it. Before it downloads anything, it refuses a
name reserved for maw's own log files (see "Console logs"), an installed name, a name being
installed by another connection, a name under which anything is left in `distros/` in any
case (`distributionDirectoryExists`), an invalid user or password, and too little free space.
`ImageCache` downloads over HTTPS into `~/Library/Caches/maw/images` and
verifies the SHA-256 before every use. `VirtualProvisioningMachine` boots the initramfs with the
new disk and runs each step as a command through the guest agent; the image is decompressed on
the Mac and streamed to `bsdtar` in the guest. [docs/distributions.md](distributions.md) lists
the steps and what they change.

An installation is cancelled when its client sends `cancelInstall`, when the client's
connection closes, and when the daemon receives SIGTERM: the provisioning machine stops at once,
and the staging directory is removed before the cancellation is confirmed. A cancellation
during the image check stops the check before its next 4 MiB read; the check then has no
result, the image is not read, the provisioning machine does not boot, and the cached file
stays for the next check.

Each daemon builds new distributions in `distros/.staging/<label>/`, named by its own launchd
label, so that daemons of different labels, such as the integration tests' and the user's,
never remove each other's installations in progress. At start, while it holds its lock, the
daemon removes what a crash left in its own label's directory, and nothing of another label's.
Staging directories of earlier builds, `distros/.staging-<name>-<id>/`, carry no label; the
daemon removes them only when no other daemon holds its lock, because a daemon creates staging
directories only while it holds its lock, and otherwise keeps them for a later start. Creating
and removing staging directories never follows a symbolic link below `distros/`. The label
must be 1 to 128 letters, digits, `.`, `-`, and `_`, start with a letter or digit, and contain
no `..`, so that it names exactly one directory.

The password is in the daemon's memory only while the installation runs, travels to the
guest as `chpasswd`'s standard input, and never appears in a log, a description, or an error
message.

`state.json` in `~/Library/Application Support/maw` records the default distribution. An
installation that registers its distribution while none is installed makes it the default;
of two installations that run at once, the first to register does. If `state.json` names a
distribution that is no longer installed, the default is the first installed one by name.
`maw --set-default <name>` records another installed distribution as the default through the
`setDefault` request, whether or not any machine runs, and starts none. Plain `maw` and
`maw --list` see the new default at once, and it survives a restart of the daemon.

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
| `~/Library/Logs/maw/install/<name>.log` | The console of the machine that provisioned `<name>`, from its last installation attempt. Earlier builds wrote `install-<name>.log`; those files stay where they are. |
| `~/Library/Logs/maw/debug-boot-console.log` | The console of the machine that `mawd debug-boot` boots, without the daemon. |

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

Without arguments, the script runs the tests in the three groups of `scripts/test-groups.sh`,
each one test at a time, and then checks that every test ran in exactly one group ([decision
record 0018](decisions/0018-test-groups.md)). Arguments, such as `--filter`, are passed to a
single `swift test` instead, without the groups and the check.

The script fails the run if a boot of any machine started the guest agent more than once,
according to the console logs: each boot starts it once, and a second start means that it
exited and ended every session it served. When a test fails, the agent restarted, or the run
left something behind, the script saves the agent's journal from the test distribution into
the test daemon's log directory, keeps that directory with the daemon's log and every console
log, and prints its path. Otherwise it deletes it.

## Known limitations

[docs/known-limitations.md](known-limitations.md) lists every deferred item, with its phase.

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
  refuses the names `initramfs`, `mawd`, and `debug-boot-console`, in any case, whose console
  logs would be the initramfs machine's, the daemon's, or `mawd debug-boot`'s log files.
- maw has no command to repair a distribution whose root file system failed its check. The
  disk image stays where it is, unchanged except for what `e2fsck -p` repaired before it
  stopped, and a repair needs e2fsck from a Linux system, run on a copy. Phase 06, which manages
  installed distributions, is where such a command belongs: it would boot the initramfs
  machine with the disk attached, as the installer does, and run e2fsck interactively or with
  `-y` after the user has made a copy.
- A session's connection can end on the host's side while the guest's side stays open.
  Virtualization.framework did this, rarely, to connections that the agent dials: in phase 05's
  integration runs, one running session's connection ended in the middle of a frame, and in
  bursts of 64 sessions a connection that the daemon had accepted was reset (Part 5a of pull
  request #19 records the evidence; the cause is not established).
  - **What the user sees.** `maw` prints `sessionConnectionEnded`: the connection to the
    session ended unexpectedly, the output may be incomplete, and the command may still be
    running. The output received before the end stays printed, and a terminal is restored
    first. If the daemon reports within a second that the machine stopped, the error is
    `machineStopped` instead, as for any session whose machine stops.
  - **The command keeps running.** The agent never learns that the host has gone, so it does
    not send the command SIGHUP. The machine's idle stop counts only the daemon's leases
    (`MachineRegistry.scheduleIdleStopIfUnused`), and the lease ends when `maw` exits, so the
    command does not keep the machine running: it runs until the machine stops, 60 seconds
    after its last session ends (`DaemonTimeouts.machineIdle`), later while other sessions keep
    the machine running, or until the user ends it, with `kill` through `maw -e`, or with
    `maw --shutdown`, which stops every running distribution.
  - **The exit status is 1**, the status of every runtime error (`CommandFailure`), which cannot
    be told apart from a command that itself exits with 1.
  - **Phase 06.** Once `maw --terminate` exists, the suggestion should name
    `maw --terminate <name>`, which ends the command with its distribution only.
  - **Phase 12b, a mitigation; both options change the protocol.**
    - **The client asks the daemon to end the session in the guest.** On an unexpected end,
      `maw` asks the daemon, over XPC, to have the agent end that session's process, for
      example with a new request on a host-opened connection that names the session. It acts
      at once, but only when `maw` sees the end and the daemon still answers, and it needs a
      way to name a session to the agent.
    - **Session connections carry a keepalive.** The host sends a small frame at an interval,
      and the agent treats a connection that has carried none for several intervals as a dead
      host and hangs up the command, as it does when the host closes. It works whatever the
      client does, but it detects the end only after the timeout, adds traffic to every idle
      session, and must not mistake a `maw` that Ctrl-Z stopped for a dead host.
