# Phase 05: Distro install

Read `CLAUDE.md`, `docs/decisions/`, `docs/protocol.md`, and `docs/daemon.md` first. Work on
branch `phase/05-distro-install` from the latest `main`.

This phase turns maw into a Linux subsystem that a person would choose to use: one command
installs Ubuntu, and `maw` then opens a fast, ordinary Ubuntu shell as the user's own account,
with working package management. Treat installation time, boot time, command latency, and the
clarity of every message as product requirements, not as finishing touches. Measure each of
them, and record the numbers in the PR.

## Goal

At the end of this phase, these commands work on the owner's Mac, with `.build/debug` on the
`PATH`:

```sh
maw --list --online                  # the distributions that can be installed
maw --install Ubuntu-24.04           # download, verify, provision, create the user
maw                                  # a login shell as that user, in the home directory
maw -- sudo apt update               # package management works
maw -u root -- id -u                 # prints 0
maw -- uname -r                      # the maw kernel, 6.18.x-maw
maw --status                         # the distribution's machine, running
```

`maw` without an installed distribution no longer falls back to the initramfs machine. It
fails with an error that names `maw --install` as the fix.

## Product requirements

### Speed targets

Measure each of these on the owner's Mac and record the median of 5 runs in the PR. If a
target is missed, report the number, where the time goes, and what would close the gap.

| Measurement | Target |
|-------------|--------|
| Install, from a verified cached image to the first prompt, excluding the download | under 45 s |
| Cold start: machine stopped, daemon running, to the end of `maw -e true` | under 1.5 s |
| Cold start to an interactive prompt (`maw`) | under 2 s |
| Warm `maw -e true` | median under 50 ms, as in phase 04b |
| Warm `maw` to a prompt | under 150 ms |
| `apt update` with a warm cache, compared with the same command in a Linux VM on another hypervisor if one is available | report only |

### Experience rules

- **Every long step shows progress.** The download shows size, speed, and remaining time. Each
  later step prints one line when it starts and its duration when it ends. Output stays quiet
  and aligned, in the style of the existing `maw` messages; no step prints raw tool output
  unless it fails.
- **Interruption is safe.** Ctrl-C or a failure at any point leaves no half-installed
  distribution, no registered entry, and no running machine. A partial download is kept in
  the cache and resumed by the next attempt when the server supports range requests.
- **Errors explain and suggest.** Every new failure is a `MawError` case with a message and a
  suggested fix: no network, a checksum mismatch, insufficient disk space (checked before the
  download starts), a name that is already installed, an invalid user name.
- **The first prompt feels like Ubuntu.** The user's own account, their home directory, a
  UTF-8 locale, a hostname that names the distribution, `sudo` that works, and no warnings
  printed at login.

## Architecture

### Distribution catalog

- A catalog of installable distributions ships in the binary, as a `Codable` resource in
  `MawCore`. Each entry has a name (`Ubuntu-24.04`), aliases (`Ubuntu` for the current LTS),
  a display name, the image URL, its size, and its SHA-256.
- **Image choice.** Canonical publishes several arm64 root file system archives for Ubuntu
  24.04, among them the cloud image root archive, the WSL image, and Ubuntu Base. Compare them
  in the plan on: install time, size, boot time to a prompt, the packages a developer expects
  (`sudo`, `bash-completion`, `man`, `curl`, `ca-certificates`), and the services that run at
  boot (`cloud-init`, `snapd`). Choose one, with measurements, and record the choice in a
  decision record.
- **Verification.** Pin the SHA-256 of a specific image serial in the catalog, and verify the
  download against it before anything reads it. Canonical also signs its checksum files with
  OpenPGP; maw has no OpenPGP implementation and adds no dependency for one in this phase.
  Record that trade-off in the same decision record, including how the catalog is updated when
  Canonical publishes a new serial.
- **Cache.** Verified images live in `~/Library/Caches/maw/images/`, so that a second install
  of the same image does not download again.

### Provisioning

- The daemon owns installation. `maw --install` sends a request and renders the progress
  events that the daemon sends back over XPC. The install continues only while the client is
  connected; when the client goes away, the daemon cancels it and cleans up.
- **Disk.** A sparse raw disk image at `~/Library/Application Support/maw/distros/<name>/
  disk.img`, with a virtual size of 256 GiB, formatted as ext4 inside the guest, as decision
  record 0003 requires. Choose the `mkfs.ext4` options for speed of first use (lazy
  initialization) and record them.
- **Getting the image into the guest.** The guest has no network during provisioning. Stream
  the archive into the provisioning guest through the guest agent, as standard input of the
  extracting command, which phase 04 already supports with back-pressure. Measure where
  decompression is faster, in the guest or on the host with `/usr/bin/tar` (libarchive), and
  choose the faster path.
- **Configuration inside the new root:** the hostname, `/etc/hosts`, the default user, the
  sudo group membership, `/etc/maw.conf` with `[user] default=<name>`, and the services that
  serve no purpose in maw masked (for example `cloud-init` and `snapd`, depending on the image).
  List every change in `docs/distributions.md`.
- **The user.** `maw --install` asks for a user name and a password, as WSL does, without
  echoing the password and asking for it twice. Validate the name against Ubuntu's rules
  before anything is created. `--user <name>` and a password read from standard input allow a
  non-interactive install for tests and scripts. The first installed distribution becomes the
  default.
- Record each distribution in `distros/<name>/distro.json`: name, catalog entry and serial,
  creation date, default user, and disk size.

### Booting a distribution

- Each installed distribution is a machine, `MachineID.distribution(name)`, with its disk
  attached. The initramfs mounts the disk as the root file system and switches to it.
- **systemd runs as PID 1**, as in current WSL releases of Ubuntu, so that services and
  `systemctl` work. `maw` must not wait for the whole boot: the guest agent starts as early as
  the boot allows, and a session can begin while other units are still starting.
- **The agent is not installed into the distribution.** The initramfs provides it at every
  boot (for example on a `/run` tmpfs, with a runtime systemd unit), so that a guest update
  never has to modify installed distributions. Record this in a decision record.
- Phase 12 adds a `systemd=false` option to `/etc/maw.conf`. Do not implement it now.
- **Resources.** Until phase 12 makes them configurable: all of the Mac's CPUs and half of its
  memory, as WSL does. Record that Virtualization.framework does not return guest memory to
  macOS without a balloon device, and leave that to phase 12.
- **Disk performance and safety.** Choose the disk attachment's caching and synchronization
  modes with a stated reason, and enable discard if Virtualization.framework supports it on
  macOS 14, so that deleted files return space to the Mac. Measure and record the effect.
- **Clean shutdown** keeps working through the agent, and now stops systemd cleanly.

### Network

- Attach a virtio network device with NAT (`VZNATNetworkDeviceAttachment`), so that `apt`
  and other outbound connections work from this phase on. The guest configures it with DHCP
  through the distribution's own network stack.
- Port forwarding, `localhost` access from macOS, and DNS behavior under VPNs remain phase 08.
  Update the phase 08 row in `docs/ROADMAP.md` to say so.

### Sessions as a user

- The exec request gains the user to run as. The agent looks the user up in the
  distribution, then sets the groups, group, and user, and builds a login environment
  equivalent to an ssh session: `HOME`, `USER`, `LOGNAME`, `SHELL`, `PATH`, and `LANG`. This
  changes the protocol; increase its version and update `docs/protocol.md`.
- **Shell sessions** start the user's login shell from `/etc/passwd`, in the home directory,
  and register with `systemd-logind` when it runs, so that `XDG_RUNTIME_DIR` and
  `systemctl --user` work. **Direct commands** (`-e`) must not pay for a login session; keep
  them within the warm latency target.
- **Locale.** Use the host's language and region when the distribution has that locale, and
  `C.UTF-8` otherwise. Phase 11a found that an invalid locale breaks multibyte input, so test
  Turkish input at the shell prompt again.
- `-u <user>` runs as another user, and `-u root` as root.
- `maw <command>` passes the command to the user's login shell with `-c`, replacing the
  `/bin/sh -c` of phase 04b.

### Command line

- `--install [<distro>]` and `--list --online` are implemented. Without a name, `--install`
  installs the catalog's recommended entry.
- Remove the initramfs fallback marked `PHASE 05` in `Sources/maw/SessionPlan.swift`. The
  initramfs machine remains for provisioning and for `mawd debug-boot`.
- `maw --status` shows each distribution's machine by its name.
- The terminal app is unchanged; phase 11b connects it.

## Tests

**Unit tests, run in CI:**
- The catalog: decoding, aliases, the recommended entry, and every entry's URL and SHA-256
  format.
- Verification: a matching file passes; a wrong hash, a truncated file, and a missing file
  fail with their own errors.
- User name validation, against Ubuntu's rules.
- The install request, its progress events, and cancellation, against a fake provisioner.
- The protocol's new user fields, their `Codable` round trip, and the version check.
- The locale choice.
- Free space checks, with an injected volume size.

**Integration tests** (`.integration`, through `scripts/integration-test.sh`):
- They use a cached image, so that only the first run downloads.
- A full install into a temporary distribution name, then: the prompt runs as the new user in
  their home directory; `sudo -n true` fails without a password and `sudo` with it succeeds;
  `id -u` as root prints 0; `systemctl is-system-running` reaches `running` or `degraded` with
  the failed units listed; `apt update` succeeds; Turkish characters typed at the prompt echo
  intact.
- Installing a name that exists fails without touching the existing distribution.
- Cancelling an install during each step leaves nothing behind.
- A clean shutdown of a distribution's machine records `shutdown: clean`.
- The measurements listed under "Speed targets".
- Every test removes the distributions it created.

## Docs

- `docs/distributions.md`: the catalog, how an image is chosen and verified, what provisioning
  changes in the root file system, the boot sequence, and how sessions become a user.
- Decision records: the image choice and its verification; systemd as PID 1 with the agent
  provided by the initramfs; network in phase 05.
- `docs/protocol.md` and `docs/daemon.md` updated.
- `README.md`: installing Ubuntu, and the first steps after.
- `docs/ROADMAP.md`: mark 05 as done, and update the phase 08 row.

## Out of scope

- `--list` of installed distributions, `--set-default`, `--terminate`, `--export`, `--import`,
  and `--unregister` (phase 06). Until then, the README explains how to remove a test
  distribution by hand.
- `/mnt/mac` and working-directory translation (phase 07).
- Port forwarding and `localhost` access (phase 08).
- Distributions other than Ubuntu 24.04.
- `.mawconfig`, the remaining `/etc/maw.conf` settings, the memory balloon, and sleep and wake
  (phase 12).
- The terminal app (phase 11b).

## Acceptance criteria

- `swift build -Xswiftc -warnings-as-errors`, `swift test`, and `swift format lint --strict`
  pass, and CI and the Guest workflow are green.
- The commands under "Goal" behave as described on the owner's Mac.
- `scripts/integration-test.sh` passes, and the PR records every measurement under "Speed
  targets".
- The owner confirms, on the Turkish keyboard:
  - the install prompts are clear, and the progress output is readable;
  - Ctrl-C during the download leaves nothing behind, and the next install resumes it;
  - in `maw`, the prompt shows their user name and the distribution's host name, Turkish
    characters type correctly, `vi` and `top` work, and `sudo apt install htop` succeeds;
  - `maw` opens noticeably fast when the machine is already running.

## How to work

1. Present a short plan first. It must cover:
   - the image comparison with its measurements, and the choice;
   - the provisioning sequence and where decompression runs;
   - the boot sequence, from the initramfs to systemd, and how the agent starts early;
   - how the agent switches to the user and registers a login session;
   - the network attachment.

   Wait for approval.
2. Push early as a draft PR so that the Guest workflow runs while you work on the host side.
3. Ask the owner to run the interactive checks. You cannot type on their keyboard.
4. Finish with the PR, as described in the Workflow section of `CLAUDE.md`.
