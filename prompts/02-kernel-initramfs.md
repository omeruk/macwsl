# Phase 02: Guest kernel and initramfs

Read `CLAUDE.md` first. Work on branch `phase/02-kernel` from the latest `main`.

## Goal

A reproducible build, run in CI, that produces the two files every MacWSL VM boots from:

- `Image`: an uncompressed arm64 Linux kernel. `VZLinuxBootLoader` cannot boot a
  compressed kernel (`Image.gz`) on Apple Silicon.
- `initramfs.cpio.gz`: a minimal initramfs with busybox and e2fsprogs, and a placeholder
  `/init`. Phase 04 adds the real guest agent to it.

No host (macOS) code in this phase. Phase 03 boots these files with
Virtualization.framework. In this phase, CI proves they boot by running them under QEMU.
QEMU is only a test harness here. It is never a runtime dependency of the product.

## Tasks

1. **Kernel source and config** (`Guest/kernel/`)
   - Pin the newest longterm (LTS) kernel from kernel.org. Record its version and the
     tarball's sha256 in `Guest/kernel/VERSION`, and verify the checksum before building.
   - Start from `make allnoconfig`, then merge `Guest/kernel/macwsl.config` with
     `scripts/kconfig/merge_config.sh`. After `make olddefconfig`, fail the build if any
     option requested in the fragment did not end up set. `merge_config.sh` only warns
     about these.
   - Build everything in. Set `CONFIG_MODULES=n`, so the guest never needs a module tree.
   - 4K pages (the arm64 default).
   - The fragment is grouped and commented by purpose:
     - **Virtio devices:** PCI, block, net, console (`hvc0`), balloon, entropy (rng),
       virtio-fs with FUSE, vsock with virtio transport.
     - **Filesystems:** ext4, tmpfs, devtmpfs with automount, proc, sysfs, overlayfs,
       autofs.
     - **Executables:** ELF, scripts, `binfmt_misc` (needed by Rosetta in phase 10).
     - **Initramfs:** `BLK_DEV_INITRD` with gzip support.
     - **Networking:** IPv4, IPv6, Unix sockets, packet sockets.
     - **Containers** (Docker and Podman inside the distro should work):
       - Namespaces and cgroup v2 with all controllers.
       - seccomp and BPF with the BPF syscall.
       - Bridge, veth, tun/tap.
       - Netfilter with nftables and the iptables-nft compatibility layer, plus NAT and
         conntrack.
     - **systemd requirements:**
       - Base options: `FHANDLE`, `SIGNALFD`, `TIMERFD`, `EPOLL`, `INOTIFY_USER`, `DMIID`
         if applicable.
       - Plus everything listed under "REQUIREMENTS" in systemd's README.
   - Write `Guest/kernel/check-config.sh`. It verifies the final `.config` against two
     sources:
     - Our required list.
     - The "required" (generally necessary) section of moby's `contrib/check-config.sh`.
       Pin that file by commit hash rather than vendoring it unpinned.

     The build fails if any required option is missing. "Optional" moby items are only
     reported.

2. **Initramfs** (`Guest/initramfs/`)
   - Contents:
     - Static busybox, with applet symlinks.
     - Static `mke2fs`/`mkfs.ext4`, `e2fsck`, `resize2fs`.
     - `/init`.
   - Build these from pinned source tarballs with verified sha256 sums. If you take a
     distro package instead, pin the exact version and record the reason in the decision
     record.
   - `/init` is a busybox `sh` script. In order, it:
     1. Mounts `proc`, `sys`, `devtmpfs`, `tmpfs` on `/run`.
     2. Prints a single banner line to the console:
        `macwsl-initramfs <version> kernel=<uname -r>`.
     3. If the kernel command line contains `macwsl.test=poweroff`, prints
        `macwsl-initramfs: poweroff` and powers off immediately. Phase 03 and CI use this.
     4. Otherwise, starts an interactive shell on `/dev/hvc0`.
   - The cpio archive must be reproducible:
     - Sorted entries.
     - Fixed mtimes from `SOURCE_DATE_EPOCH`.
     - Owner `0:0`.
     - `gzip -n`.
   - `build.sh` takes an optional `--agent <path>`, which installs a binary as
     `/sbin/macwsl-agent`. Phase 04 uses this.

3. **Build entry point**
   - `Guest/build.sh` builds the kernel and initramfs inside a container image pinned by
     digest (Debian or Ubuntu, arm64 native).
   - It writes everything to `Guest/out/`, which is git-ignored:
     - `Image`
     - `initramfs.cpio.gz`
     - `kernel.config`
     - `SHA256SUMS`
     - `manifest.json`: kernel version, source sha256, initramfs component versions,
       `SOURCE_DATE_EPOCH`, and git commit.
   - Set `KBUILD_BUILD_TIMESTAMP`, `KBUILD_BUILD_USER`, `KBUILD_BUILD_HOST`, and
     `SOURCE_DATE_EPOCH` so that two builds of the same commit are byte-identical.
   - `Guest/build.sh` must also run on the developer's Mac when a container runtime is
     available (Docker, or Apple's `container` CLI). Detect which one is installed, and
     print a clear message when neither is.

4. **Boot smoke test** (`Guest/test/boot-smoke.sh`)
   - Boots `Image` with `initramfs.cpio.gz` in `qemu-system-aarch64` with these settings:
     - Machine and CPU: `-machine virt -cpu max`.
     - Console: virtio-serial with a `virtconsole` on stdio.
     - Network and graphics: none.
     - Kernel command line: `console=hvc0 macwsl.test=poweroff`.
   - Passes when the banner and `macwsl-initramfs: poweroff` both appear and QEMU exits on
     its own within 120 seconds. On failure, it prints the full console log.

5. **CI** (`.github/workflows/guest.yml`)
   - Runs on `ubuntu-24.04-arm`, triggered by changes under `Guest/` and by manual
     dispatch.
   - Steps:
     1. Build.
     2. Run `check-config.sh`.
     3. Run the boot smoke test.
     4. Build a second time and compare `SHA256SUMS`, to prove the build is reproducible.
     5. Upload `Guest/out/` as the artifact `macwsl-guest`.
   - Cache the downloaded source tarballs, keyed by their sha256.
   - On a tag matching `guest-v*`, attach the files to a GitHub Release.

6. **Fetch script** (`scripts/fetch-guest.sh`)
   - Uses `gh run download` to fetch the latest successful `macwsl-guest` artifact from
     `main`, or from a branch given as an argument.
   - Verifies `SHA256SUMS`, then installs the files into
     `~/Library/Application Support/MacWSL/kernel/`.
   - Phase 03 depends on this script.

7. **Docs**
   - `docs/decisions/0003-guest-kernel.md`: why we ship our own kernel, why it is
     monolithic (no modules), why 4K pages, and why the initramfs provisions disks.
   - `Guest/README.md`: how to build locally, how to change the kernel config, and how to
     bump the kernel version.

## Out of scope

The guest agent, vsock, anything that runs on macOS other than `fetch-guest.sh`, and
distro root filesystems.

## Acceptance criteria

- The `guest.yml` workflow is green on the PR.
- `check-config.sh` reports every required option as set.
- The boot smoke test passes and reaches `macwsl-initramfs: poweroff`.
- Two consecutive builds produce identical `SHA256SUMS`.
- `Image` is uncompressed: `file Image` reports an arm64 Linux kernel image, not gzip
  data.
- The PR description lists the sizes of `Image` and `initramfs.cpio.gz`, and the time the
  CI build took.
- `scripts/fetch-guest.sh <branch>` on the Mac installs the files and verifies their
  checksums.

## How to work

1. Present a short plan first:
   - The kernel version you picked.
   - Where each initramfs binary comes from.
   - The container image you will pin.

   Wait for approval.
2. Kernel builds are slow, so iterate on the config in CI rather than guessing locally.
3. Finish with the PR, as described in the Workflow section of `CLAUDE.md`.
