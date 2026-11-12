# 0020: Distribution figures come from the host, and from the guest only where the host cannot know them

- Status: Accepted
- Date: 2026-11-12

## Context

Phase 11c fills the distributions screen's MEMORY, CPU, DISK, UPTIME, and KERNEL cells, its
details box, and its memory chart ([prompt](../../prompts/11c-distribution-figures.md)). Each
figure could come from the Mac or from the guest. The screen must follow every change of a
machine's state, cost nothing while no screen is visible, and never start a machine or keep one
running.

## Decision

- **The host gives what it can measure correctly:** CPU, DISK, UPTIME, KERNEL, the boot time,
  the default user, the disk image's path, and the host memory. **The guest gives only what the
  host cannot know:** the memory in use inside the guest and its IPv4 address, through a new
  `sample` request (protocol version 5, [docs/protocol.md](../protocol.md#sample)).
- **The daemon samples only while a client watches**, with `watchDistributions(after:)`, a long
  poll over one held connection (daemon interface version 4,
  [docs/daemon.md](../daemon.md#watching-the-distributions)). Its `FigureSampler` samples every
  running distribution at once when watching starts or when a machine starts running while
  watched, and then every 1.5 seconds. It never starts a machine and takes no lease.
- **CPU and host memory come from the machine's process on the Mac**, which the daemon finds at
  the first sample of each run (below).

## Evidence

Measured on 2026-11-11 on macOS 27.0.1, on an Apple silicon Mac with 16 GB of memory, with a
copy of `mawd` signed ad hoc with `Resources/mawd.entitlements` and the identifier
`dev.maw.mawd-experiment`, and three C programs built with `clang -O2` in the session's
scratchpad: `rusage <pid>` (`proc_pid_rusage` with `RUSAGE_INFO_V4`: user and system time,
`ri_phys_footprint`), `lockpid <file>` (`fcntl(F_GETLK)` for a write lock), and
`findvm <file>` (the lookup below). The guests were booted with
`mawd debug-boot --cpus 4 --memory 2G [--disk <scratch>.img --create-disk 2G] --exec -- sh -c '<script>'`
while the host read the machine's process once a second. The load average was not recorded.

- **The machine's process.** Virtualization.framework runs each virtual machine in a process
  of its own,
  `/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine`,
  whose parent is launchd (process 1) and whose user is the daemon's user
  (`ps -axo pid,ppid,user,etime,comm`), not inside `mawd`. Apple documents neither the process
  nor its ID. During an 8-second busy loop on one vCPU
  (`sleep 4; ( while :; do :; done ) & p=$!; sleep 8; kill $p`), `rusage` on the process rose
  from 158 ms to 7,140 ms of CPU time; idle, an initramfs guest cost about 1 ms of CPU per
  second.
- **Why CPU comes from the host.** The guest's `/proc/stat` (`head -1 /proc/stat`, `USER_HZ`
  100) gives the share of the machine's vCPUs that Linux keeps busy: the idle field rose by
  4,798 in 12 s on 4 vCPUs, and the user field by 1,000 during 10 s of one busy loop. It misses
  the work that the Mac does for the guest's disk, network, and vsock. The process's CPU time is
  what the Mac spends, and is what Activity Monitor shows.
- **Why MEMORY comes from the guest.** After the guest filled 600 MB of tmpfs
  (`dd if=/dev/zero of=/tmp/m/z bs=1M count=600`) and removed it, its `MemAvailable` went from
  1.98 GB to 1.36 GB and back to 1.98 GB, while the process's footprint rose from 108 MB to
  710 MB and stayed there, because the memory balloon is not driven (phase 12). The footprint is
  kept as the `host memory` figure.
- **The memory limit** is the configured size, half of the Mac's memory. The guest's `MemTotal`
  is about 51 MB smaller (2,044,624 kB of 2,097,152 kB on a 2 GiB machine), because the kernel
  reserves memory.
- **Why DISK comes from the host.** `stat -f "size=%z blocks=%b" disk.img` on the stopped
  `Ubuntu-24.04` gave 4,640,824 blocks of 512 bytes (2.2 GiB) of 274,877,906,944 bytes
  (256 GiB). On a scratch disk, writing 300 MB and deleting it left 301 MiB allocated while the
  guest's `df` showed the space free at once; `fstrim` on its mount point brought the image to 1 MiB within
  a second, because Virtualization.framework passes discards to APFS. Ubuntu runs
  `fstrim.timer` weekly. The host's figure is the space on the Mac, and is known in every state.
- **Why the IP address comes from the guest.** `/var/db/dhcpd_leases` is readable, but had no
  entry for `Ubuntu-24.04`'s MAC address among its 253 leases (`grep -c "{"`), because the
  guest's DHCP client does not identify itself by it.
- **Uptime, kernel, and boot time** are already in the daemon: `MachineRegistry` keeps the time
  since running, `VirtualMachineHandle.start()` receives `info`'s `kernelRelease` and measures
  the time to the agent, and the guest files' `manifest.json` names the kernel of the next
  start.
- **Why a new request rather than `exec`.** A sample through `exec` of `cat /proc/meminfo`
  takes two connections and the whole `dialBack` exchange before the `exec` starts. [Decision
  record 0017](0017-dial-back-for-sessions.md), "Evidence", timed that exchange over 200 warm
  sessions: opening the request connection 476 µs, starting a thread 90 µs, the version
  exchange 220 µs, `dialBack` to `dialedBack` 806 µs, back to the daemon's task 80 µs, and
  until the dialed connection is in hand 30 µs, a total median of 1,809 µs (medians of steps do
  not add up to the median of the total); 8 blocks of 50 sessions gave a median of 2,285 µs.
  On top come the `exec`, its `started` and `exited` messages, a new process in the guest
  (200 runs of busybox `cat /proc/meminfo` in the initramfs took 20 ms, 0.1 ms each; Ubuntu's
  dynamically linked `cat` was not measured), and a lease, which would keep the machine running;
  and it depends on the distribution's `/bin/cat`. `sample` takes one host-opened connection,
  as `info` does: the first three steps above, 786 µs of medians, one small reply, and no
  process.
- **Why a long poll.** Pushed events are queued by libxpc without bound for a client that does
  not read, and a timer in the app sees a state change up to one interval late. A long poll
  delivers a state change at once, and the client paces the replies, one at a time.
- **The process lookup.** `lockpid` on the disk image of a running machine reported the write
  lock with process ID −1, so the lock cannot name the process. `findvm` lists the process IDs
  (`proc_listallpids`), keeps those whose executable (`proc_pidpath`) is the path above and
  whose user (`PROC_PIDTBSDINFO`) is the caller's, and only for those lists the open files
  (`PROC_PIDLISTFDS`, `PROC_PIDFDVNODEPATHINFO`) to match the disk image by device and inode.
  Among 905 processes, it found exactly one process in 6.5, 3.7, and 3.4 ms on three runs. The
  daemon's lookup (`Sources/MawDaemonKit/MachineProcess.swift`) does the same, keeps the
  process's ID with its start time, and checks the start time at each sample, so that a reused
  process ID is never read. In the integration tests on 2026-11-12, it took a median of 9 ms
  over 5 runs.
- **The risk.** If Apple changes the process model, the lookup finds nothing, and CPU and host
  memory stay empty; they are never wrong. `MachineProcessIntegrationTests` and
  `FigureIntegrationTests` fail in that case.

## What it costs

Development measurements with `scripts/measure-figures.sh` and its `FigureMeasurements` suite,
on the Mac above, macOS 27.0.1, on 2026-11-12. The Mac was in use: the load averages, which
`sysctl -n vm.loadavg` gave at the start and end of each run, are listed. They are not the
owner's official measurements, which run on an idle Mac and decide whether the conclusions
below stand.

| Measurement | Median | 95th percentile | Target | Run |
|-------------|--------|-----------------|--------|-----|
| First figures from the start of a watch | 17.0 ms | 27.5 ms | under 500 ms | 2 |
| First CPU figure from the start of a watch | 1,531 ms | 1,568 ms | under 3 s | 2 |
| A state change by `maw --terminate`, to a watcher | 30.2 ms | 36.6 ms | under 500 ms | 1 |
| One sample in the daemon, from the request to the reply (4,991 samples) | 3.88 ms | 7.95 ms | median under 5 ms | 3 |
| The guest agent's CPU time per `sample` request (5 batches) | 1.155 ms | 1.225 ms | under 0.5 ms | 3 |
| The guest agent's CPU time per `info` request (5 batches) | 0.821 ms | 1.221 ms | none | 3 |
| The machine's process CPU time per `sample` request | 4.18 ms | 4.30 ms | none | 3 |
| The machine's process CPU time per `info` request | 3.20 ms | 3.38 ms | none | 3 |
| Over 60 s, watched, one distribution running: `mawd` | 0.418 % | 0.462 % | under 0.5 % of one core | 1 |
| The same: the guest agent | 0.079 % | 0.111 % | under 0.1 % | 1 |
| The same: the machine's process, above its cost unwatched | 0.372 % | 0.396 % | under 0.2 % | 1 |
| The same: `mawd`'s resident memory growth | 0.047 MiB | 0.156 MiB | under 1 MiB | 1 |
| `mawd` unwatched, one distribution running | 0.003 % | 0.004 % | none | 1 |

- **Run 1**, 13:12 to 13:32 UTC, on the code committed as `ed8ed06` to `1039eef` (the script's
  header names `238fa91`, which was `HEAD` when it started), guest files `34dc80b`, load average
  2.91, 5.36, 6.60 at the start and 2.11 at the end. Its first batch also gave 1.948 ms of agent
  CPU per sample and a sample request median of 4.02 ms (95th percentile 9.22 ms).
- **Run 2**, about 14:16 UTC, at `b090939`, load average 3.81 at the start and 3.20 at the end.
- **Run 3**, 14:20 to 14:44 UTC, at `7e6f5cb`, load average 5.32 at the start and 2.20 at the
  end. The agent's idle cost, 0.03 % of one core, is subtracted from each batch.
- The agent's CPU time is read from `/proc/<pid>/stat` (10 ms ticks) before and after a batch
  of 1,000 requests, on the test daemon with the hidden `--sample-interval-ms 100`; the `info`
  batches add `--sample-with-info`, which sends `info` in place of `sample`
  ([docs/daemon.md](../daemon.md#the-daemon)).

**Where the time goes.** `info` is the fixed cost of a request on a host-opened connection: the
connection, the agent's thread, the version exchange, and a small reply. It costs 0.82 ms in the
agent and 3.2 ms in the machine's process. Reading `/proc/meminfo` and `/proc/net/route` and
calling `getifaddrs` add 0.33 ms in the agent and about 1.0 ms in the machine's process. At one
sample every 1.5 seconds, 1.155 ms of agent time is 0.077 % of one core, which matches the 60 s
window's 0.079 %. Run 1's 1.95 ms against run 3's 1.155 ms is not explained; a busier Mac may
inflate the guest's CPU accounting, which the guest's `steal` time would show, and was not
measured.

**Two targets are missed, and the owner accepted both on 2026-11-12:** the guest agent's CPU
time per sample (1.155 ms against 0.5 ms), and the machine's process over 60 s (0.372 % above
its unwatched cost against 0.2 %). The fixed cost of one request alone exceeds both. The cost is
a fraction of one percent of one core, and only while a distributions screen is visible; with
no screen visible it is zero. The targets in the prompt stay as they are. Reusing one
host-opened connection for every sample of a run would remove most of the fixed cost; it changes
the protocol and the guest files, and is recorded under phase 12b in
[docs/known-limitations.md](../known-limitations.md#phase-12b-hardening). Sampling every 3
seconds instead would halve the cost and the chart's resolution, and was not chosen.

## Consequences

- A machine that runs while nothing watches costs nothing: no lookup, no sample, no timer.
- The guest's figures are guest input: decoded strictly, displayed only, never logged
  ([docs/security.md](../security.md#figures-from-the-guest)).
- The lookup reads the open files of the user's Virtualization processes, including other
  programs' virtual machines
  ([docs/security.md](../security.md#finding-a-machines-process)).
- A host and guest files of different protocol versions refuse each other, and an app built
  before interface version 4 fails with `daemonVersionMismatch` until it is rebuilt.
