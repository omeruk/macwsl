# 0001: Use Virtualization.framework directly

- Status: Accepted
- Date: 2026-10-20

## Context

MacWSL runs each Linux distribution in a virtual machine. The product goals constrain how:

- A VM must boot in about a second, so that `macwsl ls` feels like a local command.
- Files, terminals and commands cross the host/guest boundary constantly. That needs a fast
  shared file system (virtiofs) and a low-latency host/guest channel (vsock), not SSH.
- x86_64 Linux binaries should run through Rosetta, as they do in Apple's own tooling.
- We ship a signed, notarized app. Every bundled binary is something we must build, sign,
  update and answer for, including its license.

Three ways to get there on Apple Silicon:

1. **QEMU** with the Hypervisor.framework accelerator.
2. **Lima** (or a similar wrapper such as Colima), which drives QEMU or Virtualization.framework
   and manages VMs for us.
3. **Virtualization.framework** (`VZ*` APIs) used directly from Swift.

## Decision

Use Virtualization.framework directly, from our own Swift code, with no VM manager in between.

The pieces we need are all first-party:

| Need                | Virtualization.framework API                          |
|---------------------|-------------------------------------------------------|
| Direct kernel boot  | `VZLinuxBootLoader`                                   |
| Root disk           | `VZDiskImageStorageDeviceAttachment` on a sparse raw image |
| `/mnt/mac`          | `VZVirtioFileSystemDeviceConfiguration` (virtiofs)    |
| Agent channel       | `VZVirtioSocketDeviceConfiguration` (vsock)           |
| x86_64 binaries     | `VZLinuxRosettaDirectoryShare`                        |
| Networking          | `VZNATNetworkDeviceAttachment`                        |
| Returning memory    | `VZVirtioTraditionalMemoryBalloonDeviceConfiguration` |
| Sleep/wake          | `saveMachineStateTo` / `restoreMachineStateFrom` (macOS 14) |

## Why not QEMU

- It is a large C code base to build, sign, ship and patch for security fixes, under GPL/LGPL
  licensing that complicates distribution inside an app bundle.
- virtiofs on QEMU needs a separate `virtiofsd` daemon, which does not run on macOS. The
  alternative, 9p, is much slower for the many small file operations a shell generates.
- QEMU has no Rosetta integration. Running x86_64 binaries would mean full emulation, which is
  slow.
- Boot time and idle overhead are higher than with Apple's purpose-built virtio devices.

## Why not Lima

- Lima is a VM manager with its own lifecycle, YAML configuration, state directory and daemon.
  `macwsld` must own lifecycle itself (idle shutdown, sleep/wake, per-distro state), so we would
  be working around Lima's model rather than using it.
- Commands run over SSH. That adds connection setup latency and makes PTY, signal and exit-code
  handling depend on SSH semantics instead of our own protocol.
- It adds a Go runtime and a second release cadence to our dependency tree. Its VZ backend calls
  the same framework we would call ourselves.

## Consequences

- Apple Silicon and macOS 14 or later only. This matches the product's platform constraints.
- Every binary that creates a VM must carry the `com.apple.security.virtualization`
  entitlement. Development builds are ad-hoc signed by `scripts/sign-dev.sh`.
- We are limited to the devices Apple exposes. For example, there is no USB passthrough.
- `VZVirtualMachine` must be used from the dispatch queue it was created on. That is one of the
  places where `CLAUDE.md` permits a `DispatchQueue`, wrapped at the module boundary so the rest of
  the code uses actors.
- We build our own guest kernel and initramfs (phase 02), because direct kernel boot needs them
  and we want a minimal configuration that boots in about a second.
