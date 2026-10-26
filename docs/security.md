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
  (phase 07 adds `/mnt/mac`), and no network path into the Mac other than NAT's. The only
  other connection it can open to the Mac is to the dial-back listener on vsock, which gives it
  nothing without a session's nonce.
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
  which only the process that runs the machine, `mawd`, can do. The daemon opens them only
  for `info`, `shutdown`, and `dialBack` requests; a session runs on a connection that the
  agent dials back (see the next section), whose descriptor the daemon hands to its client
  after the XPC checks above.
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

### The dial-back listener

While a machine runs, `mawd` listens on the machine's vsock port 19800
(`AgentProtocol.dialBackPort`), where the agent dials each session's connection in reply to a
`dialBack` request ([decision record 0017](decisions/0017-dial-back-for-sessions.md),
[docs/protocol.md](protocol.md)). It is the one exception to the phase 05 rule that nothing on
the Mac listens for the guest.

- **Who can reach it.** Only processes in that machine's guest, through its vsock device. The
  listener is a `VZVirtioSocketListener` inside `mawd`, not a socket of the Mac's network stack:
  other machines, other hosts, and processes on the Mac cannot connect to it. It is set when
  the machine starts running and removed when it stops.
- **The nonce is the boundary.** For each session, the daemon draws a 32-byte nonce from the
  system's random number generator and sends it to the agent on a connection that the daemon
  opened. It hands a dialed connection to a session only if the connection's first frame
  carries a nonce that a session of that machine waits for. A nonce is used once, is valid for
  5 seconds, and is compared in constant time. At most 64 sessions of a machine wait at once.
- **The source port only filters.** The daemon refuses at once, before reading anything, a
  connection from a source port of 1024 or above. In the guest kernel (6.18.57,
  `net/vmw_vsock/af_vsock.c`, `__vsock_bind_connectible`), binding a port at or below 1023
  needs `capable(CAP_NET_BIND_SERVICE)`, which is `ns_capable(&init_user_ns, ...)`: the
  capability in the initial user namespace. Root in a container that runs in that namespace,
  such as Docker's default, whose capabilities include `CAP_NET_BIND_SERVICE`, therefore
  passes the filter; a process in another user namespace does not, even as root there. Bound
  vsock ports are not separated by network namespace.
- **Before anything is read**, the daemon also refuses every connection while no session of
  the machine waits for one, and every connection once as many admitted connections have not
  yet sent their nonce as there are waiting sessions plus 4. From an admitted connection it
  reads exactly the 37-byte nonce frame, within 2 seconds, on a thread of its own, and closes
  the connection if the frame is late, malformed, or carries no waiting session's nonce.
- **A guest process without the capability** cannot bind a source port below 1024 (EACCES),
  and the daemon refuses its dials without reading from them. It cannot learn a nonce: the
  nonce travels only on the daemon's connection to the agent, which no other guest process
  can read, and the agent runs as root.
- **Guest root** can bind such a port and connect while a session opens, but without the
  nonce its connection is closed after at most 37 bytes or 2 seconds and receives nothing;
  guessing a 256-bit nonce is not feasible. Root could read a nonce from the agent's memory and
  take a session's connection, but root can already trace or replace the agent and read every
  session, so it gains nothing; the host treats every byte from the guest as untrusted.
- **Denial of service by guest root, accepted.** While a session opens, guest root can hold
  the places for connections without a nonce, as many as there are waiting sessions plus 4,
  for up to 2 seconds each, or bind every source port below 1024. The agent's dial is then
  refused, or finds no port, and the session fails with `sessionDialBackFailed`. While no
  session opens, every connection is refused before anything is read. This is accepted
  because root in the guest can stop or disturb its own machine in many other ways, and the
  failure is limited to that machine.
- **Nonces are never logged.** A nonce describes itself as `<nonce>`, refusals name their
  reason without it, and the security integration test checks that the console log contains
  neither the nonce that a refused dial sent nor any 64-digit hexadecimal string in a refusal.
  Refusals go to the machine's console log, at most 5 in 10 seconds.
- **Descriptors are closed on exec.** Virtualization.framework's own descriptor of a vsock
  connection does not have `FD_CLOEXEC` set. The daemon duplicates it with `F_DUPFD_CLOEXEC`
  and closes the framework's connection right away: in the connect completion handler for a
  connection it opens, and once the listener's delegate has returned for a dialed one. The
  console pipes are closed on exec as well, and the daemon starts programs with
  `POSIX_SPAWN_CLOEXEC_DEFAULT`, so that no program it starts inherits a session.

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
- Nothing on the Mac listens for the guest on this network, and other machines cannot connect
  to the guest: the NAT network is private to this Mac. The dial-back listener above is on
  vsock, not on this network.
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
