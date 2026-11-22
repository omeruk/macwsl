# Distributions

A distribution is a Linux root file system on a disk image of its own, which boots in a
machine of its own with the maw kernel and systemd. This document describes how maw installs
one, what it changes in it, how it boots, and how sessions become a user. The code is in
`Sources/MawCore/DistroCatalog.swift`, `Sources/MawDaemonKit/Installer.swift`,
`Sources/MawDaemonKit/ProvisioningScript.swift`, and `Guest/initramfs/init`.

## The catalog

`maw --list --online` lists the distributions that maw can install:

```
The distributions that maw --install can install. * marks the one it installs when no name is given.

    NAME          ALSO    DESCRIPTION       DOWNLOAD
  * Ubuntu-24.04  Ubuntu  Ubuntu 24.04 LTS  388.3 MB
```

The catalog is built into the binary. Each entry pins one image by its HTTPS URL, size, and
SHA-256, and records the space the extracted root file system needs and the user and group
names that already exist in it. [Decision record 0012](decisions/0012-ubuntu-image.md) explains
why Ubuntu comes from its WSL image, how the image is verified, and how a new image is pinned.

Names are matched without regard to case, and aliases select their entry: `maw --install
Ubuntu` installs `Ubuntu-24.04`. `--name <name>` installs an entry under another name, so that
one image can be installed more than once.

## Installing

```sh
maw --install                         # the recommended distribution, Ubuntu-24.04
maw --install Ubuntu-24.04 --name Work
maw --install 2>&1 | tee install.log  # keep the progress in a file
printf '%s\n' "$password" | maw --install -u ayse   # without a terminal
```

When standard input is a terminal, maw asks for the new account's name and for its password
twice, without echoing it. It asks on the controlling terminal (`/dev/tty`), as `sudo` and `ssh`
do, so the questions stay visible when standard output and standard error go to a pipe or a
file, and neither they nor the answers ever reach it. With `--user`, it asks only for the
password; without a terminal on standard input, the password is the first line of standard
input, and without `--user` as well, maw refuses, since there is nothing to ask on. When
standard output is a terminal too, a shell opens in the new distribution at the end; otherwise
the last line says how to open one. The daemon does the work and reports progress, one line per
step, redrawn in place only on a terminal:

| Step | What happens |
|------|--------------|
| Checking | The name must be unknown, and nothing else may be in `distros/` under it in any case: a directory left without `distro.json`, as a partial manual removal leaves it, is refused and never changed, since it may hold a disk. The user name must be valid by Ubuntu's rules (lowercase letter first, then lowercase letters, digits, `-` and `_`, at most 32 characters, not a name the image already uses), the password a non-empty single line, and the volume must have room for the rest of the download, the root file system, and 1 GB more. Nothing is downloaded before these checks pass. |
| Downloading | Only when the image is not in `~/Library/Caches/maw/images`. An interrupted download is kept and resumed. |
| Verifying the image | The size and the SHA-256, before every installation. A file that fails is removed. Ctrl-C stops the check before its next 4 MiB read and leaves the file as it is. |
| Creating the virtual disk | A 256 GiB sparse disk image, readable only by its owner, and the initramfs machine that provisions it. |
| Formatting the disk | `mkfs.ext4 -L maw-root -m 1 -E assume_storage_prezeroed=1,nodiscard`. |
| Extracting the root file system | `/usr/bin/tar` decompresses the image on the Mac and streams it, as a pax archive, to `bsdtar` in the guest, which keeps owners, permissions, and extended attributes. |
| Configuring | The changes listed below, and the password through `chpasswd`'s standard input. |
| Writing the disk | `sync`, unmount, power off. |
| Starting | The distribution's first boot, so that the first session is warm. |

Everything before "Starting" happens in `distros/.staging/<label>/<name>-<id>/`, where
`<label>` is the daemon's launchd label (`dev.maw.mawd`), and that directory is renamed to
`distros/<name>/` as the last step. Ctrl-C, a failure, the client's exit, or the daemon's stop
ends the installation, stops the provisioning machine at once, and removes the staging
directory; the daemon also removes staging directories left by a crash when it starts, only
under its own label (docs/daemon.md). No distribution can be named `.staging`, since a name
starts with a letter or digit. A distribution that registers while none is installed becomes
the default; of two installations that run at once, the first to register.

The provisioning machine's console goes to `~/Library/Logs/maw/install/<name>.log`. Earlier
builds wrote `install-<name>.log` beside the other logs; maw leaves those files where they are.
No distribution can be named `mawd`, `debug-boot-console`, or `initramfs`, in any case, since
its console log would be one of maw's own log files. Two installations of the same image share
one download: the second waits for the first's.

## What provisioning changes in the root file system

| Change | Why |
|--------|-----|
| `/etc/hostname`, `/etc/hosts`: the distribution's name in lowercase, other characters replaced by `-` (`ubuntu-24-04`) | The prompt names the distribution. |
| `/etc/fstab`: `LABEL=maw-root / ext4 defaults 0 0` | The initramfs checks and mounts the root; systemd needs no fsck of it. |
| A user, created with `useradd --create-home --shell /bin/bash`, in the groups `adm`, `dialout`, `cdrom`, `floppy`, `sudo`, `audio`, `dip`, `video`, `plugdev`, `netdev`, `users` that the image has | The groups WSL's Ubuntu setup gives the first user; `sudo` requires the user's password. |
| The user's password, set with `chpasswd` | It travels only as `chpasswd`'s standard input. |
| `~/.sudo_as_admin_successful`, empty and owned by the user | Ubuntu's `/etc/bash.bashrc` prints "To run a command as administrator (user "root"), use "sudo <command>"." at every login until this file exists, which `sudo` creates after its first successful use. The first prompt stays quiet; `sudo` itself is unchanged and asks for the password. |
| `/var/lib/systemd/linger/<user>` | The user manager runs from boot, so that a shell does not wait for it ([0015](decisions/0015-sessions-through-pam.md)). |
| `/etc/maw.conf` with `[user] default = <user>` | Sessions run as this user unless `-u` names another. |
| The Mac's locale generated with `locale-gen`, if the image supports it, and `/etc/default/locale` set to it; `LANG=C.UTF-8` otherwise | A UTF-8 character type in every session. |
| `/etc/netplan/50-maw.yaml` (mode 600): DHCP through systemd-networkd on the `virtio_net` device; `/etc/resolv.conf` linked to systemd-resolved's stub resolver | The network ([0014](decisions/0014-network-in-phase-05.md)). |
| `/etc/systemd/journald.conf.d/50-maw.conf`: `SystemMaxUse=256M` | journald's default allows 10% of the 256 GiB disk, at most 4 GB, which would stay allocated on the Mac. |
| The units below masked (linked to `/dev/null`) | They would run and serve no purpose in maw. `systemctl unmask` reverts each. |
| `/etc/profile.d/update-motd.sh` diverted with `dpkg-divert --rename` | The WSL image prints the message of the day from it once a day; the first prompt stays quiet. The diversion survives package updates. |

### Masked units

| Units | Why |
|-------|-----|
| `cloud-init-local.service`, `cloud-init.service`, `cloud-config.service`, `cloud-final.service`, `cloud-init-hotplugd.socket`, `cloud-init.target` | cloud-init configures cloud instances from a metadata source; maw configures the distribution itself. |
| `snapd.service`, `snapd.socket`, `snapd.seeded.service`, `snapd.apparmor.service`, `snapd.autoimport.service`, `snapd.core-fixup.service`, `snapd.recovery-chooser-trigger.service`, `snapd.system-shutdown.service`, `snapd.snap-repair.timer` | Snaps need squashfs and AppArmor, which the maw kernel lacks; snapd's stop alone delayed a shutdown by over 10 s. |
| `systemd-networkd-wait-online.service` | Waiting for "online" delays the end of the boot; the network is usable once DHCP answers. |
| `console-setup.service`, `keyboard-setup.service`, `setvtrgb.service` | A maw machine has no virtual terminals or keyboard. |
| `serial-getty@hvc0.service`, `getty@tty1.service` | Login prompts on the console and on a virtual terminal that nobody can see; sessions come through the guest agent. |
| `landscape-client.service` | The Landscape management client of the WSL image: never registered, and its check took 456 ms of every boot. |
| `motd-news.timer` | It fetches news for a message of the day that maw does not show. |
| `apport.service`, `apport-autoreport.path`, `apport-autoreport.timer`, `apport-forward.socket` | Crash reports and their upload. |
| `e2scrub_all.timer`, `e2scrub_reap.service` | Scrubbing of LVM snapshots; the disk has no LVM. |

### Units that stay

Measured 30 seconds after boot, 12 services run. These serve a purpose and stay enabled:

| Unit | Why it stays |
|------|--------------|
| `unattended-upgrades.service`, `apt-daily.timer`, `apt-daily-upgrade.timer` | Ubuntu's security updates. The service keeps a shutdown from interrupting an upgrade in progress. |
| `systemd-timesyncd.service` | Keeps the clock exact after the initramfs sets it from the Mac's. |
| `systemd-networkd.service`, `systemd-resolved.service` | The network and DNS. |
| `fstrim.timer` | Returns the blocks of deleted files to the Mac each week. |
| `systemd-journald.service`, `rsyslog.service` | The journal, and the text logs in `/var/log` that Ubuntu's tools read. |
| `cron.service`, `dbus.service`, `systemd-logind.service`, `systemd-udevd.service`, `user@<uid>.service` | Users' crontabs, the system bus, login sessions, devices, and the user manager. |

The image's WSL files `/etc/wsl.conf` and `/etc/wsl-distribution.conf` stay; nothing in maw reads
them. WSL's own units skip themselves outside WSL (`ConditionVirtualization=wsl`).

## Booting

[Decision record 0013](decisions/0013-systemd-and-the-agent.md) describes the boot sequence:
the initramfs sets the clock, checks and mounts the disk, supplies the guest agent as a runtime
systemd unit in a tmpfs on `/run`, and switches to the distribution's systemd. In the same
directory, `/run/systemd/system`, it writes the drop-in
`systemd-timesyncd.service.d/maw-order.conf`, which orders `systemd-timesyncd` after
`systemd-resolved`, so that a shutdown soon after a boot does not wait 5 s for
`systemd-timesyncd`. Both are gone when the machine stops, and neither is written into the
distribution's own files. The agent starts
with systemd, so that a session can begin while other units still start. Each machine gets every
CPU of the Mac and half of its memory, and reaches the network through NAT.

Measured on an M1 Pro, median of 5: a cold `maw -e true` in 593 ms, a cold `maw` to a prompt in
865 ms, a warm `maw -e true` in 29 ms, and a warm `maw` to a prompt in 132 ms. 30 seconds after
boot, an idle distribution uses 205 MB of memory and 0.02% of the CPUs.

## The Mac's files: /mnt/mac

Every distribution's machine shares the owner's home directory, read-write, and the initramfs
mounts it at `/mnt/mac` before it starts systemd, at every boot, without changing the
distribution's files beyond the mount point ([decision record 0021](decisions/0021-mac-share.md)).
A distribution installed before phase 07 gets it after the new guest files are installed and
its machine starts again.

- **The owner.** Every file under `/mnt/mac` shows the distribution's default user as its owner
  and that user's primary group as its group, whoever looks: `[user] default` in
  `/etc/maw.conf`, with its uid and gid from `/etc/passwd`, both read when the machine starts.
  Without a default user, files show as root's; with one that cannot be resolved, as root's as
  well, and the console log says why. The guest checks each access against that owner and the
  file's mode, as for any file: other users get the group and other bits. The Mac checks every
  access again against the owner's identity, so a file that the owner cannot read on the Mac
  stays unreadable. `chown` and the set-user-ID bit have no effect on the Mac; `chmod` does.
- **The mount point.** If the distribution has no `/mnt/mac`, the initramfs creates `/mnt` and
  `/mnt/mac`, owned by root, with mode 755: an empty directory on the distribution's disk is all
  that the share adds to it. A `/mnt` or `/mnt/mac` that is a symbolic link or not a directory,
  or a `/mnt/mac` that is not empty, is left alone and nothing is mounted; the console log says
  why. maw never writes the mount into `/etc/fstab`.
- **A failed mount** never stops the boot: sessions work, the console log has a line
  `maw-initramfs: /mnt/mac is not mounted: <reason>`, and the distributions screen shows no
  `mounts` row.
- **Mount options.** `virtiofs maw-mac` with `nosuid`, `nodev`, and `uid=` and `gid=` of the
  default user, as `/proc/self/mountinfo` shows them. A default user whose uid or gid is
  4294967295, which the kernel refuses as an owner, gives root's ownership, as one that cannot be
  resolved does.

### mawpath

`mawpath` translates paths between the Mac and the distribution, as `wslpath` does
([decision record 0022](decisions/0022-working-directory-and-logind.md)): `mawpath <path>` or
`mawpath -u <path>` gives a Mac path's place under `/mnt/mac`, `mawpath -m <path>` the Mac path
of a path under `/mnt/mac`, and `-a` an absolute result for a relative path. A path that the
other side cannot see is an error, and the path need not exist.

- **The link.** When a distribution's machine starts, the agent links `/usr/local/bin/mawpath`
  to `/run/maw/maw-agent`, the agent's binary, before it serves a session. This link is the one
  file that `mawpath` adds to a distribution's disk. It dangles while the machine is stopped,
  and an export contains it; an import into maw makes it work again.
- **When there is none.** If `/usr`, `/usr/local`, or `/usr/local/bin` is missing or is itself
  a symbolic link, the agent makes no link, and `mawpath` is not on PATH; a `mawpath` that is
  not maw's link is left as it is. In both cases the console log has a line
  `maw-agent: mawpath is not on PATH: <reason>`.
- **The Mac home directory** comes from the kernel command line, `maw.home=<path>`,
  percent-encoded. A home directory longer than 1,024 bytes once encoded is not passed, and
  `mawpath` then reports that it is not known.

## Sessions

A session runs as the distribution's default user, `[user] default` in `/etc/maw.conf`, or as
the user that `-u` names. [Decision record 0015](decisions/0015-sessions-through-pam.md)
explains how the agent switches to the user and registers login shells with `systemd-logind`,
and [docs/protocol.md](protocol.md) specifies the environment a session gets.

- `maw` opens the user's login shell from `/etc/passwd`.
- `maw <command>` runs the command line with the user's shell, as `<shell> -c <command>`.
- `maw -e <program> [<argument>...]` runs the program directly.

**The working directory** ([decision record 0022](decisions/0022-working-directory-and-logind.md)):

- **Without `--cd`**, a session starts in the Linux path of `maw`'s current directory: the
  home directory is `/mnt/mac`, and `~/Projects/app` is `/mnt/mac/Projects/app`. Outside the
  home directory, such as in `/tmp` or `/Volumes/USB`, or when the current directory no longer
  exists, it starts in the user's Linux home directory, and `maw` says so in one line on
  standard error.
- **When that directory cannot be used in Linux**, because the share is not mounted, the
  directory is gone, or the user cannot enter it, the session also starts in the home
  directory, and `maw` says why; when the share is not mounted, the line names the console
  log.
- **`--cd`** takes `'~'` and `'~/<path>'` for the Linux home directory and a path under it, an
  absolute Linux path as given, a Mac path under the home directory, translated, and a path
  relative to the current directory. A Mac path outside the home directory is an error. A
  `--cd` directory that cannot be entered is an error too; it never falls back.
- **A login shell in a directory** starts through `runuser -l`, with the agent as its shell
  helper, so it is a `systemd-logind` session like any other.

## Files on the Mac

| Path | Content |
|------|---------|
| `~/Library/Application Support/maw/distros/<name>/disk.img` | The sparse disk image, mode 600. About 1.3 GB is allocated after installation. |
| `~/Library/Application Support/maw/distros/<name>/distro.json` | Name, creation date, default user, disk size, MAC address, and where the distribution came from: the catalog entry, release, and image SHA-256, or, for an imported one, the archive's path or `standard input`. Since `maw --import`, new files have schema version 2; files of schema version 1 are read as they are and never rewritten. A build from before schema 2 reads the file of a distribution installed from the catalog, and skips an imported one: it does not list it, and commands that name it fail with "cannot be used". Remove imported distributions with `maw --unregister` before going back to such a build, or keep them until this build is installed again. |
| `~/Library/Application Support/maw/state.json` | The default distribution. |
| `~/Library/Caches/maw/images/<sha256>.tar.gz` | Verified images, and `.partial` downloads with their validator. |
| `~/Library/Logs/maw/<name>.log` | Each distribution's console. |
| `~/Library/Logs/maw/install/<name>.log` | The console of the machine that provisioned the distribution. |
| `~/Library/Logs/maw/export/<name>.log` | The console of the machine that ran the distribution's last export. |

`maw --unregister` deletes the distribution's directory and its three logs. When it removes the
default, `state.json` records the new default instead. The image cache is kept.

## Removing a distribution

`maw --unregister <name>` stops the distribution's machine, if it runs, and deletes the
distribution with its disk. On a terminal it first asks "Delete <name> and its disk for good?
[y/N]", and only `y` or `yes`, in any case, goes on; anything else, an empty line, or Ctrl-D
changes nothing and exits with status 1. Without a terminal on standard input, and with
`--yes`, it asks nothing, as `wsl.exe --unregister` does. A name that is not installed fails
before the question.

The daemon then:

1. holds the name, so that every other request that names the distribution fails with "<name>
   is being removed by maw --unregister." until the removal is done;
2. stops its machine, which ends its sessions with the reason "maw --unregister was run";
3. renames its directory into the daemon's staging directory,
   `distros/.staging/<label>/<name>-<UUID>.removed`, which is the moment it stops being
   installed;
4. if the distribution was the default, records the first distribution that `maw --list`
   shows as the default in `state.json`, which maw names on standard error, so that a later
   installation does not take its place;
5. deletes the distribution's logs, and then the renamed directory.

Nothing after the rename is undone or interrupted, by Ctrl-C or by the daemon's exit. A
directory that could not be deleted, for example because the daemon exited, is deleted at the
daemon's next start. maw removes only installed distributions: a directory in `distros/`
without a `distro.json` is never touched. [docs/daemon.md, "Removing a
distribution"](daemon.md#removing-a-distribution) describes the sequence in the daemon.

A distribution can still be removed by hand, with `maw --terminate <name>` and then deleting
its directory, but the terminal app's distributions screen may keep showing it for a while
([docs/known-limitations.md](known-limitations.md)).

## Exporting a distribution

`maw --export <name> <file>` writes the root file system of a stopped distribution to a tar
archive, and `maw --export <name> -` writes it to standard output. A running distribution is
refused with the suggestion to stop it with `maw --terminate`. The format follows the file's
extension, as `tar -a` does:

| Name | Format |
|------|--------|
| `.tar.gz`, `.tgz`, `.gz`, in any case | `tar.gz`, gzip |
| `.tar.xz`, `.txz`, `.xz`, in any case | `tar.xz`, xz |
| any other name, and `-` | `tar`, uncompressed |

`--format tar`, `--format tar.gz`, or `--format tar.xz` chooses the format whatever the name
is.

maw opens the file itself and passes the open descriptor to the daemon, which, as a
LaunchAgent, lacks the privacy permissions that Terminal has for folders such as `~/Desktop`
and `~/Documents`. It creates the file only after the daemon has accepted the export, with mode
600, because the archive holds `/etc/shadow` and every user's files, and it never replaces an
existing file or follows a symbolic link in its place. When the export fails or is cancelled,
maw removes the file, but only if its path still names the file that maw created. Progress goes
to standard error, so that `-` keeps standard output for the archive alone; `-` is refused when
standard output is a terminal.

The export boots the provisioning machine, the initramfs, with the distribution's disk
attached, and:

1. checks the file system with `e2fsck -p`, as a start of the distribution does; a file system
   that fails the check is reported as at a start, and nothing is exported;
2. mounts it read-only, without replaying its journal (`ro,noload`);
3. runs `bsdtar -c --format pax --numeric-owner --xattrs` in the guest, whose output reaches
   the daemon over vsock; for `tar.gz` and `tar.xz` the daemon compresses it on the Mac with
   `/usr/bin/tar`;
4. writes the archive to maw's descriptor, and stops the machine.

The provisioning machine has no share of the Mac's files, so the archive contains `/mnt/mac`
as the empty directory it is on the disk, never the Mac's files. The archive keeps numeric
owners and groups, permissions with the set-user-ID, set-group-ID,
and sticky bits, extended attributes of the `user`, `trusted`, and `security` namespaces, file
capabilities among them, hard links, symbolic links, device files, FIFOs, and names with
non-ASCII characters. It does not keep POSIX ACLs ([docs/known-limitations.md](known-limitations.md)). A
reader that stops early, as `maw --export <name> - | head -c 1` does, ends the export with a
message that names the closed pipe. A slow reader holds the machine back instead of making the
daemon buffer, because each write to the descriptor waits for the reader.

While a distribution is being exported, a session on it, `maw --unregister`, and a second export
fail with "<name> is being exported by maw --export."; `maw --terminate` and `maw --set-default`
work as for any stopped distribution, and the list shows it as `Stopped`. Ctrl-C asks the
daemon to cancel, which stops the provisioning machine, and maw removes the file. The machine's
console goes to `~/Library/Logs/maw/export/<name>.log`.

## Importing a distribution

`maw --import <name> <file>` creates the distribution `<name>` from a tar archive, and
`maw --import <name> -` reads the archive from standard input, so that
`maw --export Ubuntu-24.04 - | maw --import Copy -` copies a distribution. The archive is a
tar archive in the ustar, pax, or GNU format, uncompressed or compressed with gzip, bzip2, xz,
compress, or lzip, such as one from `maw --export`, from `wsl.exe --export`, or a
distribution's published root file system. The new name follows the installation's rules. An
archive in which every file is under one directory is refused, and so is anything that is not
such a tar archive: a `.vhdx` from `wsl.exe --export --vhd`, a zstd-compressed archive, an old
tar archive without the ustar magic, or another archive format. `-` is refused
when standard input is a terminal.

As for `--export`, maw opens the file itself and hands the daemon its descriptor, so that the
daemon needs no access to `~/Desktop` or `~/Documents`. `distro.json` records the absolute path
of the file that maw opened, or `standard input`. The import checks the free space first: 1 GB,
plus the archive's size times 1 for an uncompressed tar archive, 4 for gzip, and 6 for any other
compression; from a pipe, 1 GB.

The steps are those of an installation, with the archive in place of the image:

| Step | What happens |
|------|--------------|
| Creating the virtual disk | A sparse 256 GiB disk in the staging directory, and the provisioning machine. |
| Formatting the disk | As at installation. |
| Extracting the archive | `/usr/bin/gzip` on the Mac decompresses the archive, and `bsdtar` in the provisioning machine extracts it without `-P`: absolute paths lose their leading `/`, and `..` and extraction through links are refused. No program on the Mac reads the archive's format. |
| Checking the root file system | The archive must hold `etc/passwd` and `usr/` at its top level, and `/sbin/init` must lead to systemd. Links are followed inside the imported root, as the imported system follows them. The default user is chosen. |
| Configuring `<name>` | The system files below. |
| Writing the disk | As at installation. |
| Starting `<name>` | The first start. |

Ctrl-C, a failure, or a refusal before the registration leaves no distribution and no staging
directory behind; the provisioning machine's console log stays, for the failure. A distribution
imported while none is installed becomes the default. If the first start fails, the
distribution stays installed: maw prints the start's error, which names the distribution's
console log, `~/Library/Logs/maw/<name>.log`, and then `maw --unregister <name>`, which deletes
that log, and exits with status 1. The provisioning machine's console goes to
`~/Library/Logs/maw/install/<name>.log`. While an import runs, an installation or a second import
of the name fails with "<name> is being imported by maw --import.".

### What `--import` configures

The imported root file system keeps its users, its files, and its locale. The import changes
only what a root file system needs to boot and work in maw. Every path below is resolved inside
the imported root first, and a link where a file is written is replaced, not written through.

| Change | Why |
|--------|-----|
| `/etc/hostname` and `/etc/hosts` from the new name, as at installation | Two imports of one archive do not share a host name; WSL's generated `/etc/hosts` is replaced. |
| `/etc/fstab`, `/etc/netplan/50-maw.yaml`, the `/etc/resolv.conf` link, the journal's limit, and the masked units, as at installation | The root, the network, and the units, as maw needs them. Lines of the archive's `/etc/fstab`, such as WSL's drvfs mounts, are dropped. |
| `/etc/profile.d/update-motd.sh` diverted, if it is not diverted yet | As at installation. |
| `/etc/machine-id` emptied, and `/var/lib/dbus/machine-id` removed | systemd generates a new machine ID at the first boot, so that two distributions imported from one archive send different DHCP client IDs. |
| `/dev`, `/proc`, `/sys`, `/run` created if missing | The initramfs moves its file systems there. |
| Without netplan: `/etc/systemd/network/50-maw.network` (DHCP on the `virtio_net` device), and `systemd-networkd` and `systemd-resolved` enabled | Nothing else would configure the network. |
| `/var/lib/systemd/linger/<user>` for the default user, unless it is `root` | As at installation. |
| `/etc/maw.conf`: `[user] default = <user>`, if the file does not name that user yet; its other lines are kept | The guest agent reads the default user from it. |

No user is created and no password is asked. The default user is the user that `-u <user>`
names, which must exist in the archive's `/etc/passwd`, or else the import fails before
anything is registered. Without `-u`, it is `[user] default` from the archive's `/etc/maw.conf`,
or else from its `/etc/wsl.conf`, if that names a user with a valid name in the archive's
`/etc/passwd`; otherwise `root`, as after `wsl.exe --import`. `distro.json` records the same
user. maw's last lines name the user that sessions run as; with `root` because nothing named
another user, they say how to import again with `-u <user>`. For an archive made by
`maw --export`, every change but the host name, the machine ID, and the MAC address finds its
result already in place.

### An archive from WSL

| What the archive brings | What it would do in maw | What the import does |
|-------------------------|-------------------------|----------------------|
| `[boot] systemd=true` in `/etc/wsl.conf`, or no such line | Nothing: maw reads only `[user] default` from `/etc/wsl.conf`, and always boots `/sbin/init` | Nothing; `/sbin/init` must lead to systemd |
| `[boot] command`, `[automount]`, `[network]`, `[interop]` in `/etc/wsl.conf` | Nothing: maw does not apply them | Keeps the file as it is |
| `/etc/resolv.conf` written by WSL, or a link to `/mnt/wsl/resolv.conf` | Windows' DNS server, or no DNS | Replaces it with the link to systemd-resolved's stub resolver |
| `/etc/hosts` and `/etc/hostname` with the Windows host's name | The wrong host name | Replaces them |
| A drvfs line in `/etc/fstab`, such as `C: /mnt/c drvfs defaults 0 0` | A mount of a device that maw does not have | Replaces the file |
| A machine ID | The same DHCP client ID as other imports of the archive | Empties it |
| No `/etc/maw.conf` | Sessions as `root` | Writes the default user into it |
| No `systemd-resolved` (Debian's default) | The stub link leads nowhere: no DNS | Nothing ([docs/known-limitations.md](known-limitations.md)) |
| `systemd-networkd` or `systemd-resolved` masked | No network or no DNS | Nothing ([docs/known-limitations.md](known-limitations.md)) |
| An init that is not systemd | The guest agent never starts | Refuses the archive, naming what `/sbin/init` leads to |
