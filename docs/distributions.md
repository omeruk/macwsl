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
printf '%s\n' "$password" | maw --install -u ayse   # without a terminal
```

In a terminal, maw asks for the new account's name and for its password twice, without
echoing it, and opens a shell in the new distribution at the end. The daemon does the work and
reports progress, one line per step:

| Step | What happens |
|------|--------------|
| Checking | The name must be unknown, the user name valid by Ubuntu's rules (lowercase letter first, then lowercase letters, digits, `-` and `_`, at most 32 characters, not a name the image already uses), the password a non-empty single line, and the volume must have room for the rest of the download, the root file system, and 1 GB more. Nothing is downloaded before these checks pass. |
| Downloading | Only when the image is not in `~/Library/Caches/maw/images`. An interrupted download is kept and resumed. |
| Verifying the image | The size and the SHA-256, before every installation. A file that fails is removed. |
| Creating the virtual disk | A 256 GiB sparse disk image, readable only by its owner, and the initramfs machine that provisions it. |
| Formatting the disk | `mkfs.ext4 -L maw-root -m 1 -E assume_storage_prezeroed=1,nodiscard`. |
| Extracting the root file system | `/usr/bin/tar` decompresses the image on the Mac and streams it, as a pax archive, to `bsdtar` in the guest, which keeps owners, permissions, and extended attributes. |
| Configuring | The changes listed below, and the password through `chpasswd`'s standard input. |
| Writing the disk | `sync`, unmount, power off. |
| Starting | The distribution's first boot, so that the first session is warm. |

Everything before "Starting" happens in `distros/.staging-<name>-<id>/`, which is renamed to
`distros/<name>/` as the last step. Ctrl-C, a failure, the client's exit, or the daemon's stop
ends the installation, stops the provisioning machine at once, and removes the staging
directory; the daemon also removes staging directories left by a crash when it starts. The first
installed distribution becomes the default.

The provisioning machine's console goes to `~/Library/Logs/maw/install-<name>.log`. Two
installations of the same image share one download: the second waits for the first's.

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
systemd unit in a tmpfs on `/run`, and switches to the distribution's systemd. The agent starts
with systemd, so that a session can begin while other units still start. Each machine gets every
CPU of the Mac and half of its memory, and reaches the network through NAT.

Measured on an M1 Pro, median of 5: a cold `maw -e true` in 593 ms, a cold `maw` to a prompt in
865 ms, a warm `maw -e true` in 29 ms, and a warm `maw` to a prompt in 132 ms. 30 seconds after
boot, an idle distribution uses 205 MB of memory and 0.02% of the CPUs.

## Sessions

A session runs as the distribution's default user, `[user] default` in `/etc/maw.conf`, or as
the user that `-u` names. [Decision record 0015](decisions/0015-sessions-through-pam.md)
explains how the agent switches to the user and registers login shells with `systemd-logind`,
and [docs/protocol.md](protocol.md) specifies the environment a session gets.

- `maw` opens the user's login shell from `/etc/passwd`, in the home directory.
- `maw <command>` runs the command line with the user's shell, as `<shell> -c <command>`.
- `maw -e <program> [<argument>...]` runs the program directly.

## Files on the Mac

| Path | Content |
|------|---------|
| `~/Library/Application Support/maw/distros/<name>/disk.img` | The sparse disk image, mode 600. About 1.3 GB is allocated after installation. |
| `~/Library/Application Support/maw/distros/<name>/distro.json` | Name, catalog entry, release, image SHA-256, creation date, default user, disk size, MAC address. |
| `~/Library/Application Support/maw/state.json` | The default distribution. |
| `~/Library/Caches/maw/images/<sha256>.tar.gz` | Verified images, and `.partial` downloads with their validator. |
| `~/Library/Logs/maw/<name>.log` | Each distribution's console. |
| `~/Library/Logs/maw/install-<name>.log` | The console of the machine that provisioned the distribution. |

## Removing a distribution by hand

Phase 06 adds `maw --unregister`. Until then, a distribution is removed by stopping its machine
and deleting its directory:

```sh
maw --shutdown
rm -r "$HOME/Library/Application Support/maw/distros/<name>"
```
