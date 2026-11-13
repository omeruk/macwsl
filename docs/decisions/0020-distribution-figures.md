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

### Official measurements

The owner's official measurements with `scripts/measure-figures.sh` and its `FigureMeasurements`
suite, on the Mac above, macOS 27.0.1, on 2026-11-13: after a restart, on AC power, with Low
Power Mode off, under `caffeinate -dims`, and with only Terminal open. The load averages are
those that `sysctl -n vm.loadavg` gave at the start and end of each run.

| Measurement | Median | 95th percentile | Target | Result | Run |
|-------------|--------|-----------------|--------|--------|-----|
| First figures from the start of a watch | 13.179 ms | 14.599 ms | under 500 ms | Met | B |
| First CPU figure from the start of a watch | 1,531.677 ms | 1,545.612 ms | under 3 s | Met | B |
| A state change by `maw --terminate`, to a watcher | 23.473 ms | 28.796 ms | under 500 ms | Met | A |
| One sample in the daemon, from the request to the reply (4,995 samples) | 3.746 ms | 7.583 ms | median under 5 ms | Met | A |
| The guest agent's CPU time per `sample` request (5 batches) | 1.473 ms | 1.687 ms | under 0.5 ms | Missed; accepted | A |
| The guest agent's CPU time per `info` request (5 batches) | 0.569 ms | 0.588 ms | none | | A |
| The machine's process CPU time per `sample` request | 4.105 ms | 4.441 ms | none | | A |
| The machine's process CPU time per `info` request | 2.900 ms | 2.977 ms | none | | A |
| Over 60 s, watched, one distribution running: `mawd` | 0.459 % | 0.462 % | under 0.5 % of one core | Met | A |
| The same: the guest agent | 0.079 % | 0.113 % | under 0.1 % | Met by the median; the 95th percentile is above | A |
| The same: the machine's process, above its cost unwatched | 0.357 % | 0.431 % | under 0.2 % | Missed; accepted | A |
| The same: `mawd`'s resident memory growth | 0.047 MiB | 0.172 MiB | under 1 MiB | Met | A |
| `mawd` unwatched, one distribution running | 0.004 % | 0.004 % | none | | A |

- **Run A**, the whole suite, from 07:45:20 UTC, at commit `6829e27` with guest files `7e6f5cb`;
  load average 1.60, 14.71, 14.42 at the start, the 5- and 15-minute values still falling after
  the restart, and 1.38, 1.62, 3.54 at the end. The agent's idle cost subtracted from the
  batches was 0.031 % of one core with `sample` and 0.000 % with `info`. Run A also measured the
  first figures, median 15.302 ms and 95th percentile 1,527.623 ms, and the first CPU figure,
  1,524.244 ms and 1,533.220 ms. The 95th percentile of the first figures came from a race in
  which a cancelled timeout discarded the guest's answer; commit `f88ae07` fixes it, and run B
  replaces both rows.
- **Run B**, `scripts/measure-figures.sh measuresTheFirstFigures` only, from 11:20:14 UTC, at
  commit `694eb11` with guest files `694eb11` (Guest run 43409382196), with the 1-minute load
  average under 2 before the start; load average 1.46, 4.79, 8.76 at the start and 2.22, 4.55,
  8.47 at the end.
- **Why run A's other rows stand at `694eb11`.** Between `6829e27` and `694eb11`, the daemon's
  code changes only in `FigureSampler.askGuest`: the guest task reports the guest's answer
  before it cancels the timeout, instead of after. The request, its connection, the guest's
  work, the reading of the machine's process, the timer, and the snapshots are unchanged, and so
  are the guest files' sources: the newest change to a path of the Guest workflow is `34dc80b`,
  older than both runs' guest files. The other commits change `scripts/measure-figures.sh`, the
  tests, and the documentation. Before the fix, about 0.6 % of answers were discarded; they cost
  the same, and were missing only from the snapshots, and so from the 4,995 sample times.

**Where the time goes.** `info` is the fixed cost of a request on a host-opened connection: the
connection, the agent's thread, the version exchange, and a small reply. In run A it costs
0.569 ms in the agent and 2.900 ms in the machine's process, or 39 % and 71 % of a `sample`. Reading `/proc/meminfo` and `/proc/net/route` and calling `getifaddrs` add 0.90 ms in
the agent and 1.2 ms in the machine's process. At one sample every 1.5 seconds, 1.473 ms of
agent time would be 0.098 % of one core, while the 60 s window measured 0.079 %; and 4.105 ms
of the machine's process would be 0.274 %, while the window measured 0.357 %. The batches and
the window do not agree, and why is not established; the agent's figures are read in ticks of
10 ms over a batch of 1,000 requests, a resolution of 0.01 ms per request.

**Two targets are missed, and the owner accepted both on 2026-11-12 and kept them on
2026-11-13 after the official measurements:** the guest agent's CPU time per sample (1.473 ms
against 0.5 ms), and the machine's process over 60 s (0.357 % above its unwatched cost against
0.2 %). The fixed cost of one request alone exceeds the agent's target. In the machine's
process it is 0.193 % of one core at one request every 1.5 seconds, just under the limit, and
reading the figures takes the rest. The cost is a fraction of one percent of one core, and only
while a distributions screen is visible; with no screen visible it is zero. The targets in the
prompt stay as they are. Reusing one host-opened connection for every sample of a run would
remove most of the fixed cost. It changes the protocol and the guest files, and is recorded
under phase 12b in [docs/known-limitations.md](../known-limitations.md#phase-12b-hardening).
Sampling every 3 seconds instead would halve the cost and the chart's resolution, and was not
chosen.

**What a reused connection would save.** In the machine's process, the fixed cost is most of a
sample in both official runs that measured it, 71 % in run A and 79 % in run C (below), so a
reused connection would remove most of that cost. In the guest agent, the split between the
fixed cost of a request and the reading of the figures is not established. This record first
concluded from run A that the fixed cost is 39 % of a sample's agent time, and so that a reused
connection would remove less than half of it. Run C did not reproduce that split: by its
medians, the fixed cost (0.869 ms per `info` request) is larger than a whole sample (0.773 ms),
and both sets of batches are scattered, per sample 0.7 to 0.8 ms in three batches and 1.5 to
1.6 ms in two, and per `info` request 0.5 to 1.2 ms. How much of the agent's time a reused
connection would save is therefore unknown. Phase 12b measures the split again before the
protocol change is decided.

#### Run C, at `1d91067`

The owner's run of the whole `scripts/measure-figures.sh` for pull request #30 (its run 1), from
16:12:33 UTC on 2026-11-13, at commit `1d91067` with guest files `5dad733` (Guest run
43422499290), under the conditions above and with Do Not Disturb on, with one exception: shortly
after the test distribution was installed, the owner opened the Claude app for a short time and
closed it again. The terminal app's measurements ran first and are recorded in pull request #30;
the daemon's rows below ran after them, from about 12 minutes after the installation. The
1-minute load average was 1.60 before the start; the script's header gave 2.63, 14.54, 16.29,
after the harness's build, and the end 1.17, 1.44, 2.12. All 9 tests passed in 2,761.9 s, the
daemon's 5 in 2,052.8 s. The agent's idle cost subtracted from the batches had a median of
0.000 % of one core with `sample` (95th percentile 0.032 %) and 0.000 % with `info` (0.033 %).
Since run A's `6829e27`, the guest's sources are unchanged, and the daemon changes only in
`FigureSampler`: run B's fix in `askGuest`, and a count of each run's samples for the snapshots'
`sampleNumber`. The request, the guest's work, and the reading of the machine's process are the
same.

| Measurement | Median | 95th percentile | Values in order | Target | Result | Runs A and B: median, 95th percentile |
|-------------|--------|-----------------|-----------------|--------|--------|----------------------------------------|
| First figures from the start of a watch | 15.761 ms | 16.719 ms | 14.7, 16.7, 15.8, 15.5, 16.0 | under 500 ms | Met | 13.179 ms, 14.599 ms (B) |
| First CPU figure from the start of a watch | 1,530.610 ms | 1,544.960 ms | 1,530.6, 1,545.0, 1,522.9, 1,538.3, 1,523.2 | under 3 s | Met | 1,531.677 ms, 1,545.612 ms (B) |
| A state change by `maw --terminate`, to a watcher | 33.405 ms | 46.453 ms | 46.5, 27.1, 25.8, 33.5, 33.4 | under 500 ms | Met | 23.473 ms, 28.796 ms |
| One sample in the daemon, from the request to the reply (5,010 samples) | 3.083 ms | 4.528 ms | | median under 5 ms | Met | 3.746 ms, 7.583 ms |
| The guest agent's CPU time per `sample` request (5 batches) | 0.773 ms | 1.611 ms | 0.7, 0.8, 0.7, 1.5, 1.6 | under 0.5 ms | Missed; accepted | 1.473 ms, 1.687 ms |
| The guest agent's CPU time per `info` request (5 batches) | 0.869 ms | 1.221 ms | 0.6, 0.5, 0.9, 1.2, 1.0 | none | | 0.569 ms, 0.588 ms |
| The machine's process CPU time per `sample` request | 3.453 ms | 3.650 ms | 3.0, 3.7, 3.5, 3.5, 3.4 | none | | 4.105 ms, 4.441 ms |
| The machine's process CPU time per `info` request | 2.739 ms | 3.057 ms | 2.4, 2.9, 2.7, 3.1, 2.7 | none | | 2.900 ms, 2.977 ms |
| Over 60 s, watched, one distribution running: `mawd` | 0.463 % | 0.465 % | 0.5, 0.5, 0.5, 0.5, 0.5 | under 0.5 % of one core | Met | 0.459 %, 0.462 % |
| The same: the guest agent | 0.095 % | 0.095 % | 0.1, 0.1, 0.1, 0.1, 0.1 | under 0.1 % | Met | 0.079 %, 0.113 % |
| The same: the machine's process, above its cost unwatched | 0.364 % | 0.367 % | 0.1, 0.4, 0.4, 0.4, 0.4 | under 0.2 % | Missed; accepted | 0.357 %, 0.431 % |
| The same: `mawd`'s resident memory growth | 0.047 MiB | 0.125 MiB | 0.1, 0.0, 0.0, 0.0, 0.0 | under 1 MiB | Met | 0.047 MiB, 0.172 MiB |
| `mawd` unwatched, one distribution running | 0.004 % | 0.005 % | 0.0, 0.0, 0.0, 0.0, 0.0 | none | | 0.004 %, 0.004 % |

The values in order are as the script prints them, rounded to one decimal place. The
conclusions above are drawn from run A, except "What a reused connection would save", which
takes run C into account. Run C differs from run A as follows; none of these differences is
explained.

- Every target has the same outcome as in runs A and B, except the guest agent's 60 s cost:
  its 95th percentile, 0.095 %, is under the limit, where run A's was 0.113 %. Its median,
  0.095 %, is above run A's 0.079 %.
- The guest agent's CPU time per sample is 0.773 ms, against 1.473 ms. Its five batches fall in
  two groups: three of 0.7 to 0.8 ms, and two of 1.5 and 1.6 ms, near run A's figure.
- The guest agent's CPU time per `info` request, 0.869 ms, is above its time per sample,
  0.773 ms, although a sample does the work of an `info` request and reads the figures besides.
  By run C's medians, reading the figures costs nothing measurable in the agent, where run A
  gave 0.90 ms, and the fixed cost of a request is the whole of a sample's agent time, where
  run A gave 39 %.
- At one sample every 1.5 seconds, run C's 0.773 ms of agent time would be 0.052 % of one core,
  while its 60 s window measured 0.095 %. In run A the batches gave more than the window (0.098 %
  against 0.079 %); in run C they give less.
- The machine's process takes 3.453 ms per sample and 2.739 ms per `info` request, against
  4.105 ms and 2.900 ms: its fixed cost is 79 % of a sample, against 71 %, and 0.183 % of one
  core at one request every 1.5 seconds, against 0.193 %.
- One sample in the daemon takes 3.083 ms (95th percentile 4.528 ms), against 3.746 ms
  (7.583 ms); a state change reaches a watcher in 33.405 ms (46.453 ms), against 23.473 ms
  (28.796 ms).

### Development measurements

Development measurements, recorded before the official ones with the same script, on the Mac
above, macOS 27.0.1, on 2026-11-12. The Mac was in use: the load averages, which
`sysctl -n vm.loadavg` gave at the start and end of each run, are listed. They do not decide the
targets.

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

**Where the time goes, in the development measurements.** `info` cost 0.82 ms in the agent
and 3.2 ms in the machine's process. Reading `/proc/meminfo` and `/proc/net/route` and calling
`getifaddrs` added 0.33 ms in the agent and about 1.0 ms in the machine's process. At one
sample every 1.5 seconds, 1.155 ms of agent time is 0.077 % of one core, which matched the 60 s
window's 0.079 %. Run 1's 1.95 ms against run 3's 1.155 ms is not explained; a busier Mac may
inflate the guest's CPU accounting, which the guest's `steal` time would show, and was not
measured. The development measurements missed the same two targets, with 1.155 ms per sample
and 0.372 % above the unwatched cost, and met the others, as the official ones do.

## Consequences

- A machine that runs while nothing watches costs nothing: no lookup, no sample, no timer.
- The guest's figures are guest input: decoded strictly, displayed only, never logged
  ([docs/security.md](../security.md#figures-from-the-guest)).
- The lookup reads the open files of the user's Virtualization processes, including other
  programs' virtual machines
  ([docs/security.md](../security.md#finding-a-machines-process)).
- A host and guest files of different protocol versions refuse each other, and an app built
  before interface version 4 fails with `daemonVersionMismatch` until it is rebuilt.
- The terminal app draws one bar of its memory chart per sample. A snapshot is also published
  after state changes, installations, a new default, and the samples of other distributions, so
  phase 11c's second pull request adds each distribution's `sampleNumber` to the snapshots, which
  increments the daemon interface version to 5 ([docs/daemon.md](../daemon.md#watching-the-distributions)).
