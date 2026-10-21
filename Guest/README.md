# Guest kernel and initramfs

Every maw VM boots from two files built here:

- `Image`: an uncompressed arm64 Linux kernel. `VZLinuxBootLoader` cannot boot a compressed
  kernel on Apple Silicon.
- `initramfs.cpio.gz`: static busybox, static `mke2fs`/`mkfs.ext4`, `e2fsck`, and
  `resize2fs`, the guest agent `/sbin/maw-agent`, and `/init`.

`/init` mounts the pseudo-file systems, prints the banner, and runs the `maw.test=` hooks.
It then executes busybox `init` as PID 1, which supervises the agent; with
`maw.debug=shell` on the kernel command line, `init` also runs a shell on `hvc0`.
[Decision record 0005](../docs/decisions/0005-init-supervises-the-agent.md) explains the
arrangement, and [docs/protocol.md](../docs/protocol.md) specifies how the host talks to the
agent.

[Decision record 0003](../docs/decisions/0003-guest-kernel.md) explains why maw ships its
own monolithic kernel with 4K pages, and why the initramfs provisions disks.

## Layout

```
Guest/
  build.sh               entry point: detects a container runtime, downloads and verifies
                         sources, and runs the build in the builder image
  Containerfile          builder image: Debian pinned by digest, packages from snapshot.debian.org
  container-build.sh     runs inside the builder: kernel, initramfs, manifest, checksums
  kernel/
    VERSION              pinned kernel version, URL, and sha256
    maw.config           configuration fragment, applied on top of allnoconfig
    build-kernel.sh      allnoconfig, merge_config.sh, olddefconfig, verification, `make Image`
    check-config.sh      checks the final configuration against the required lists
  initramfs/
    SOURCES              pinned busybox and e2fsprogs versions, URLs, and sha256 sums
    busybox.config       busybox configuration overrides
    init                 /init
    maw-shutdown         the inittab shutdown action: stops processes, powers off
    build.sh             builds busybox and e2fsprogs, packs the cpio archive
  agent/
    SWIFT                pinned Swift toolchains and Static Linux SDK for the agent
  scripts/               helpers shared by the kernel and busybox configuration
  test/
    boot-smoke.sh        boots the output under QEMU, and runs the agent's self-test
    runtime-detection.sh tests build.sh's container runtime detection
  out/                   build output (not in git)
  .cache/sources/        downloaded source tarballs (not in git)
```

## Building locally

The build runs inside a Linux container, so it needs a container runtime on the Mac:

- **Apple's [container CLI](https://github.com/apple/container)** is the recommended runtime.
  Start its service once with `container system start`.
- **Docker** works as well.

`Guest/build.sh` uses the first of these that is installed and running, in that order. Set
`MAW_CONTAINER_RUNTIME=docker` or `MAW_CONTAINER_RUNTIME=container` to choose. When
neither runtime is usable, the script says what to install or start, and exits with status
69.

```sh
scripts/build-guest-agent.sh           # build the agent (see "Building the agent locally")
Guest/build.sh --agent .build/guest-agent/maw-agent
                                       # build into Guest/out/ with the agent
Guest/build.sh                         # build without the agent; /init then starts a shell
Guest/kernel/check-config.sh           # check Guest/out/kernel.config
Guest/test/boot-smoke.sh               # boot Guest/out/ under QEMU (needs qemu-system-aarch64)
Guest/test/runtime-detection.sh        # test runtime detection; needs no runtime
```

The first build creates the builder image, which takes several minutes. Later builds reuse
it until `Containerfile` changes. The CI build in `.github/workflows/guest.yml` is the
reference build.

`Guest/out/` contains:

| File | Contents |
|------|----------|
| `Image` | the kernel |
| `initramfs.cpio.gz` | the initramfs |
| `kernel.config` | the final kernel configuration |
| `manifest.json` | kernel version and source sha256, initramfs component versions, the agent's sha256, `SOURCE_DATE_EPOCH`, git commit, builder image |
| `SHA256SUMS` | sha256 of the four files above |

To use a CI build instead of building locally, run `scripts/fetch-guest.sh [<branch>]`. It
downloads the latest successful build of the branch (default `main`), verifies it, and
installs it into `~/Library/Application Support/maw/kernel/`.

## Building the agent locally

Local agent builds are optional: `scripts/fetch-guest.sh` installs guest files that the Guest
workflow built, agent included. To build the agent yourself, you need the swift.org toolchain
and the Static Linux SDK of the same release, both pinned in `agent/SWIFT`. Xcode's toolchain
cannot use the SDK.

1. Download the macOS toolchain package (`SWIFT_MACOS_URL` in `agent/SWIFT`), check its
   sha256 against `SWIFT_MACOS_SHA256`, and install it for your user only:

   ```sh
   installer -pkg swift-6.4.1-RELEASE-osx.pkg -target CurrentUserHomeDirectory
   ```

   It goes into `~/Library/Developer/Toolchains/` and does not change PATH: `swift` in a new
   shell is still Xcode's. Do not install swiftly or other tools that put a proxy on PATH.

2. Install the SDK with the toolchain selected for that one command:

   ```sh
   id=$(plutil -extract CFBundleIdentifier raw \
       ~/Library/Developer/Toolchains/swift-6.4.1-RELEASE.xctoolchain/Info.plist)
   TOOLCHAINS=$id swift sdk install <SWIFT_SDK_URL> --checksum <SWIFT_SDK_SHA256>
   ```

3. Build:

   ```sh
   scripts/build-guest-agent.sh    # writes .build/guest-agent/maw-agent
   ```

   The script finds the pinned toolchain, selects it with `TOOLCHAINS` for its own commands
   only, checks the toolchain and SDK versions, and builds a static, stripped binary for
   `aarch64-swift-linux-musl`.

The agent's logic lives in `Sources/MawAgentKit`, which also builds on macOS, so its unit
tests run with `swift test` and need none of the above.

## Reproducibility

Two builds of the same commit produce identical files, and CI checks this on every run.
The build achieves this as follows:

- The builder image is pinned by digest, and its packages come from a fixed
  snapshot.debian.org timestamp.
- Every source tarball is pinned by sha256.
- `SOURCE_DATE_EPOCH` is the commit time of `HEAD`, and `KBUILD_BUILD_TIMESTAMP`,
  `KBUILD_BUILD_USER`, `KBUILD_BUILD_HOST`, and `KBUILD_BUILD_VERSION` are fixed.
- The build runs in `/build` inside the container, outside the git tree, so no host path is
  embedded and the kernel release has no `+` suffix.
- The cpio archive is built from a sorted entry list with owner `0:0`, mtimes from
  `SOURCE_DATE_EPOCH`, and `gzip -n`.

A build from a working tree with uncommitted changes is marked `-dirty` in its version.

The agent is the exception. Two builds of `maw-agent` from the same commit, toolchain, and
path differ in the `.swift_modhash` section that Swift 6.4 emits (146 16-byte module hashes,
of which about 17 differ), and therefore in the GNU build ID. No compiler option to make the
section deterministic was found. CI builds the agent twice, reports the difference as a
warning, and compares the two guest builds with the same agent, so that everything except the
agent is still checked.

## Changing the kernel configuration

1. Edit `kernel/maw.config`. Add the option to the group that matches its purpose, with
   a comment if the reason is not obvious.
2. If the guest depends on the option, add it to `REQUIRED_OPTIONS` in
   `kernel/check-config.sh` as well.
3. Build. `build-kernel.sh` fails if any requested option did not end up set, and names it.
   That almost always means a dependency is not enabled. Find it in the option's `depends on`
   lines, for example with `grep -rn '^config NAME$' -A10 --include=Kconfig*` in the kernel
   source, and add it to the fragment.
4. Run `kernel/check-config.sh` and `test/boot-smoke.sh`, or push and let CI run them.

To explore the configuration interactively, open a shell in the builder image (use the tag
from `Guest/build.sh --print-builder-image`), extract the kernel source from
`.cache/sources/`, and run `make ARCH=arm64 allnoconfig`, then
`scripts/kconfig/merge_config.sh -m .config <fragment>` and `make ARCH=arm64 menuconfig`.
`menuconfig` needs `libncurses-dev`, which the builder image does not include.

## Bumping the kernel

maw tracks the newest longterm release listed at <https://www.kernel.org/releases.json>.

1. Update `LINUX_VERSION`, `LINUX_URL`, and `LINUX_SHA256` in `kernel/VERSION`. Take the
   sha256 from `sha256sums.asc` in the same directory as the tarball on cdn.kernel.org, and
   verify that file's signature with the kernel developers' keys.
2. Build and run the checks. Within a longterm series, configuration changes are rare. When
   moving to a new longterm series, expect renamed or new dependencies; `build-kernel.sh`
   and `check-config.sh` report them.
3. Read the new kernel's `scripts/kconfig/merge_config.sh` output in the build log for
   options that were redefined or dropped.

Other pins are bumped the same way:

- **busybox and e2fsprogs:** update `initramfs/SOURCES`.
- **moby's check-config.sh:** update `MOBY_COMMIT` and `MOBY_SHA256` in
  `kernel/check-config.sh`.
- **Builder image:** update the image digest and the snapshot timestamp in `Containerfile`.

## Not included yet

- `CONFIG_DEBUG_INFO_BTF` and `CONFIG_BPF_LSM`, which systemd needs only for
  `RestrictFileSystems=`. BTF requires building with DWARF debug information and `pahole`.
  `kernel/check-config.sh` lists the other systemd items that do not apply to this guest, and
  why.
