# 0021: The owner's home directory is mounted at /mnt/mac, owned by the default user

- Status: Accepted
- Date: 2026-11-17

## Context

Phase 07 gives every distribution the Mac's files, as WSL gives a distribution `/mnt/c`
([prompt](../../prompts/07-file-sharing-and-paths.md)). The owner decided three things before
the work began:
- the share is the whole home directory, read-write, at `/mnt/mac`;
- outside the home directory, `maw` starts in the Linux home directory (pull request B);
- there is no switch to turn the share off until phase 12.

Apple documents little about its virtiofs. Before the plan, a throwaway build on the owner's Mac
measured what the plan depends on. The figures below come from that build. Unless a figure says
otherwise, it was taken from test distributions under the test daemon, on an M1 Pro with 16 GB
running macOS 27.0.1, on 2026-11-17, with guest files `6202165` (Linux 6.18.57).

## What the platform does

**The device.** `VZVirtioFileSystemDeviceConfiguration` with a `VZSingleDirectoryShare` of the
home directory appears in the guest as `virtiofs virtio3: discovered new tag: maw-mac`.

- `mount -t virtiofs maw-mac <directory>` works with no options, and so does a bare `mount(2)`
  with no data. Nothing is needed beyond the kernel's `CONFIG_VIRTIO_FS=y` and
  `CONFIG_FUSE_FS=y`: there is no mount helper and no module.
- A mount took 9.6 ms the first time and 1.9 to 2.7 ms afterwards.
- A wrong tag fails with status 32, and the kernel logs `virtio-fs: tag <...> not found`.
- The kernel's line about the tag goes to `dmesg` only, not to the console.
- Alternating 5 cold starts with the device and 5 without, with the share not mounted:

  | Measurement | With the device | Without |
  |---|---|---|
  | `maw -e true` | 535 ms | 519 ms |
  | `maw` to a prompt | 899 ms | 893 ms |

  Within the spread of the runs.

**Access.** Every access is made on the Mac with the owner's identity.

- Files and directories that the guest creates belong to the owner on the Mac (`501:20`), with
  the guest's umask: 644 for files, 755 for directories.
- `chmod`, including `+x`, reaches the Mac.
- `chown` is ignored, although root's `chown` returns 0.
- `chmod u+s` is ignored, and returns 0.
- `mknod` of a device fails with `Operation not permitted`.
- `mkfifo` works.
- A file of mode 000 cannot be used by any guest user, root included.

**The owner that the guest sees.** Apple's server reports as a file's owner the uid and gid of
the guest process whose request fetched its attributes, and the guest caches the answer.

- When root looked first, the default user saw `uid=0` for more than 60 seconds, until a
  directory listing by the default user fetched the attributes again.
- In the other order, root saw `uid=1000`.
- `git` then refused a repository of the default user: `detected dubious ownership`.
- The guest checks modes (`default_permissions`). After a refusal it fetches the attributes
  again as the requesting user (`fs/fuse/dir.c`, `fuse_permission`), so that user becomes the
  owner. Every guest user therefore had the owner's full rights: `nobody` wrote a file of mode
  644, read one of mode 600, and entered a directory of mode 700.
- The mount itself and a read of `/proc/self/mountinfo` look nothing up, so neither makes root
  the first to look. `mountpoint` does: it looks up the mount's root as root.

**What could fix the owner, measured.**
- virtiofs refuses `uid=` (`virtiofs: Unknown parameter 'uid'`).
- An idmapped mount fails with `failed to attach idmapping`. The kernel allows one on FUSE only
  if the server announces `FUSE_ALLOW_IDMAP` (`fs/fuse/inode.c`), and Apple's does not. An
  idmapping would also have to map two uids, 0 and 1000, to one, which it cannot.
- The attribute cache's lifetime comes from the server's replies. Dropping the guest's caches
  helps only until root's next lookup.

**Privacy prompts (TCC).**
- Each question names `mawd`. The attribution in the TCC log is
  `responsible=dev.maw.mawd`, `accessing=com.apple.Virtualization.VirtualMachine`.
- The question comes back with every development build whose code hash changes, for every
  protected folder, Desktop included.
- A refusal shows in the guest as `Operation not permitted` on the folder itself, not as an
  empty directory, and is not asked again within that build.
- `~/Library/Mail`, which needs Full Disk Access, is refused with no question.

**Names and links.**
- A name keeps the bytes that its side wrote, NFC (`c3 a7`) or NFD (`63 cc a7`), and is found
  under either form on both sides.
- The home volume is APFS, case-insensitive and case-preserving. `> a` and then `> A` in the
  guest gave one file, `a`, holding the second write; `mv b B` failed with `'b' and 'B' are the
  same file`.
- An absolute link resolves on the side that made it, and dangles on the other. Relative links
  work on both sides.
- Hard links work: one inode, two links, on both sides.

**Coherence.**
- A change made on the Mac reached the guest within 0.1 s.
- For about 0.1 s, one read returned the new data cut to the old cached size.
- A directory that the Mac removed and created again under the same name was stale in the
  guest for under a second.

**Speed** (development figures, median of 5, load averages from 2.6 to 3.1):

| Measurement | Median | Slowest |
|-------------|--------|---------|
| Writing 1 GiB (`dd conv=fsync`) | 1,151 MB/s | 973 MB/s |
| Reading 1 GiB, the guest's caches dropped | 2,753 MB/s | 2,671 MB/s |
| `ls -l` of 10,000 files, the guest's caches dropped | 987 ms | 998 ms |
| The same on the Mac | 83 ms | 94 ms |
| `git status` in a clone of this repository, second run | 23 ms | 24 ms |

Pull request A records the measurements of `scripts/measure-mac-share.sh`.

## Decision

1. **Every distribution's machine shares the home directory**, read-write, under the tag
   `maw-mac`, with `maw.share=maw-mac` on its kernel command line. The provisioning machine,
   which runs programs of root file systems that may come from outside maw, never gets the
   device. `mawd serve --without-mac-share` leaves both out, for the cold-start measurement
   only.

2. **The initramfs mounts it**, before `switch_root`, through the agent's
   `mount-mac-share` subcommand.
   - It runs before systemd and every session, so no process can look before the mount, and no
     unit has to be ordered.
   - The default user is resolved in Swift that is tested on the Mac, rather than in shell code
     that would repeat `MawConf`.
   - `/etc/maw.conf` and `/etc/passwd` are resolved inside the root: an absolute link starts
     again at the root, and `..` stops there. Only regular files of at most 4 MiB are read. A
     user that cannot be resolved gives root's uid and gid, and the console says why.
   - `/mnt` and `/mnt/mac` are examined with `fstatat(AT_SYMLINK_NOFOLLOW)` and opened with
     `O_NOFOLLOW`, and are created with mode 755 if missing. A link, another kind of file, or a
     mount point that is not empty is refused.
   - The mount is made on `/proc/self/fd/<n>` of the opened directory, with `nosuid`, `nodev`,
     `uid=` and `gid=`.
   - A failure is a line on the console, `maw-initramfs: /mnt/mac is not mounted: <reason>`,
     and never stops the boot.

   Busybox's `mount`, as `Guest/initramfs` builds it, could mount the share as well, but it
   would need the uid and gid from shell code.

3. **maw's kernel carries a patch**, `Guest/kernel/patches/0001-virtiofs-owner-options.patch`.
   It adds `uid=` and `gid=` options to virtiofs only, and sets every inode's owner and group
   to them, as WSL's drvfs does for `/mnt/c`.
   - With `default_permissions`, which virtiofs already sets, the guest checks each access
     against that owner and the file's mode: the default user is the owner, root is root, and
     other users get the group and other bits.
   - The Mac still checks every access against the owner's identity.
   - Without the options, nothing changes.
   - `build-kernel.sh` applies every patch with no fuzz and fails the build if one does not
     apply cleanly. `Guest/README.md`, "Bumping the kernel", describes how to refresh it.

   This adds to [decision record 0003](0003-guest-kernel.md), which ships the kernel from
   kernel.org: maw now carries one patch of its own.

4. **The daemon learns the mount at the start.** The agent's `info` reply, which the daemon
   asks for once while a machine starts, reports `macShareMounted` from
   `/proc/self/mountinfo` (protocol version 6). The snapshot's `macShare` names the Mac's path,
   which is the daemon's own, and `/mnt/mac` (daemon interface version 8). No request runs for
   every snapshot.

5. **The mount point stays on the distribution's disk**: an empty `/mnt/mac`, owned by root.
   An export, whose provisioning machine has no share, contains it, empty.

## Consequences

- A distribution is as trusted as a program the owner runs on the Mac. Root and the default
  user can read and write everything that the owner can, including `~/.ssh` and
  `~/Library/LaunchAgents` ([docs/security.md](../security.md)).
- Ownership checks in the guest, such as git's, accept the files under `/mnt/mac` for the
  default user, whoever looked first.
- The questions of macOS's privacy protection name `mawd`, and come back with each development
  build. Phase 13 signs the release build, so that an answer lasts across updates
  ([docs/known-limitations.md](../known-limitations.md)).
- A setting to turn the share off, for all distributions or one, belongs to phase 12.
- The snapshot reports the mount as it was at the start; a later `umount` in the guest does not
  reach it.
- The programs of Ubuntu 24.04's image do not walk `/mnt/mac`:
  - there is no indexer (`plocate`, `mlocate`, `updatedb`);
  - `man-db` reads only the manual paths;
  - the weekly `fstrim.service` lists `/mnt/mac` among the mounted file systems, and sends one
    discard request per file system, which virtiofs does not support (`--quiet-unsupported`).
    `MacShareIntegrationTests.leavesTheShareToFstrim` runs it.
