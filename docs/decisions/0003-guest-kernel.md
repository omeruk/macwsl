# 0003: Ship our own monolithic guest kernel and a provisioning initramfs

- Status: Accepted
- Date: 2026-10-20

## Context

Every MacWSL VM is started by `VZLinuxBootLoader`, which loads a kernel and an initramfs
directly, without firmware or a boot loader. On Apple Silicon the kernel must be an
uncompressed arm64 `Image`.

The guest needs specific kernel features: virtio over PCI, a virtio console, virtio-fs for
`/mnt/mac`, vsock for the agent, `binfmt_misc` for Rosetta, and what systemd, Docker, and
Podman require. It should boot in about a second, and it must work the same way for every
distribution MacWSL installs.

## Decision

1. MacWSL builds and ships its own kernel from the newest longterm (LTS) release on
   kernel.org, pinned by version and sha256. It does not use the distribution's kernel.
2. The kernel is monolithic: `CONFIG_MODULES=n`, and every feature is built in.
3. The kernel uses 4K pages.
4. The initramfs contains static `mke2fs`, `e2fsck`, and `resize2fs`, so that disks are
   formatted, checked, and resized inside the VM.

The kernel and initramfs are built in a container image pinned by digest, with packages
from a fixed snapshot of the Debian archive, so that two builds of the same commit are
byte-identical. `Guest/README.md` describes the build.

## Why our own kernel

- **One tested kernel for every distribution.** Distribution kernels differ in version and
  configuration, and not all of them enable virtio-fs, vsock, and `binfmt_misc` as built-in
  features. With one kernel, a feature that works for Ubuntu works for every distribution.
- **Boot format.** Distribution arm64 kernels are usually shipped compressed (`vmlinuz`),
  often as an EFI zboot image, and expect an initramfs generated inside the distribution to
  load their modules. `VZLinuxBootLoader` needs an uncompressed `Image` and an initramfs that
  is ready to use.
- **Updates under our control.** Kernel fixes reach every distribution through a MacWSL guest
  release, independently of each distribution's package updates. WSL2 follows the same
  model.

Trade-off: MacWSL takes responsibility for kernel security updates. Each LTS point release
is a version bump in `Guest/kernel/VERSION` followed by the CI checks in this phase.

## Why monolithic

- **No module tree to keep in step.** Modules must match the running kernel exactly. With
  loadable modules, every distribution would need a matching `/lib/modules/<release>` tree,
  installed and updated by MacWSL rather than by the distribution's package manager.
- **Faster, simpler boot.** There is nothing to load before the root file system is mounted,
  so the initramfs does not need `modprobe` or a module dependency map.
- **Smaller attack surface.** The kernel cannot load code after boot.

Trade-off: every feature must be enabled at build time. Software that builds out-of-tree
modules (for example DKMS packages) cannot work in a MacWSL guest. Tools that call `modprobe`
find no modules; the features they request must already be built in.

## Why 4K pages

Apple Silicon also supports 16K pages, which Asahi Linux uses on bare metal. MacWSL uses 4K:

- 4K is the arm64 default and the page size that Debian, Ubuntu, and other distributions
  build and test their arm64 kernels with.
- Some arm64 binaries are linked with 4K segment alignment and do not load on a 16K-page
  kernel.
- x86_64 software, which runs through Rosetta from phase 10, is written for 4K pages.

## Why the initramfs provisions disks

- **No Linux file system tooling on the host.** macOS cannot create or check ext4. Building
  the tools into the initramfs avoids a host dependency such as Homebrew's e2fsprogs.
- **The host stays simple.** To create a distribution, the host creates a sparse raw file and
  attaches it to the VM. The initramfs formats it on first boot, runs `e2fsck` before
  mounting, and grows the file system with `resize2fs` when the disk is enlarged.
- **One implementation.** The tools that create the file system come from the same build as
  the kernel that mounts it.

Trade-off: the initramfs is larger by the size of three static binaries, and the first boot
of a new distribution includes formatting the disk.

## Consequences

- CI builds the kernel and initramfs, checks the configuration, boots them under QEMU, and
  proves that the build is reproducible. QEMU is a test harness only; MacWSL boots the files
  with Virtualization.framework from phase 03.
- `scripts/fetch-guest.sh` installs CI-built files on a developer's Mac, so that host
  development does not require building the kernel locally.
- New guest features require a kernel configuration change and a new guest release.
