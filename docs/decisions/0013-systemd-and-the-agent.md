# 0013: A distribution boots systemd as PID 1, with the agent supplied by the initramfs

- Status: Accepted
- Date: 2026-10-22
- Supersedes [0005](0005-init-supervises-the-agent.md) for distribution machines. busybox
  `init` stays PID 1 on the initramfs machine, which provisions distributions and serves
  `mawd debug-boot`.

## Context

A distribution's machine boots the maw kernel and initramfs with the distribution's disk
attached. Ubuntu expects systemd: its services, `systemctl`, `systemd-logind`, user managers,
and timers for security updates all depend on it, and current WSL releases run it as PID 1.

The guest agent (`maw-agent`) must run in every distribution, start as early as possible so
that a session does not wait for the whole boot, and never require changes inside an installed
distribution when maw updates it.

## Decision

1. **Boot sequence.** With `maw.root=/dev/vda` on the kernel command line, `/init`:
   1. sets the clock from `maw.clock=<seconds>` (the virtual machine has no real-time clock,
      and its clock would start in 1970, which breaks TLS and apt);
   2. runs `e2fsck -p` on the disk and mounts it at `/sysroot`, read-write;
   3. mounts a tmpfs on `/sysroot/run`, copies the agent to `/run/maw/maw-agent`, and writes the
      runtime unit `/run/systemd/system/maw-agent.service`, enabled for `sysinit.target`;
   4. moves `/dev`, `/proc`, and `/sys` into the new root, and runs
      `switch_root /sysroot /sbin/init`.

   systemd keeps a `/run` that is already mounted and reads runtime units from
   `/run/systemd/system`, so the agent runs without being installed in the distribution, and is
   gone when the machine stops.
2. **The agent's unit** has `DefaultDependencies=no`, so that it starts as soon as systemd does
   and is not stopped before the final kill at power-off; `KillMode=process`, so that a
   restarted agent keeps its sessions; `Restart=always`; and its output goes to the journal and
   the console.
3. **Sessions do not wait for the boot.** The daemon opens sessions once the agent answers.
   Commands run at once; a login shell waits at most 2 seconds for the system bus, so that
   `pam_systemd` can register it (decision record 0015).
4. **Shutdown.** The agent sends PID 1 SIGRTMIN+4, which starts `poweroff.target`. systemd is
   built against glibc, whose SIGRTMIN is 34; the agent is linked against musl, whose SIGRTMIN
   is 35, so the signal number, 38, is spelled out (`InitSystem.powerOffSignal`).
5. **Resources**, until phase 12 makes them configurable: every CPU of the Mac and half of its
   memory, as WSL gives its virtual machine. The configuration includes a memory balloon device,
   but nothing drives it yet, so memory that the guest has used is not returned to macOS until
   the machine stops. Phase 12 adds the balloon's control.
6. **Disk.** Virtualization.framework chooses the caching mode (`.automatic`). The
   synchronization mode is `.full`: every flush from the guest issues `F_FULLFSYNC`, so that
   data the guest has flushed survives a crash or a power loss of the Mac. The measurements
   below record the cost and the choice.

## Measurements

Median of 5 runs, M1 Pro, 2026-10-22.

**Cold start** of `maw -e true`, machine stopped and daemon running: 593 ms (slowest 611 ms).
Breakdown of the median run, in the guest's uptime:

| Stage | Time |
|-------|------|
| Virtualization.framework creates and starts the machine, before the kernel runs | about 190 ms (the daemon's 483 ms to agent readiness, less the guest's 292 ms) |
| Kernel, until `/init` runs | 0.10 s |
| `/init`: clock, `e2fsck -p`, mount, agent unit, until `switch_root` | 0.12 s |
| systemd starts the agent's unit | 0.275 s |
| The agent is ready | 0.292 s |
| maw connects, opens the session, runs `true`, and exits | about 110 ms |

**Cold start to a prompt** (`maw`): 864.9 ms (slowest 1,039.8 ms). **Clean shutdown** through
the agent: 650 to 730 ms.

**Disk synchronization.** `apt-get install build-essential` from a local package cache, in a
fresh distribution, median of 3:

| Mode | Runs | Median |
|------|------|--------|
| `.full` | 19.59, 17.49, 17.58 s | 17.58 s |
| `.fsync` | 4.68, 4.20, 4.06 s | 4.20 s |

`.full` makes package installation about 4.2 times slower, because dpkg flushes after every
package. The owner decided to keep `.full` (2026-10-23): a flush the guest has made survives a
crash or a power loss of the Mac, which `.fsync` does not guarantee, and the integrity of the
user's data comes before speed. Phase 12 adds a `.mawconfig` setting with which a user can
choose `.fsync` for their machines and accept that risk.

**Discard.** Virtualization.framework has no setting for it. On macOS 27 the guest's virtio
block device accepts discard requests (`discard_max_bytes` is the disk's size, the granularity
512 bytes), and Ubuntu's `fstrim.timer`, enabled by default, trims weekly. Measured on a
distribution's disk image on the Mac:

| Step | Allocated on the Mac |
|------|----------------------|
| Before | 1.59 GB |
| After writing a 1 GiB file in the guest | 2.68 GB |
| After deleting it | 2.68 GB |
| After `fstrim /` | 1.61 GB |

The file system is mounted without the `discard` option, so deleting a file does not discard at
once; the weekly trim returns the space, and `sudo fstrim /` does so on demand. Whether macOS 14
advertises discard has not been verified on a Mac running macOS 14.

## Consequences

- The initramfs needs only the agent binary to serve every distribution; a guest update never
  modifies an installed distribution.
- `mkfs.ext4` runs with `assume_storage_prezeroed=1,nodiscard`: the sparse file already reads as
  zeros, so neither `mke2fs` nor the kernel's lazy initialization writes zeros, which would
  allocate them on the Mac. Formatting the 256 GiB disk takes 30 to 45 ms.
- An installed distribution uses 1.3 GB of the Mac's disk after installation (allocated blocks
  of the sparse image).
