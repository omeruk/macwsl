# Security

This document lists every way into maw's guest and host, what protects each, and what is not
protected yet. A phase that adds an entry point updates it in the same branch. Phase 12b
reviews it as a whole.

## Trust model

- **The user who runs maw** controls it completely. Every part of maw runs as that user: the
  `maw` command, the daemon `mawd` (a LaunchAgent, not a system daemon), and the virtual
  machines. maw adds no privileges on the Mac.
- **The guest is the user's own Linux system.** Its root account is available to the Mac user
  through `maw -u root`, as `wsl -u root` gives it on Windows; the guest's `sudo` password
  protects the guest against processes inside the guest, not against the Mac user.
- **The guest must not reach beyond itself.** It has no access to the Mac's files in this phase
  (phase 07 adds `/mnt/mac`), and no network path into the Mac other than NAT's.
- **Downloads are not trusted** until they are verified against a value that maw pins.

## Entry points

### The daemon's XPC service

`mawd` serves the Mach service `dev.maw.mawd` ([docs/daemon.md](daemon.md)). It accepts a
connection only if the peer runs as the same user (`xpc_connection_get_euid`) and satisfies the
code signing requirement `identifier "dev.maw.maw" or identifier "dev.maw.mawd"`.

- With ad-hoc signing, any local program can claim those identifiers, so the requirement guards
  against stale or unrelated builds, not against malicious programs. Until phase 13 signs with a
  Developer ID, **the same-user check is the boundary**: only processes of the user who already
  controls maw can use it.
- Every message carries the interface version, which is checked before the body is decoded.
  Bodies are JSON decoded into fixed types; a malformed body fails the request.
- Phase 13 adds the team identifier to the requirement, which only Apple's certificate chain
  can satisfy.

### The guest agent over vsock

`maw-agent` listens on vsock port 19799 in every machine ([docs/protocol.md](protocol.md)). Only
the host may connect:

- On the Mac, vsock connections into a machine are opened through Virtualization.framework,
  which only the process that runs the machine, `mawd`, can do. The daemon hands a
  connection's descriptor to its client after the XPC checks above.
- Inside the guest, the kernel is built without the vsock loopback transport
  (`CONFIG_VSOCKETS_LOOPBACK` is not set, and `Guest/kernel/check-config.sh` requires that), so a
  guest process cannot connect to the guest's own ports.
- The agent independently accepts only peers whose context ID is the host's (2), and closes
  any other connection before reading from it, logging the refusal.

The phase 05 security review found that both were missing: Kconfig enables the loopback
transport by default, and any account in a distribution could reach the agent and run commands
as root without a password. An integration test now checks that a guest process cannot.

- The agent runs as root and starts any program as any user it is asked to. It is the
  boundary's guest side, not a boundary itself.
- The host treats the guest as untrusted input: frames are length-checked before they are
  read, payloads are limited to 1 MiB, buffers are bounded in both directions, and a malformed
  frame closes only its connection. The fuzz test sends 10,000 random frames.

### Guest files from CI

`scripts/fetch-guest.sh` downloads the kernel and initramfs that the Guest workflow built, from
the latest successful run on a branch, with the signed-in GitHub CLI. It checks every file
against the run's `SHA256SUMS` before installing it and again after.

- The trust anchor is the GitHub repository and its workflow: whoever can push a branch and get
  a Guest run to succeed can produce files that `fetch-guest.sh` accepts. The build is
  reproducible, so that anyone can rebuild a run's files and compare them.
- Phase 13 replaces this with signed guest releases.

### Distribution images

`maw --install` downloads a root file system image ([decision record
0012](decisions/0012-ubuntu-image.md), [docs/distributions.md](distributions.md)).

- The catalog, compiled into `maw` and `mawd`, pins each image's HTTPS URL, size, and SHA-256.
  The SHA-256 of Ubuntu 24.04.5's WSL image is the one in Canonical's `SHA256SUMS`, whose
  OpenPGP signature was checked when it was pinned.
- Downloads use HTTPS only; a redirect to another scheme fails. A download that grows beyond
  the pinned size is stopped.
- **Nothing reads an image before its size and SHA-256 match.** The check runs before every
  installation, also for a cached image; a file that fails is deleted.
- A partial download is resumed only when the server's `ETag` still matches (`If-Range`); the
  final SHA-256 check covers the joined file in any case.
- maw does not check OpenPGP signatures at installation; it has no OpenPGP implementation. The
  pinned SHA-256 makes that unnecessary for pinned images, at the cost of a maw release for
  every new image.

### The extraction

The verified image is decompressed on the Mac by `/usr/bin/tar` and extracted in the
provisioning machine by `bsdtar`, as root, with `--numeric-owner`, into the new disk only.

- An image cannot write outside the new root: `bsdtar` refuses absolute paths and `..`
  components by default, and the disk is the only one attached.
- `bsdtar` comes from libarchive 3.8.10, built in the guest build container from a tarball
  pinned by SHA-256 (`Guest/initramfs/SOURCES`), whose OpenPGP signature by libarchive's release
  maintainer was checked when it was pinned. It is linked statically, without compression
  libraries.
- `/usr/bin/tar` runs with only its standard descriptors and `/dev/null` as input, so it cannot
  reach the daemon's connections.

### The password

maw asks for the new account's password once per installation.

| Stage | How it travels |
|-------|----------------|
| `maw` | Read with `readpassphrase(3)`, without echo, from the controlling terminal; or the first line of standard input with `--user`. The buffer is cleared after reading. |
| XPC to `mawd` | Inside the `install` request's JSON body, to the same-user peer that passed the checks above. The value is a `Secret`, whose descriptions print `<redacted>`. |
| `mawd` | In memory while the installation runs. It is never logged and is not part of any error message. |
| vsock to the provisioning machine | As the standard input of `chroot /mnt/root /usr/sbin/chpasswd`, never in an argument, the environment, or a script. |
| The guest | `chpasswd` stores its hash in `/etc/shadow`. |

Swift strings cannot be wiped, so copies may stay in the memory of `maw` and `mawd` until it is
reused. A test checks that no description of an install request contains the password.

### The NAT network

From phase 05 each distribution has a virtio network device with
`VZNATNetworkDeviceAttachment` ([decision record 0014](decisions/0014-network-in-phase-05.md)).

- The guest can open outbound connections, as any program on the Mac can.
- Nothing listens on the Mac for the guest, and other machines cannot connect to the guest:
  the NAT network is private to this Mac.
- Port forwarding and `localhost` access arrive in phase 08 and will be described here.

### Files on the Mac

- Disk images are created with mode 600: they contain the distribution's files, including its
  password hashes.
- `distro.json`, `state.json`, the image cache, and the logs contain no secrets. The console
  logs contain what the guest prints on its console: the kernel log, systemd's status messages,
  and the agent's log, which records commands' process IDs but not their arguments or input.

## Known gaps

- The ad-hoc code signing requirement does not identify maw's builds; phase 13.
- Guest files come from CI artifacts rather than signed releases; phase 13.
- The password's copies in memory are not wiped (see above).
