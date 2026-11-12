# Phase 11c: Live figures on the distributions screen

Read `CLAUDE.md`, `docs/decisions/`, `docs/design/terminal/`, `docs/protocol.md`,
`docs/daemon.md`, `docs/security.md`, and `docs/known-limitations.md` first. The phase is
delivered in two pull requests (see "Pull requests"). Work on branch
`phase/11c-distribution-figures` from the latest `main` for the first, and on
`phase/11c-figures-on-screen` from `main` after the first has merged for the second.

Phase 11b made the distributions screen list the installed distributions with their state and
the default, and left the MEMORY, CPU, DISK, UPTIME, and KERNEL cells, the details box, and the
memory chart empty. This phase fills them with live figures, and makes an open screen follow
every change of a machine's state, whoever caused it.

Keep this phase small. Anything that is not needed for the features below goes into a separate
`fix/` branch or into `docs/known-limitations.md`, not into these pull requests. Pull request A
may add at most 1,800 lines outside `Tests/`, and pull request B at most 1,000. If a part would
take its pull request beyond its cap, stop and ask the owner before going on.

## Goal

At the end of this phase, on the owner's Mac, with the daemon installed and `Ubuntu-24.04` the
default distribution:

- **The table shows live figures.** A running distribution shows its memory in use, its CPU
  use, the space its disk image takes on the Mac, its uptime, and its kernel. A stopped one shows
  its disk and the kernel it boots next. Nothing shows a placeholder.
- **The details box and the memory chart** appear for the selected distribution once it has
  data for them, as `Distributions.dc.html` draws them, with the deviations listed below.
- **The screen follows the daemon.** A machine that starts or stops for any reason, such as a
  tab in another window, `maw` in a terminal, or the idle stop, changes its row while the
  screen is in view.
- **Reading figures costs nothing while no screen is visible**, and never starts a machine or
  keeps one running.

## Product requirements

### What each figure means

| Cell | Meaning | Source |
|------|---------|--------|
| MEMORY | Memory in use inside the guest: `MemTotal` minus `MemAvailable` from `/proc/meminfo`, which `free` in Ubuntu 24.04 reports as used. | The guest, through the new `sample` request. |
| CPU | The CPU time of the machine's process on the Mac (`com.apple.Virtualization.VirtualMachine`) over the last interval, in percent of one core, as Activity Monitor shows that process. It includes the work that Virtualization.framework does for the guest's devices, and may exceed 100 %. | The host: `proc_pid_rusage` on the machine's process. |
| DISK | The space the disk image takes on the Mac's volume (its allocated blocks), and the image's size, which is the most it can grow to: `2.2G/256G`. It falls when the guest discards blocks, for example with `fstrim`. | The host: `stat` on `disk.img`. |
| UPTIME | Time since the machine reached the running state. | The daemon's `MachineRegistry`. |
| KERNEL | Running: the kernel release that the guest agent reported when the machine started. Otherwise: `kernel.release` in the installed guest files' `manifest.json`, which the next start boots. | The daemon. |

- The memory chart shows MEMORY over the last 60 seconds, one bar per sample, 40 bars, scaled
  to the machine's memory size, which its caption names as the limit (`412M now · 8.0G limit`).
- Units: binary, as in the board: `412M`, `1.2G` (one decimal below 10), `256G`. CPU with one
  decimal below 10 %, and whole numbers above (`0.4%`, `37%`, `180%`). Uptime as `37s`, `41m`,
  `2h 14m`, `3d 2h`.

### The four states

A figure that is not known is an empty cell or an absent row, never a placeholder such as `—`
or `0`.

| State | MEMORY | CPU | DISK | UPTIME | KERNEL | Details box | Memory chart |
|-------|--------|-----|------|--------|--------|-------------|--------------|
| starting | empty | empty | shown | empty | manifest | default, user, disk image | absent |
| running | from the first sample | from the second sample | shown | shown | agent's | default, user, ip, disk image, boot, host memory | from the first sample |
| stopping | empty | empty | shown | empty | manifest | default, user, disk image | absent |
| stopped | empty | empty | shown | empty | manifest | default, user, disk image | absent |

- A figure that cannot be read, for example because the guest does not answer in time, is
  empty for that sample; the row keeps its other figures.
- If the disk image cannot be read, DISK is empty; if the manifest cannot be read, KERNEL is
  empty for a machine that does not run.

### The details box

In the board's order, with its colors (`DistributionInfo.Detail.Role`):

| Key | Value | Notes |
|-----|-------|-------|
| `default` | `yes` or `no` | |
| `user` | the default user from `distro.json` | Phase 12 adds `/etc/maw.conf`'s setting. |
| `ip` | the guest's IPv4 address on the interface of its default route | Running only. |
| `disk image` | the image's path, with the home directory as `~`, truncated in the middle | |
| `boot` | `271 ms to agent`: from the start of the machine to its agent's answer, as the daemon logs it | Running only. |
| `host memory` | the memory footprint of the machine's process on the Mac | Running only. |

### Deviations from `Distributions.dc.html`

1. Unknown values are empty, where the board draws `—`, as the design README requires. This
   includes the memory chart's caption, which falls back to `—` today
   (`MemoryChartBox.caption` in `App/MawTerminalKit/Sources/MawTerminalKit/Views/DistributionsScreen.swift`).
2. The details box has no `forwarded` and `mounts` rows until phases 08 and 07 add port
   forwarding and `/mnt/mac`; drawing them empty or with `—` would be a placeholder.
3. The details box adds `host memory`. Until phase 12 drives the memory balloon, the machine's
   process keeps the memory that the guest has freed, so MEMORY and what Activity Monitor shows
   differ; the row shows the second.
4. DISK's first number is the space the image takes on the Mac, which the board's `3.1G/64G`
   does not specify.
5. The details box and the memory chart appear independently, each once the selected
   distribution has data for it: a stopped distribution shows the details box without the chart.
6. The chart's limit is the machine's memory size, half of the Mac's memory (`8.0G` on a 16 GB
   Mac), where the board shows `2.0G`.
7. The board's start, restart, export, and unregister actions stay out, as in phase 11b.

### Speed targets

Measure in code, through the daemon and the provider, not by watching the screen.

- **Development measurements.** The session runs them while it works, and records them in the
  pull request with their date and the Mac's load average, marked as development measurements.
- **Official measurements.** The owner runs them, under the owner's rule: a restarted, idle Mac
  on AC power, Low Power Mode off, `caffeinate -dims`, only Terminal open besides what is
  measured. Provide one script for them, `scripts/measure-figures.sh`, which pull request A adds
  for its measurements and pull request B extends for the app's. It registers the test daemon
  as `scripts/integration-test.sh` does, runs every measurement 5 times, and prints for each
  measurement its median and its 95th percentile, with the date, the commit, and the guest
  files' version. The app's costs are measured in-process, in a harness that shows the screen
  in a window, as phase 11b measured its flood of output; nothing records the screen. The pull
  request records the owner's output.

| Measurement | Target |
|-------------|--------|
| From the screen becoming visible, with the daemon running, to the first figures of a running distribution (DISK, UPTIME, KERNEL, MEMORY) | under 500 ms |
| From the screen becoming visible to the first CPU figure | under 2 sampling intervals (3 s) |
| From a machine's state change in the daemon, caused by another client, to the provider's new state | under 500 ms |
| One sample of one running machine in the daemon, from the request to the reply | median under 5 ms |
| The guest agent's CPU time per sample | under 0.5 ms |

If a target is missed, report the number, where the time goes, and what would close the gap.

### Limits on cost

| Situation | Limit |
|-----------|-------|
| No distributions screen visible (no window shows it, or every window that shows it is minimized or covered) | No sample, no request, no held connection to the daemon. The daemon's idle exit and every machine's idle stop behave as before. |
| A screen visible, nothing running | One held XPC connection; no sample and no timer in the daemon. |
| A screen visible, one distribution running, over 60 s | `mawd`: under 0.5 % of one core. The guest agent: under 0.1 % of one core. The app: under 1 % of one core above its cost with the screen hidden. The machine's process: under 0.2 % of one core above its cost with the screen hidden. `mawd`'s resident memory grows by under 1 MiB. |
| Any number of windows showing the screen | One request stream from the app, and one sample per machine per interval in the daemon, however many clients watch. |

`scripts/measure-figures.sh` measures these limits as well.

### Experience rules

- **The app never invents data.** Every figure comes from the daemon. Unknown figures are
  empty, also in the chart's caption.
- **Figures never change a machine.** Reading them never starts a machine, takes no lease, and
  does not delay the idle stop: a distribution with no session stops after the idle timeout
  while the screen shows it.
- **The screen follows the daemon.** A state change by any client, or by the idle stop,
  reaches an open screen within the target above. A distribution installed or made the default
  through the daemon appears without reselecting the screen.
- **The selection stays on its distribution** as rows update, as in phase 11b.
- **Errors keep phase 11b's rules.** When the daemon cannot be reached, the screen shows maw's
  message and suggestion. While the screen stays visible, the app tries again with a growing
  delay: 1, 2, 4, 8, 16, then every 30 seconds. Each attempt connects over XPC, and launchd
  starts the daemon for a connection when it does not run, so every attempt may start the
  daemon; the growing delay limits how often that can happen. When no window shows the screen
  any longer, the app stops trying, and the next time a window shows it, it starts again from
  the shortest delay.

## Architecture

### Where the figures come from

The host gives what it can measure correctly: CPU, DISK, UPTIME, KERNEL, the boot time, the
default user, the disk image's path, and the host memory. The guest gives only what the host
cannot know: memory in use inside the guest and the IPv4 address.

Record this in a new decision record, `docs/decisions/0020-distribution-figures.md`. It must
contain the following, with the commands that produced each result, and the date and macOS
version of the measurement:

- **The machine's process.** Virtualization.framework runs each virtual machine in a process of
  its own,
  `/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine`,
  whose parent is launchd (process 1) and whose user is the daemon's user, not inside `mawd`.
  Apple documents neither the process nor its ID. During an 8-second busy loop on one vCPU of a
  `mawd debug-boot` guest, the process's CPU time (`proc_pid_rusage`) rose from 158 ms to
  7,140 ms; idle, an initramfs guest cost about 1 ms of CPU per second.
- **Why CPU comes from the host.** The guest's `/proc/stat` gives the share of the machine's
  vCPUs that Linux keeps busy (at `USER_HZ` 100: the idle field rose by 4,798 in 12 s on 4 vCPUs,
  and the user field by 1,000 during 10 s of one busy loop), and misses the work the Mac does
  for the guest's disk, network, and vsock. The process's CPU time is what the Mac spends, and
  matches Activity Monitor.
- **Why MEMORY comes from the guest.** After a guest filled 600 MB of tmpfs and removed it, its
  `MemAvailable` went from 1.98 GB to 1.36 GB and back to 1.98 GB, while the process's footprint
  (`ri_phys_footprint`) rose from 108 MB to 710 MB and stayed there, because the balloon is not
  driven. The footprint is kept as the `host memory` row.
- **The memory limit.** The configured size, half of the Mac's memory. The guest's `MemTotal` is
  about 51 MB smaller (2,044,624 kB of 2,097,152 kB on a 2 GiB machine), because the kernel
  reserves memory.
- **Why DISK comes from the host.** `Ubuntu-24.04`'s image took 4,640,824 blocks of 512 bytes
  (2.2 GiB) of 256 GiB (274,877,906,944 bytes), measured with `stat` while stopped. On a
  scratch disk, writing 300 MB and deleting it left 301 MiB allocated, while the guest's `df`
  showed the space free at once; `fstrim` brought the image to 1 MiB within a second, because
  Virtualization.framework passes discards to APFS. Ubuntu runs `fstrim.timer` weekly. The
  host's figure is the space on the Mac, and is known in every state.
- **Why the IP address comes from the guest.** `/var/db/dhcpd_leases` is readable, but had no
  entry for `Ubuntu-24.04`'s MAC address among its 253 leases, because the guest's DHCP client
  does not identify itself by it.
- **Uptime, kernel, and boot time** are already in the daemon: `MachineRegistry` keeps the time
  since running, `VirtualMachineHandle.start()` receives `info`'s `kernelRelease` and measures
  the time to the agent, and `manifest.json` names the kernel of the next start.
- **Why a new request rather than `exec`.** A sample through `exec` of `cat /proc/meminfo` takes
  two connections and the whole `dialBack` exchange before the `exec` even starts. Decision
  record 0017 timed that exchange step by step over 200 warm sessions: opening the request
  connection 476 µs, starting a thread 90 µs, the version exchange 220 µs, the `dialBack`
  request to its `dialedBack` reply 806 µs, back to the daemon's task 80 µs, and until the dialed
  connection is in hand 30 µs, a total median of 1,809 µs (medians of steps do not add up to the
  median of the total). A separate measurement in 8 blocks of 50 sessions gave a median of
  2,285 µs for opening a session with the dial-back. On top of that come the `exec` itself, its
  `started` and `exited` messages, and a new process in the guest (0.1 ms per busybox `cat` in
  the initramfs; Ubuntu's dynamically linked `cat` costs more, not measured), and a lease, which
  would keep the machine running; and it depends on the distribution's `/bin/cat`. The `sample`
  request takes one host-opened connection, as `info` does: the first three steps above, 786 µs
  of medians, and one small reply, and no process.
- **Why a long poll.** Compared with pushed events, which libxpc queues without bound for a
  client that does not read, and with a timer in the app, which sees a state change up to one
  interval late: a long poll delivers a state change at once, and the client paces the replies,
  one at a time.
- **The process lookup** and its cost: among 905 processes, it found exactly one process in 3.4
  to 6.5 ms on each of three runs. `F_GETLK` on the disk image reports the lock with process ID
  −1, so the lock cannot name the process.
- **The risk:** if Apple changes the process model, the lookup finds nothing and CPU and `host
  memory` stay empty; they are never wrong. The integration tests detect it.

### The process lookup

The daemon finds a machine's process at the first sample of its run, not when the machine
reaches the running state, so that a machine that runs while nothing watches costs nothing:

1. It lists the process IDs (`proc_listallpids`) and keeps only those whose executable
   (`proc_pidpath`) is exactly the path above and whose user ID (`PROC_PIDTBSDINFO`) is the
   daemon's.
2. Only for those processes, it lists the open files (`PROC_PIDLISTFDS`,
   `PROC_PIDFDVNODEPATHINFO`) and keeps the process that has the machine's disk image open, by
   device and inode. It never lists the open files of any other process.
3. It keeps that process's ID with its start time for the rest of the run. Each sample checks
   the start time, so that a reused process ID is never read.

If the lookup finds no process, or more than one, it tries again at each following sample of the
run, at most 10 more times (about 15 seconds). After that, CPU and `host memory` stay empty for
that run, and the daemon logs once:
`<machine>: its virtual machine process was not found; CPU and host memory stay empty until it
restarts`. The guest's `sample` does not wait for the lookup, so MEMORY arrives with the first
sample in any case.

### Kernel and boot time

`VirtualMachineHandle.start()` already asks the agent for `info`, whose reply carries
`kernelRelease`, and logs `agent ready after <n> ms`. Keep both on the handle instead of
discarding them; this needs no protocol change.

### The guest's `sample` request

- A new request, `sample`, without fields, on a connection that the host opens, as `info`. The
  agent replies `sampled` with `memoryTotalBytes`, `memoryAvailableBytes`, and an optional
  `ipv4Address`, and closes the connection. The reply is a few hundred bytes, which the host
  reads in full at once, as the rule for host-opened connections requires
  (docs/protocol.md, "Flow control and ordering").
- The agent reads `/proc/meminfo`, finds the interface of the default route in
  `/proc/net/route`, and takes its IPv4 address with `getifaddrs`; it starts no process. If
  `MemAvailable` is missing, the reply is a protocol violation that the host reports as an empty
  MEMORY, not as a failure of the machine.
- This changes the protocol: increase its version to 5 and update `docs/protocol.md`. The pull
  request changes `Sources/MawProtocol` and `Sources/MawAgentKit`, which the Guest workflow
  watches, so the guest files must be rebuilt and installed (see "Installing the builds");
  a host and guest files of different versions fail with `guestAgentVersionMismatch`, as they
  do today.

### The sampler in the daemon

- A `FigureSampler` in `MawDaemonKit` samples running distribution machines while at least one
  client watches (below): the guest's `sample`, and the process's CPU time and footprint. CPU is
  the difference of two CPU times over the difference of two clock readings.
- **The first sample is immediate.** When watching starts, it samples every running machine at
  once, and then every 1.5 seconds. A machine that reaches the running state while watched is
  sampled at once as well, and then joins the 1.5-second rhythm. This is what lets the first
  MEMORY reach a screen within 500 ms.
- **The timer exists only while it is needed:** while at least one client watches and at least
  one machine runs. With watchers and no running machine, and without watchers, the sampler
  holds no timer and no task. It starts the timer again, with an immediate sample, when a
  machine reaches the running state while watched, or when watching starts while a machine runs.
- It samples only machines in the running state, at most one `sample` in flight per machine,
  with a reply timeout of 1 second. It never calls `start`, never takes a lease, and never
  touches the idle timer. A stop that begins during a sample does not wait for it.
- Each running machine has a run identifier (the registry's generation), so that a client can
  tell a restart from a continued run.

### The daemon interface

- A new request, `watchDistributions(after: UInt64)`, answered by
  `distributionSnapshot(DistributionSnapshot)`: a sequence number and every installed
  distribution with its state, the default, and its figures and details. The daemon replies at
  once if its latest snapshot is newer than `after`, and otherwise when the next one exists:
  after the next sample, or at once when a machine changes state, a distribution is installed,
  or the default changes. A connection has at most one such request outstanding.
- A connection that has sent `watchDistributions` is a watcher until it closes, as a lease
  lasts as long as its connection. The first watcher starts the sampler, and the last one's
  close stops it. The daemon logs each watcher's start and end, and never a sample, with
  exactly these messages (`DaemonLog` adds the time and `mawd: `, as in
  `2026-11-11T20:16:38.004Z mawd: <message>`):
  - `process <pid> started watching the distributions`, when a connection sends its first
    `watchDistributions`;
  - `process <pid> stopped watching the distributions`, when that connection closes.
- The held connection keeps the daemon from its idle exit, as any client does, but takes no
  lease, so every machine's idle stop is unchanged.
- `listDistributions` keeps its reply. This changes the daemon interface: increase
  `DaemonInterface.version` to 4 and update `docs/daemon.md`. A client of another version fails
  with `daemonVersionMismatch`, whose suggestion is to run `mawd install`; an app built before
  this change therefore stops working with the new daemon until it is rebuilt.
- `DaemonClient` in `MawClient` gains the request. `maw` does not use it: `maw --list
  --verbose` keeps the columns of `wsl.exe --list --verbose`.

### The app

- `DaemonDistributions`, which every window already shares, owns the only watch. Each window
  tells it whether it shows the screen: its selected tab is the distributions screen, it is not
  minimized, and its occlusion state is visible (`NSWindow.didChangeOcclusionStateNotification`).
  While any window shows it, the provider holds one connection and repeats
  `watchDistributions(after:)`; when none does, it closes the connection.
- The provider keeps each running distribution's memory history: 40 samples, 60 seconds. It
  clears a distribution's history when its run identifier changes or it leaves the running
  state, and clears all history when the watch stops, so that a gap never appears as data. A
  screen that opens therefore shows a chart that fills from the right over 60 seconds.
- The table, the details box, and the chart format the daemon's numbers as "What each figure
  means" describes. The details box and the memory chart appear independently, each once the
  selected distribution has data for it; the chart's caption shows no figure that is not known.
- The new-tab menu, the command palette, and the settings keep phase 11b's refresh when they
  open.

### Security

Add to `docs/security.md`, in pull request A:

> **Figures from the guest.** The `sample` request is a new reply from the guest, on a
> connection that the host opens. Root in the guest can report any memory figures and any
> address for its own machine; they are only displayed, in that machine's row. The host decodes
> the reply strictly, bounds its size by the frame limit, rejects a reply whose available memory
> exceeds its total, accepts the address only if it parses as an IPv4 address, and never logs
> text that the guest supplied. At most one `sample` request is in flight per machine, with a
> reply timeout of 1 second, so a guest that does not answer holds neither the daemon's threads
> nor more than one of the agent's 64 connections.
>
> **Finding a machine's process.** To read a machine's CPU time and memory footprint, the daemon
> looks for the machine's process at the first sample of the machine's run, and only while a
> client watches the distributions; a machine that runs while nothing watches is never looked
> up. It lists the process IDs and keeps only processes whose executable is
> Virtualization.framework's `com.apple.Virtualization.VirtualMachine` and whose user is the
> daemon's user. Only for those processes does it list the open files, to find the one that has
> the distribution's disk image open; it never lists the open files of any other process. These
> processes include the virtual machines of other programs of the same user, such as other
> virtualization apps; the daemon reads their open files' paths and identities, and nothing
> else, and keeps only the matching process's ID and start time. A lookup that finds nothing is
> repeated at the next samples, at most 10 times, and then given up for that run. It needs no
> privilege and gains no right.
>
> **`watchDistributions`.** The request is available to every peer that the peer check accepts.
> It reveals what `status` and `listDistributions` reveal, and the figures. The number of
> watchers does not change how often the daemon samples, a connection has at most one watch
> outstanding, and a held connection keeps the daemon running but takes no lease, so it keeps no
> machine running.

### Pull requests

- **A, `phase/11c-distribution-figures`, "Phase 11c: Distribution figures in the daemon"**, at
  most 1,800 added lines outside `Tests/`: the `sample` request and protocol version 5, the
  agent, the process lookup, the sampler, the daemon interface version 4, `DaemonClient`,
  `scripts/measure-figures.sh` for the daemon's measurements, the decision record, and the docs.
  It changes the guest files.
- **B, `phase/11c-figures-on-screen`, "Phase 11c: Live figures on the distributions screen"**,
  at most 1,000 added lines outside `Tests/`: the app's visibility, watch, history, cells,
  details box, and chart, and the app's measurements in `scripts/measure-figures.sh`. It changes
  no Guest workflow path. It updates `docs/ROADMAP.md` as described under "Docs".

## Installing the builds

Pull request A changes the guest protocol and the daemon interface. A host, guest files, and an
app from different builds refuse each other: `maw` fails with `guestAgentVersionMismatch` or
`daemonVersionMismatch`, and the app shows the second on the distributions screen and in every
Linux tab. Give the owner the procedures below in each pull request's description, and follow
them before the integration tests.

### Rules for the shared working tree

The owner and the session share `~/macwsl`, and the installed daemon runs from it.

- **One at a time.** The owner runs a procedure only while the session is idle and
  `git -C ~/macwsl status --short` prints nothing. The session says when that is the case, and
  does not work in `~/macwsl` until the owner reports the procedure done. The session itself
  runs a procedure only after it has told the owner. When the work stops, the session says which
  build is installed.
- **What "installed" means.** The installed build is two things on disk: the executable that the
  LaunchAgent names, `~/macwsl/.build/out/Products/Debug/mawd`, with `maw` next to it, and the
  guest files in `~/Library/Application Support/maw/kernel/`. Both executables belong to the
  working tree: every `swift build` in `~/macwsl` replaces them, and with them the program that
  launchd starts next. A running daemon keeps the program it started with until it exits, and
  it exits in only three ways:
  - its idle exit, 300 seconds after the last client has disconnected and the last machine has
    stopped (`DaemonTimeouts.daemonIdle`, `Sources/MawDaemonKit/MachineHandle.swift:40`), which
    writes `no client and no machine for 300.0 seconds; exiting` to `mawd.log`;
  - `mawd install`, which boots it out (below);
  - a crash.

  launchd does not restart it: the plist has neither `KeepAlive` nor `RunAtLoad`
  (`Sources/MawDaemonKit/LaunchAgent.swift:64-75`). The next connection from `maw` or the app
  starts the executable that is at that path at that moment.
- **Signed binaries.** The LaunchAgent runs `~/macwsl/.build/out/Products/Debug/mawd serve`:
  `mawd install` writes the resolved path of the executable that runs it into the plist
  (`Sources/mawd/Install.swift:29`, `resolvingSymlinksInPath()`). `scripts/sign-dev.sh` builds and
  signs `.build/out/Products/Debug/maw` and `.build/out/Products/Debug/mawd`, the directory that
  `swift build --show-bin-path` prints. `.build/debug` is a symbolic link to `out/Products/Debug`
  that every `swift build` creates again, so both names reach the same files, but every
  procedure and check uses the signed path itself. `maw` is not on the owner's `PATH`.
- **Builds unsign the installed daemon.** Every `swift build` in `~/macwsl`, including the
  acceptance commands, relinks `maw` and `mawd` in that directory with the linker's signature,
  without the virtualization entitlement and with an identifier that the daemon rejects. An
  unsigned `mawd` that launchd starts cannot boot a machine (`virtualizationEntitlementMissing`).
  The session therefore runs `scripts/sign-dev.sh` after its last build and before it reports
  idle.
- **No distribution while pull request A is half installed.** From the session's first build of
  the protocol change on pull request A's branch (protocol version 5, part A-a) until
  "Installing pull request A's build" is done, the executables on disk speak protocol version 5,
  and the installed guest files, `main`'s, speak version 4. Once the running daemon exits and a
  client starts it again, the owner's `maw` and app cannot use a distribution: the agent's
  handshake fails with `guestAgentVersionMismatch`
  (`Sources/MawProtocol/GuestAgentClient.swift:194`). The session tells the owner this before
  that first build, and keeps the period short:
  - It opens pull request A as a draft as soon as the protocol change and the agent's reply are
    committed. A push of the branch alone starts no Guest run: `push` runs only on `main`
    (`.github/workflows/guest.yml:4-5`), and the pull request's events start it (lines 21-22).
  - It runs "Installing pull request A's build", after telling the owner, as soon as that run
    has succeeded.
- **No machine runs while guest files change.** `scripts/fetch-guest.sh` does not stop machines:
  it downloads, verifies, and renames the files into
  `~/Library/Application Support/maw/kernel/`, and nothing else. Each procedure therefore stops
  every machine first, with the `maw` that is installed now, before it switches branches.
  `maw --shutdown` does nothing when the daemon does not run (`Sources/maw/Maw.swift:154`,
  `guard DaemonClient.isRunning(label: label) else { return }`). If it fails with
  `clientSignatureRejected`, a build has relinked `maw` since it was signed: run
  `./scripts/sign-dev.sh` on the current branch, then the step again.
- **`mawd install` restarts the daemon.** With the agent loaded, it runs `launchctl bootout`
  and waits up to 30 seconds until launchd has removed the job
  (`Sources/mawd/Install.swift:58-59`). The daemon handles the SIGTERM by stopping every machine
  (`Sources/mawd/Serve.swift:93`, `registry.shutdown(reason: "the maw daemon is stopping")`), one
  after another, each with the agent's `shutdown`, then Virtualization.framework's stop request,
  then a forced stop, waiting up to 5 seconds after each of the first two
  (`VirtualMachineHandle.stopTimeout`). launchd kills a daemon that has not exited 20 seconds
  after SIGTERM. Because each procedure stops the machines first, `mawd install` finds none.
- **One app.** From the first install on, the owner opens only
  `~/Library/Developer/maw-app/Build/Products/Debug/maw.app`, which each procedure builds from
  the installed commit. An app in Xcode's default folder,
  `~/Library/Developer/Xcode/DerivedData/maw-<hash>/Build/Products/Debug/maw.app`, may come from
  another commit, and one built before pull request A fails with `daemonVersionMismatch` once A
  is installed. The session's own `xcodebuild` in the acceptance criteria writes to that default
  folder: it is CI's command and checks that the app builds, and it never decides which app the
  owner opens.

### Which Guest run to install

`scripts/fetch-guest.sh [<branch>]` takes a branch name, not a run. It installs the `maw-guest`
artifact of the newest successful Guest workflow run on that branch
(`scripts/fetch-guest.sh:35-38`), and its first line names that run's commit in 12 characters:
`fetch-guest: run <id> on '<branch>', commit <12 characters>, <time>` (line 43). If the newest
run on the branch failed or has not finished, the script takes an older one. A run's artifacts
are kept for 90 days (the repository's setting; `guest.yml` sets no other).

The Guest workflow does not run for every commit (`.github/workflows/guest.yml:3-23`):

- A push starts it only on `main`, and only when the pushed commits change one of its paths.
- A pull request's events start it when the pull request as a whole, against its base, changes
  one of those paths. From then on every push to the pull request starts a run, including a push
  that changes no such path. The run builds the pushed commit itself, not GitHub's merge commit
  (`ref: ${{ github.event.pull_request.head.sha || github.sha }}`, line 46).
- `workflow_dispatch` starts it by hand (line 23).

A branch's `HEAD` may therefore have no run, and a run on a later commit than the newest change
to a watched path builds the same guest files. Each procedure accepts the newest successful run
when the newest commit that changes a watched path is its commit or an ancestor of it, and its
commit is `HEAD` or an ancestor of `HEAD`. On `main` the first condition makes the run's commit
that newest change itself, because a push to `main` starts a run only for its own changes. The
paths are copied from `guest.yml`, in quotes so that the shell does not expand `**`.

Every check below runs `.build/out/Products/Debug/maw -- uname -r`, which starts the default
distribution's machine; it stops 60 seconds after the command ends.

### Installing pull request A's build

1. The session reports that it is idle, and `git -C ~/macwsl status --short` prints nothing.
2. Quit the app.
3. `cd ~/macwsl && .build/out/Products/Debug/maw --shutdown`
4. `git switch phase/11c-distribution-figures && git pull --ff-only`
5. Check that the newest successful Guest run on the branch built the guest files of `HEAD`:

   ```sh
   guest_commit=$(git log -1 --format=%H -- 'Guest/**' '.github/workflows/guest.yml' 'scripts/fetch-guest.sh' 'scripts/build-guest-agent.sh' 'Package.swift' 'Package.resolved' 'Sources/CMawSystem/**' 'Sources/MawCore/**' 'Sources/MawProtocol/**' 'Sources/MawAgentKit/**' 'Sources/maw-agent/**')
   run_commit=$(gh run list --workflow guest.yml --branch phase/11c-distribution-figures --status success --limit 1 --json headSha --jq '.[0].headSha')
   git merge-base --is-ancestor "$guest_commit" "$run_commit" && git merge-base --is-ancestor "$run_commit" HEAD && echo "accepted: ${run_commit:0:12}"
   ```

   It must print `accepted:` and 12 characters. If it prints nothing or an error,
   `gh run list --workflow guest.yml --branch phase/11c-distribution-figures --limit 3` shows
   whether a run is in progress: wait for it and repeat this step, or report it to the session.
6. `scripts/fetch-guest.sh phase/11c-distribution-figures`. The commit in its first line must be
   the 12 characters that step 5 printed. If it is not, a newer run has succeeded in between:
   repeat steps 5 and 6.
7. `./scripts/sign-dev.sh`, which ends with `Signed .../.build/out/Products/Debug/mawd
   (dev.maw.mawd, with Resources/mawd.entitlements) and .../.build/out/Products/Debug/maw
   (dev.maw.maw).`
8. `.build/out/Products/Debug/mawd install`
9. `cd App && xcodegen && xcodebuild build -project maw.xcodeproj -scheme maw -configuration Debug -skipPackagePluginValidation -derivedDataPath ~/Library/Developer/maw-app && cd ..`
10. Check: `.build/out/Products/Debug/maw -- uname -r` prints `6.18.57-maw`; then
    `open ~/Library/Developer/maw-app/Build/Products/Debug/maw.app`, ⌘⇧L, and `Ubuntu-24.04` is
    listed without an error.
11. Tell the session that the procedure is done.

### Going back to `main` while pull request A is open

1. The session reports that it is idle, and `git -C ~/macwsl status --short` prints nothing.
2. Quit the app.
3. `cd ~/macwsl && .build/out/Products/Debug/maw --shutdown`
4. `git switch main && git pull --ff-only`
5. The check of step 5 of "Installing pull request A's build", for `main`:

   ```sh
   guest_commit=$(git log -1 --format=%H -- 'Guest/**' '.github/workflows/guest.yml' 'scripts/fetch-guest.sh' 'scripts/build-guest-agent.sh' 'Package.swift' 'Package.resolved' 'Sources/CMawSystem/**' 'Sources/MawCore/**' 'Sources/MawProtocol/**' 'Sources/MawAgentKit/**' 'Sources/maw-agent/**')
   run_commit=$(gh run list --workflow guest.yml --branch main --status success --limit 1 --json headSha --jq '.[0].headSha')
   git merge-base --is-ancestor "$guest_commit" "$run_commit" && git merge-base --is-ancestor "$run_commit" HEAD && echo "accepted: ${run_commit:0:12}"
   ```

   It must print `accepted:` and 12 characters; otherwise report it to the session.
6. `scripts/fetch-guest.sh`. The commit in its first line must be the 12 characters that step 5
   printed. If the artifact has expired, `gh workflow run guest.yml --ref main`, wait for that
   run to succeed, and repeat steps 5 and 6.
7. `./scripts/sign-dev.sh`
8. `.build/out/Products/Debug/mawd install`
9. Step 9 of "Installing pull request A's build", from `main`.
10. The check of step 10 of "Installing pull request A's build".
11. Before the session continues: `cd ~/macwsl && git switch phase/11c-distribution-figures`,
    and tell the session. `main`'s build stays installed only until the session's next
    `swift build` in `~/macwsl`, which replaces the executables with A's (see "What "installed"
    means"). When the session resumes, it therefore runs "Installing pull request A's build",
    after telling the owner, before its first build.

### After pull request A has merged

1. The session reports that it is idle, and `git -C ~/macwsl status --short` prints nothing.
2. Quit the app.
3. `cd ~/macwsl && .build/out/Products/Debug/maw --shutdown`
4. `git switch main && git pull --ff-only`
5. The check of step 5 of "Installing pull request A's build", for `main`:

   ```sh
   guest_commit=$(git log -1 --format=%H -- 'Guest/**' '.github/workflows/guest.yml' 'scripts/fetch-guest.sh' 'scripts/build-guest-agent.sh' 'Package.swift' 'Package.resolved' 'Sources/CMawSystem/**' 'Sources/MawCore/**' 'Sources/MawProtocol/**' 'Sources/MawAgentKit/**' 'Sources/maw-agent/**')
   run_commit=$(gh run list --workflow guest.yml --branch main --status success --limit 1 --json headSha --jq '.[0].headSha')
   git merge-base --is-ancestor "$guest_commit" "$run_commit" && git merge-base --is-ancestor "$run_commit" HEAD && echo "accepted: ${run_commit:0:12}"
   ```

   The merge changes guest paths, so `guest_commit` is the merge commit, and the check prints
   `accepted:` only after the merge's own run has succeeded; until then,
   `scripts/fetch-guest.sh` would install the guest files from before the merge. Wait for that
   run (`gh run list --workflow guest.yml --branch main --limit 3`) and repeat this step.
6. `scripts/fetch-guest.sh`. The commit in its first line must be the 12 characters that step 5
   printed.
7. `./scripts/sign-dev.sh`
8. `.build/out/Products/Debug/mawd install`
9. Step 9 of "Installing pull request A's build", from `main`.
10. The check of step 10 of "Installing pull request A's build".

### Installing pull request B's build

For the owner's checks before pull request B merges. `main`'s guest files after A's merge are
installed ("After pull request A has merged"); B changes no guest path, so the guest files stay.
The procedure always builds, signs, and installs B's `maw` and `mawd`, so that the owner's checks
run against B's own build.

1. The session reports that it is idle, and `git -C ~/macwsl status --short` prints nothing.
2. Quit the app.
3. `cd ~/macwsl && .build/out/Products/Debug/maw --shutdown`
4. `git switch phase/11c-figures-on-screen && git pull --ff-only`
5. `./scripts/sign-dev.sh`
6. `.build/out/Products/Debug/mawd install`
7. Step 9 of "Installing pull request A's build", from B's branch.
8. Check: `.build/out/Products/Debug/maw -- uname -r` prints `6.18.57-maw`; then
   `open ~/Library/Developer/maw-app/Build/Products/Debug/maw.app`, ⌘⇧L, and the
   `Ubuntu-24.04` row shows its figures.
9. Tell the session that the procedure is done.

### After pull request B has merged

The procedure always builds, signs, and installs `main`'s `maw` and `mawd`, so that the installed
daemon matches `main` whatever merged between pull requests A and B.

1. The session reports that it is idle, and `git -C ~/macwsl status --short` prints nothing.
2. Quit the app.
3. `cd ~/macwsl && .build/out/Products/Debug/maw --shutdown`
4. `git switch main && git pull --ff-only`
5. `./scripts/sign-dev.sh`
6. `.build/out/Products/Debug/mawd install`
7. Step 9 of "Installing pull request A's build", from `main`.
8. The check of step 8 of "Installing pull request B's build".

## Tests

**Unit tests, run in CI:**
- The `sample` and `sampled` messages: encoding, round trip, the version check, and an agent
  reply without `MemAvailable`.
- The agent's parsing of `/proc/meminfo` and `/proc/net/route` from fixture files, including
  missing fields and an absent default route.
- The process lookup against a fake process table: one match, none, two, a process of another
  user, another executable, a reused process ID, and open files read only for processes that
  passed the filter by path and user.
- When the lookup runs: never for a machine that runs while nothing watches; at the first sample
  of a run, not at the running transition; again at each following sample while it finds
  nothing, at most 10 more times, then never again in that run, with one log line; again at the
  first sample of the next run.
- The disk figures of a sparse file: the allocated size after writing and after punching a hole.
- The sampler, with fake handles and a test clock: no sample and no timer without a watcher; no
  timer with watchers and no running machine; when watching starts, every running machine is
  sampled at once, before the clock advances, and then every 1.5 s; a machine that reaches the
  running state while watched is sampled at once; the timer ends when the last running machine
  stops and returns, with an immediate sample, when one runs again; one sample per machine per
  interval with several watchers; machines that start, stop, or are stopping are not sampled;
  it never starts a machine and takes no lease; a machine with no session stops after the idle
  timeout while watched; at most one sample in flight; a sample that times out leaves MEMORY
  empty; CPU from two readings; a restart changes the run identifier.
- The daemon's log: exactly one `process <pid> started watching the distributions` and one
  `process <pid> stopped watching the distributions` per watching connection, and no line per
  sample.
- `watchDistributions`: an immediate reply, a held reply, a state change that wakes it, the end
  of watching when the connection closes, and the version check.
- In `App/MawTerminalKit`: one watch for many windows; the watch starts and stops with
  visibility, minimizing, and occlusion; the history, its limit of 40, and its resets; the four
  states of the table and the details box; the formats; the caption without unknown figures;
  the retry delays; the selection staying on its distribution.
- Tests that assert latency go into a nested `Latency` suite, and load generators into `Load`
  ([decision record 0018](../docs/decisions/0018-test-groups.md)).

**Integration tests** (`.integration`, through `scripts/integration-test.sh`):
- On a test distribution: the figures of a running machine arrive; MEMORY rises by at least
  250 MB while the guest holds 300 MB in `/dev/shm`, and falls after it is removed; CPU rises
  above 80 % while `yes > /dev/null` runs, and falls below 10 % after it ends; DISK equals the
  image's allocated size within 1 %; the process lookup finds exactly one process.
- A state change caused by `maw` reaches a watcher within the target.
- A distribution with no session stops after the test daemon's idle timeout while watched, and
  no machine starts because of a watch.
- Every test removes the distributions it created and protects the owner's `state.json`, as
  phase 06a's tests do.

## Docs

- `docs/protocol.md`: `sample`, `sampled`, and version 5.
- `docs/daemon.md`: `watchDistributions`, the sampler, the process lookup, interface version
  4, and the effect on idle exit and idle stop.
- `docs/security.md`: the text under "Security" above.
- `docs/decisions/0020-distribution-figures.md`: as described under "Where the figures come
  from".
- `README.md`: what the distributions screen shows, and the steps after a change of the guest
  protocol or the daemon interface.
- `docs/known-limitations.md`: pull request B removes "The distributions screen shows no
  figures, details box, or memory chart" and "An open distributions screen does not follow
  machines that it did not start or stop". Each pull request adds what it defers, including:
  the `forwarded` and `mounts` rows (phases 08 and 07), host memory that does not fall until the
  balloon is driven (phase 12), `/etc/maw.conf`'s default user in the details box (phase 12),
  a distribution removed by hand that an open screen does not notice while no machine runs
  (phase 06b), and figures in `maw --status` (no phase yet).
- `docs/ROADMAP.md`, in pull request B: the rows of 11c and 11 read

  ```
  | 11c | Distributions screen figures | Live memory, CPU, disk, uptime, and kernel, the details box, and the memory chart | Done    |
  | 11 | Terminal app                   | SwiftUI + SwiftTerm app: tabs, distro profiles, themes, settings         | Done    |
  ```

  and the paragraph below the table reads, with the pull requests' numbers:

  ```
  Phase 11 is delivered as phases 11a, 11b, and 11c. Phase 11b is delivered in two pull
  requests: the first (#25) adds Linux tabs in the app, and the second (#26) adds the profiles
  per installed distribution and the distributions screen's list and actions. Phase 11c is
  delivered in two pull requests: the first (#<A>) adds the figures in the daemon, and the
  second (#<B>) shows them on the distributions screen.
  ```

## Out of scope

- Port forwarding and `/mnt/mac`, and the details box's `forwarded` and `mounts` rows (phases
  08 and 07).
- Driving the memory balloon (phase 12). Until then the host memory of a machine does not fall
  when the guest frees memory.
- `/etc/maw.conf`'s default user in the details box (phase 12).
- Figures in `maw`, including `maw --list --verbose` and `maw --status`.
- Figures of the initramfs machine and of an installation's provisioning machine.
- The board's other actions: start, restart, export, install, and unregister (phases 06b and
  later).
- History that survives the screen being hidden, or a restart of the app or the daemon.

## Acceptance criteria

- The root package: `swift build -Xswiftc -warnings-as-errors`; `swift build --build-tests
  -Xswiftc -warnings-as-errors`, then `scripts/test-groups.sh all .build/test-results`;
  `swift format lint --strict --recursive Sources Tests Package.swift`.
- `App/MawTerminalKit`: `swift build -Xswiftc -warnings-as-errors`; `swift test -Xswiftc
  -warnings-as-errors --skip "/Latency/"`, then `swift test -Xswiftc -warnings-as-errors
  --skip-build --filter "/Latency/" --no-parallel`; `swift format lint --strict --recursive
  Sources Tests Package.swift`.
- The app: `cd App && xcodegen`, then `xcodebuild build -project maw.xcodeproj -scheme maw
  -configuration Debug -skipPackagePluginValidation`. This is CI's command; it writes to Xcode's
  default DerivedData folder, not to the owner's `~/Library/Developer/maw-app` (see "One app"
  under "Rules for the shared working tree").
- After these commands, which relink `maw` and `mawd`, the session runs `./scripts/sign-dev.sh`
  before it reports idle.
- CI, including the "Terminal app" job, and the Guest workflow are green.
- `scripts/integration-test.sh` passes, and each pull request records its development
  measurements and the owner's output of `scripts/measure-figures.sh` under "Speed targets".
- The owner confirms, after pull request B, with its build installed as in "Installing pull
  request B's build", the app opened from `~/Library/Developer/maw-app`, and every command run
  from `~/macwsl` in Terminal.app.
  - **Facts for the checks.** The installed daemon stops a machine 60 seconds after its last
    session ends: `public static let machineIdle = Duration.seconds(60)` in `DaemonTimeouts`
    (`Sources/MawDaemonKit/MachineHandle.swift:38`), which applies because the installed LaunchAgent
    runs `mawd serve` without the hidden `--machine-idle-timeout` (`Sources/mawd/Serve.swift:185`,
    `machineIdleTimeout.map { .seconds($0) } ?? DaemonTimeouts.machineIdle`). The clean stop takes
    about one more second (735 ms in `mawd.log` on 2026-11-11). The daemon writes its log to
    `~/Library/Logs/maw/mawd.log`, and the same lines to the unified log:
    `log stream --predicate 'subsystem == "dev.maw" AND category == "daemon"'`.
  - With `Ubuntu-24.04` running, the screen shows MEMORY, CPU, DISK, UPTIME, and KERNEL; the
    details box shows `default`, `user`, `ip`, `disk image`, `boot`, and `host memory`; and the
    chart fills over 60 seconds.
  - `.build/out/Products/Debug/maw -d Ubuntu-24.04 -- sh -c 'head -c 1G /dev/zero > /dev/shm/x; sleep 20; rm /dev/shm/x'`
    raises MEMORY and the chart by about 1 GB, and they fall afterwards.
  - `.build/out/Products/Debug/maw -d Ubuntu-24.04 -- sh -c 'timeout 15 yes > /dev/null'` shows
    CPU near 100 %, within a few percent of what Activity Monitor shows for
    `com.apple.Virtualization.VirtualMachine`.
  - `.build/out/Products/Debug/maw --terminate Ubuntu-24.04` turns the row to stopping and
    stopped while the screen stays in view, and the stopped row shows DISK and KERNEL with the
    other cells empty.
  - **The idle stop.** A Linux tab or pane holds a session, and its machine never stops while it
    is open. A new window's first tab, and ⌘T, open the new-tab profile, which is the default
    distribution unless the settings say otherwise. So, first:
    1. In every window, open the distributions screen with ⌘⇧L, then close every Linux tab, and
       every split pane that holds a Linux session, with ⌘W. A window closes only when its last
       tab closes (`removeTab` in `App/MawTerminalKit/Sources/MawTerminalKit/Window/WindowModel.swift:346`,
       `if tabs.isEmpty { host?.closeWindow() }`), and the distributions screen is a tab, so the
       window stays open with the screen alone. For a terminal, use Shell > New Tab: zsh on this
       mac, not ⌘T.
    2. Make sure that no `maw` session runs in Terminal.app.

    Then `.build/out/Products/Debug/maw -d Ubuntu-24.04 -e true` turns the row to starting and
    running without touching the app. With the screen still open, the row turns to stopping and
    stopped about 61 seconds later, and `mawd.log` shows these two lines, written by
    `Sources/MawDaemonKit/MachineRegistry.swift:258` and `:283`:

    ```
    <time> mawd: Ubuntu-24.04: no session for 60 s
    <time> mawd: Ubuntu-24.04: stopped because it was idle; shutdown: clean after <n> ms via the guest agent
    ```
  - **Watching.** Minimizing the window, or selecting another tab, writes
    `<time> mawd: process <pid> stopped watching the distributions` to `mawd.log`, and showing
    the screen again writes `<time> mawd: process <pid> started watching the distributions`,
    with the app's process ID.

## How to work

1. Present a short plan first. It must cover:
   - each figure's source and meaning, and the process lookup;
   - the `sample` message and the protocol version;
   - the sampler, its lifetime, and how it never starts or keeps a machine;
   - `watchDistributions`, its replies, and the interface version;
   - how the app decides that a screen is visible, and where the history lives;
   - the parts of each pull request, each ending with the checks passing;
   - an estimate of the added lines outside `Tests/` per pull request, against its cap.

   Wait for approval.
2. Before the first build of the protocol change, tell the owner that from then until
   "Installing pull request A's build" is done, `maw` and the app cannot use a distribution once
   the daemon restarts (see "No distribution while pull request A is half installed"). Open pull
   request A as a draft as soon as the protocol change and the agent's reply are committed, so
   that the Guest workflow builds the new guest files; a push of the branch alone starts no Guest
   run. Install them as in "Installing pull request A's build" as soon as that run has succeeded,
   and before the integration tests.
3. Ask the owner to run the interactive checks and `scripts/measure-figures.sh`. You cannot see
   the screen.
4. Finish each pull request as described in the Workflow section of `CLAUDE.md`.
