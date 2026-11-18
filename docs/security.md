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
- **A distribution is as trusted as a program the owner runs on the Mac.** Since phase 07 it
  has the owner's home directory at `/mnt/mac`, with the owner's rights, as a WSL distribution
  has `C:` at `/mnt/c` (see "The share of the home directory"). Beyond the home directory, the
  guest must not reach: it has no other files of the Mac, and no network path into the Mac
  other than NAT's. The only other connection it can open to the Mac is to the dial-back
  listener on vsock, which gives it nothing without a session's nonce.
- **Downloads are not trusted** until they are verified against a value that maw pins.

## Entry points

### The daemon's XPC service

`mawd` serves the Mach service `dev.maw.mawd` ([docs/daemon.md](daemon.md)). It accepts a
connection only if the peer runs as the same user (`xpc_connection_get_euid`) and satisfies the
code signing requirement
`identifier "dev.maw.maw" or identifier "dev.maw.mawd" or identifier "dev.maw.app"`.

- With ad-hoc signing, any local program can claim those identifiers, so the requirement guards
  against stale or unrelated builds, not against malicious programs. Until phase 13 signs with a
  Developer ID, **the same-user check is the boundary**: only processes of the user who already
  controls maw can use it.
- Since phase 11b, the terminal app (`dev.maw.app`) is a client as well. It sends the requests
  that `maw` sends and receives a session's descriptor in the same way, so accepting it gives
  that user nothing that `maw` does not already give them. Each of its Linux sessions holds a
  connection of its own, and with it a lease, only while the session is open. The descriptor
  is duplicated with close-on-exec set (`InterfaceCoding.descriptor(in:)`), so that no program
  that the client starts afterwards inherits the session; the app also starts its local shells
  so that they inherit no descriptor (see "Descriptors in the terminal app").
- Since interface version 3, a client can also change the default distribution
  (`setDefault`) and stop one distribution (`terminate`). Any process of the same user could
  already do both: `shutdown` stops every distribution, and `state.json`, which records the
  default, belongs to that user. The same-user check therefore stays the boundary. Neither
  request starts a machine, and both accept only names of installed distributions. A client
  can also list the installed distributions with the state of each machine and the default
  (`listDistributions`). The listing changes nothing, and it shows only what that user can
  already read in the distributions directory and with `status`.
- **`watchDistributions`.** The request is available to every peer that the peer check accepts.
  It reveals what `status` and `listDistributions` reveal, and the figures. The number of
  watchers does not change how often the daemon samples, a connection has at most one watch
  outstanding, and a held connection keeps the daemon running but takes no lease, so it keeps no
  machine running. The terminal app holds one such connection, only while at least one of its
  windows shows the distributions screen, and closes it when none does.
- The app's measurement harness (`App/MawTerminalKit/Tests/FiguresHarness`) is signed ad hoc
  with the app's identifier, `dev.maw.app`, by `scripts/measure-figures.sh`, as
  `scripts/integration-test.sh` signs its probe as `dev.maw.maw`. Nothing installs it, and it
  refuses to run unless `MAW_DAEMON_LABEL` names a daemon other than the installed one. It gains
  nothing that the same-user check does not already allow.
- **Removal and export (interface version 6).** A client can delete a distribution with its
  disk (`unregister`), and have the daemon write a distribution's whole root file system,
  `/etc/shadow` and every user's files included, to a descriptor that the client supplies
  (`export`). Any process of the same user can already do both to the files in `distros/`,
  which belong to that user: delete them, or read the disk image. The same-user check therefore
  stays the boundary. Both accept only names of installed distributions, resolved by the
  daemon; `unregister` never touches a directory without a valid `distro.json`.
- **The export's descriptor.** The daemon never opens a path for an export: `maw` opens the
  file and passes the descriptor in the message's `descriptor` field. The daemon accepts it only
  if it is open for writing, refuses a terminal, and closes its copy before it replies. It
  changes nothing about the descriptor's open file description, which the client's other
  processes share; the daemon ignores SIGPIPE, so a reader that closes its end cannot end it.
  A descriptor in any request other than `export` and `import` is ignored. Because the client
  opens the file, the daemon, a LaunchAgent without the user's privacy permissions, needs no
  access to `~/Desktop` or `~/Documents`, and the privacy prompt never names it.
- **Import (interface version 7).** A client can create a distribution from an archive that it
  supplies through a descriptor (`import`). Any process of the same user can already create
  files in `distros/`, which belong to that user, so the same-user check stays the boundary.
  The daemon accepts the descriptor only if it is open for reading, refuses a terminal, and
  closes its copy before it replies. It never opens a path for an import: the request names the
  archive's path only so that `distro.json` can record it, as an absolute path of at most 1,024
  bytes or `standard input`, and `mawd.log` shows it with control characters escaped. The new
  name passes the installation's checks, and an import never writes into an existing entry of
  `distros/`.
- Every message carries the interface version, which is checked before the body is decoded.
  Bodies are JSON decoded into fixed types; a malformed body fails the request.
- Phase 13 adds the team identifier to the requirement, which only Apple's certificate chain
  can satisfy.

### Descriptors in the terminal app

The terminal app holds a descriptor for each Linux session (the guest connection that the
daemon hands over) and starts local shells, which run any program the user types. A descriptor
that a local shell inherited would let any of those programs read and write a Linux session's
terminal, so the app keeps them apart in two layers:

- **Local shells start through a fork that closes every other descriptor**
  (`maw_terminal_spawn` in `App/MawTerminalKit/Sources/CMawTerminal/terminal.c`). The child,
  which makes only async-signal-safe calls, resets every signal to its default, starts a
  session, makes the pseudo-terminal its controlling terminal and its standard input, output,
  and error, closes every other descriptor below the soft `RLIMIT_NOFILE` (capped at
  `kern.maxfilesperproc`, above which the kernel hands out none), clears its signal mask, and
  executes the shell. The shell therefore receives no descriptor of the app, whether or not it
  is marked close-on-exec, including those that frameworks create, and no window remains between
  a descriptor's creation and its flag. The terminal's own primary side is opened with
  `O_CLOEXEC` as well. Phase 11a started local shells with `forkpty`, which closed nothing.
  - `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT` would close the descriptors as well, but it
    cannot give the shell a controlling terminal on macOS: it runs its file actions before
    `POSIX_SPAWN_SETSID`, so the child opens the terminal before it leads a session, and it
    cannot call `TIOCSCTTY`. Without a controlling terminal, zsh has no job control, and Ctrl-C
    and Ctrl-Z reach no program. This was measured during phase 11b.
- **A received descriptor is duplicated with close-on-exec set**
  (`InterfaceCoding.descriptor(in:)`, `F_DUPFD_CLOEXEC`), as a second defence. libxpc set
  `FD_CLOEXEC` on the descriptors it returned on macOS 27.0.1, but does not document it.

A unit test opens a pipe without close-on-exec in the test process, starts a local shell
(`/bin/sh` and `/bin/zsh`), and checks through `/dev/fd` that the shell does not have it; with
`forkpty`, the same test fails.

### The share of the home directory (/mnt/mac)

Every distribution's machine shares the owner's home directory, read-write, through
Virtualization.framework's virtiofs device, and the initramfs mounts it at `/mnt/mac`
([decision record 0021](decisions/0021-mac-share.md)).

- **What it gives a distribution.** Root and the distribution's default user can read and write
  everything in the home directory that the owner can, with the owner's rights on the Mac:
  - `~/.ssh` and every other secret kept there;
  - `~/Library/LaunchAgents`, where a program put by the guest runs at the owner's next login,
    outside any virtual machine;
  - the other distributions' disks under `~/Library/Application Support/maw/distros/`, and
    maw's `state.json`;
  - the terminal app's `settings.json`.

  A distribution is therefore as trusted as a program the owner runs on the Mac. The owner
  decided this for phase 07, as WSL does for `/mnt/c`; phase 12 adds a setting to turn the
  share off.
- **Other users of the distribution** are held to each file's mode, against the default user as
  owner. maw's kernel patch (`Guest/kernel/patches/0001-virtiofs-owner-options.patch`) makes
  every file show the default user as its owner, and virtiofs checks modes in the guest:
  `nobody` can neither write a file of mode 644 nor read one of mode 600
  (`MacShareIntegrationTests.holdsOtherGuestUsersToTheFilesModes`). Without the patch, Apple's
  server reported every requester as the owner, and every guest user had the owner's full
  rights; decision record 0021 records the measurement.
- **What it does not give.**
  - Files that the owner cannot read or write on the Mac stay so: every access is made again
    on the Mac with the owner's identity, and a file of mode 000 is refused even to guest root.
  - The guest's ownership changes are ignored on the Mac. The set-user-ID bit is never set, the
    mount has `nosuid` and `nodev`, and `mknod` of a device is refused.
  - Folders under macOS's privacy protection (Desktop, Documents, Downloads, and others) are
    reached only if the owner allows `mawd` when macOS asks; a refusal is `Operation not
    permitted` in the guest. Folders that need Full Disk Access, such as `~/Library/Mail`, are
    refused without a question, because `mawd` does not have it.
  - Nothing outside the home directory is shared: not `/Volumes`, `/tmp`, or another user's
    home directory.
  - The provisioning machine of an installation, an export, or an import, which runs programs of
    root file systems that may come from outside maw, never gets the share. A unit test checks
    its configuration (`MachineConfigurationTests`), and the integration tests read its console:
    `maw-initramfs: virtiofs tags: none`.
- **The mount reads the distribution's files.** Before `switch_root`, the agent reads
  `/etc/maw.conf` and `/etc/passwd` of a root file system that may have been imported. It
  resolves both inside that root, so that an absolute link starts again at the root and `..`
  stops there; it reads only regular files, of at most 4 MiB; and it replaces control
  characters in a name before the console shows it. It examines `/mnt` and `/mnt/mac` without
  following links, refuses a link, another kind of file, or a mount point that is not empty, and
  mounts on the directory that it opened, so that no link in the path is followed.
- **Where the guest's input reaches the Mac.** The guest sends one Boolean, `macShareMounted` in
  its `info` reply, which only decides whether the distributions screen shows its `mounts` row.
  The Mac path in that row is the daemon's own; nothing that the guest sends is used as a Mac
  path.
- **Files that the guest can now write, and the app reads.** The terminal app's
  `settings.json` names the new-tab profile, such as `distribution:<name>`. A pane's notice
  never shows a name that is not a valid distribution name, because the notice goes to the
  terminal emulator, where control characters would take effect
  (`LinuxSessionTests.anInvalidNameOpensTheDefaultAndSaysSo`). The local shell's path from
  `localShell` is shown in two places: whole, in the pane's error when the shell cannot start,
  and its last component as the name of the tab and the window. Both show it with its control
  and format characters replaced by `?`
  (`LocalShellSessionTests.showsAMissingShellsPathWithoutControlCharacters`,
  `namesTheShellWithoutControlCharacters`), and cut after the last whole character within 256
  Unicode scalars, then "…" (`showsAtMost256CharactersOfAShellsPath`,
  `cutsAPathOfCombiningMarksAt256Scalars`, `neverSplitsACharacterAtTheCut`); the path that
  runs is unchanged. Every notice and error that a pane writes to the terminal emulator has
  its control and format characters replaced in the same way, except its line feeds, CR LF
  pairs, and tabs (`PaneControllerTests.aFailureWithEscapeSequencesAppearsAsTextInRed`,
  `endsALineAtACRLF`, `replacesControlCharactersButKeepsTheStyleAndTheLineBreaks`). The
  setting itself
  names the program that a local tab runs as the owner, so a guest that writes
  `settings.json` can already run a program on the Mac, as through `~/Library/LaunchAgents`.

### The guest agent over vsock

`maw-agent` listens on vsock port 19799 in every machine ([docs/protocol.md](protocol.md)). Only
the host may connect:

- On the Mac, vsock connections into a machine are opened through Virtualization.framework,
  which only the process that runs the machine, `mawd`, can do. The daemon opens them only
  for `info`, `sample`, `shutdown`, and `dialBack` requests; a session runs on a connection that the
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
- The foreground program's name (protocol version 4), which the terminal app shows when it asks
  before closing a Linux tab, is guest input as well. The host keeps at most 64 bytes of whole
  Unicode scalars and replaces control, format, and separator characters with U+FFFD
  (`ForegroundAnswer.displayableName`), so that a name cannot move the cursor, change colors,
  or reorder the text of a dialog.
- The kernel release in the agent's `info` reply is guest input too. The daemon keeps it for the
  distribution figures only after the same treatment (`ForegroundAnswer.displayableName`, in
  `VirtualMachineHandle.start()`), so that a client shows it as text.

### Figures from the guest

The `sample` request is a new reply from the guest, on a connection that the host opens. Root in
the guest can report any memory figures and any address for its own machine; they are only
displayed, in that machine's row. The host decodes the reply strictly, bounds its size by the
frame limit, rejects a reply whose available memory exceeds its total, accepts the address only
if it parses as an IPv4 address, and never logs text that the guest supplied. At most one
`sample` request is in flight per machine, with a reply timeout of 1 second, so a guest that
does not answer holds neither the daemon's threads nor more than one of the agent's 64
connections.

### Finding a machine's process

To read a machine's CPU time and memory footprint, the daemon looks for the machine's process
at the first sample of the machine's run, and only while a client watches the distributions; a
machine that runs while nothing watches is never looked up. It lists the process IDs and keeps
only processes whose executable is Virtualization.framework's
`com.apple.Virtualization.VirtualMachine` and whose user is the daemon's user. Only for those
processes does it list the open files, to find the one that has the distribution's disk image
open; it never lists the open files of any other process. These processes include the virtual
machines of other programs of the same user, such as other virtualization apps; the daemon
reads their open files' paths and identities, and nothing else, and keeps only the matching
process's ID and start time. A lookup that finds nothing is repeated at the next samples, at
most 10 times, and then given up for that run. It needs no privilege and gains no right.

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
  and the daemon refuses its dials without reading from them. While the agent runs, it cannot
  learn a nonce either: the nonce travels only on the daemon's connection to the agent, which
  no other guest process can read, and the agent runs as root. While the agent restarts, such
  a process can take the agent's port and receive nonces, but still cannot use one, because
  its dials are refused before they are read (see "Known gaps").
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
  installation, also for a cached image; a file that fails is deleted. A cancellation stops
  the check before its next 4 MiB read. A cancelled check has no result, so the installation
  stops without reading the image or booting the provisioning machine, and the file stays for
  the next check.
- A partial download is resumed only when the server's validator, its `ETag` or otherwise its
  `Last-Modified`, still matches (`If-Range`); the final SHA-256 check covers the joined file
  in any case.
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
- `/usr/bin/tar` and `/usr/bin/gzip` run with only their standard descriptors
  (`POSIX_SPAWN_CLOEXEC_DEFAULT`), so they cannot reach the daemon's connections or any other
  descriptor of the daemon. For an installation, tar's input is `/dev/null`; for an export's
  compression, a pipe from the daemon, and its output a pipe that the daemon copies to the
  client's descriptor. For an import, gzip's input is the client's descriptor, which the daemon
  closes as soon as gzip has started, and its output a pipe to the daemon.
- **An imported archive is input from outside maw, and no program on the Mac reads its
  format.** libarchive, behind `/usr/bin/tar`, reads every archive format it knows, mtree
  among them, and an mtree entry names a file on the disk whose contents libarchive reads: an
  archive could have made the daemon copy any file that the user can read into the new
  distribution. The import therefore passes the archive on the Mac only through
  `/usr/bin/gzip -dcf`, which decompresses gzip, bzip2, xz, compress, and lzip and passes
  anything else through unchanged, and forwards the result only if its first block is a tar
  header (`ustar` at offset 257, `ImportStream`); anything else fails with
  `importNotATarArchive`. `bsdtar` reads the archive in the provisioning machine, without `-P`,
  so absolute paths lose their leading `/`, `..` components and extraction through links are
  refused, and links and special files act only inside that machine and on the new disk. The
  machine has no access to the Mac's files and no other disk. A truncated or corrupt archive
  fails the import before anything is registered.
- **The import's checks and configuration resolve every path inside the new root.** The
  inspection and `ProvisioningScript` follow each link of a path as the imported system would:
  an absolute target starts again at the root, and `..` stops there. The configuration replaces
  a link where it writes a file instead of writing through it, and refuses a path whose links
  loop. So a link in the archive cannot make the configuration write outside the new root, not
  even into the provisioning machine's own files. The daemon reads at most 4 MiB of
  `/etc/passwd`, `/etc/maw.conf`, and `/etc/wsl.conf` each.
- **The import's configuration runs programs of the imported root file system**, through
  `chroot`: `dpkg-divert`, if the archive has it, to divert the message of the day. They run as
  root inside the provisioning machine, which has no access to the Mac's files and no other
  disk; during the configuration, at worst they damage the new distribution.
- **The import's first start, and every later start, boots the archive's programs with the
  share of the home directory mounted.** The import ends by starting the new distribution, so
  that its first session is warm; from then on, the archive's units, generators, and login
  scripts run as root or as its users, with read-write access to the owner's home directory
  through `/mnt/mac` (see "The share of the home directory"), before the owner has opened a
  session. Importing an archive is therefore running its programs on the Mac as the owner: an
  archive should be imported only if its source is trusted, as a program would be run only if
  its source is trusted. Decision record 0021 explains why the share is not withheld from the
  first start.
- **The default user that `/etc/maw.conf` or `/etc/wsl.conf` names is validated** with
  `UserName`'s rules and must be a user in the archive's `/etc/passwd`; otherwise it is ignored.
  It reaches the configuration script as an argument, never inside the script's text.

### The password

maw asks for the new account's password once per installation.

| Stage | How it travels |
|-------|----------------|
| `maw` | When standard input is a terminal, read with `readpassphrase(3)` (`RPP_ECHO_OFF`, `RPP_REQUIRE_TTY`) from the controlling terminal, `/dev/tty`, without echo, twice. With `--user` and standard input that is not a terminal, the first line of standard input. The buffer of `readpassphrase` is cleared after reading. |
| XPC to `mawd` | Inside the `install` request's JSON body, to the same-user peer that passed the checks above. The value is a `Secret`, whose descriptions print `<redacted>`. |
| `mawd` | In memory while the installation runs. It is never logged and is not part of any error message. |
| vsock to the provisioning machine | As the standard input of `chroot /mnt/root /usr/sbin/chpasswd`, never in an argument, the environment, or a script. |
| The guest | `chpasswd` stores its hash in `/etc/shadow`. |

The password never reaches standard output, standard error, or a log. `maw` writes its
questions, and the terminal echoes the account name as it is typed, on `/dev/tty`
(`Sources/maw/PromptTerminal.swift`), never on standard output or standard error, so none of
it reaches a pipe or a file that those go to, as in `maw --install 2>&1 | tee install.log`.
The password itself is never echoed, not even to the terminal, and it is not part of the
progress, the summary, or any error message. `mawd` never logs it, and in the provisioning
machine it reaches only `chpasswd`'s standard input, so the console log in
`~/Library/Logs/maw/install/` does not contain it either.

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
- `distro.json`, `state.json`, the image cache, and the logs contain no secrets. An imported
  distribution's `distro.json` and `mawd.log` record the path of the archive it came from. The console
  logs, the provisioning machines' in `~/Library/Logs/maw/install/` included, contain what the
  guest prints on its console: the kernel log, systemd's status messages, and the agent's log,
  which records commands' process IDs but not their arguments or input.
- An installation never writes into an existing entry of `distros/`. It refuses a name under
  which anything is left there, in any case, such as a directory with a disk image but no
  `distro.json` after a partial manual removal, and leaves that entry as it is. It builds the
  new distribution in its own staging directory, which it creates and removes without
  following symbolic links (docs/daemon.md).
- `maw --export` creates its file with `O_CREAT | O_EXCL` and mode 600, because the archive
  holds the password hashes in `/etc/shadow` and every user's files. It never replaces an
  existing file and never follows a symbolic link in its place, dangling or not. It creates the
  file only after the daemon has accepted the export. On a failure or a cancellation it removes
  the file only if the path still names the device and inode that it created, so that it never
  removes a file that replaced its own. A `maw` killed with SIGKILL leaves the partial file
  behind ([docs/known-limitations.md](known-limitations.md)).
- An export mounts the distribution's file system read-only and without replaying its journal
  (`ro,noload`); only the check before it, `e2fsck -p`, may repair it, as at every start. The
  provisioning machine has that disk only, and no access to the Mac's files.
- `maw --unregister` asks before it deletes, on a terminal, and the daemon removes a
  distribution by renaming its directory into its own staging directory first, so that a
  removal that stops halfway leaves no partly deleted distribution under its name; the daemon
  deletes the rest at its next start.
- A distribution whose root file system fails its check at boot is not changed further. The
  initramfs does not mount it, and the daemon neither deletes, reformats, nor writes to its
  disk image; only `e2fsck -p` may have repaired parts of it before it stopped
  (docs/daemon.md, "A root file system that fails its check").

### The guest's console

The daemon writes everything the guest prints on its console to the console log, and reads it
for one purpose: on a distribution's machine, until the initramfs's line
`maw-initramfs: starting systemd`, it looks for the exact line
`maw-initramfs: root-check e2fsck-status=<status>`, with a status of 0 to 255, and keeps the
last one. That status only selects the error message when the guest powers off before its
agent answers; the daemon takes no action on it. Until systemd starts, only the initramfs and
the kernel write to the console. A marker-like line in e2fsck's output, which can include
names from the file system, precedes the initramfs's own marker and is replaced by it; lines
after systemd starts are not read. A guest that forged the marker could at most change the
message of its own failed start.

## Known gaps

[docs/known-limitations.md](known-limitations.md) lists every deferred item, with its phase.

- The ad-hoc code signing requirement does not identify maw's builds; phase 13.
- Guest files come from CI artifacts rather than signed releases; phase 13.
- The password's copies in memory are not wiped (see above).
- **The agent's port while the agent restarts.**
  - **The window.** On a distribution's machine, systemd restarts the agent 100 ms after it
    exits (`Restart=always`, `RestartSec=100ms`, `Guest/initramfs/init`). Its vsock port, 19799
    (`AgentProtocol.vsockPort`), is above 1023, so in that window any guest process can bind
    it, without root. The daemon's connections to the agent then reach that process. The
    restarted agent cannot bind the port and exits, and after five failed starts within
    10 seconds, systemd's default start limit, it is not started again until the machine
    stops.
  - **What the daemon sends on those connections.** Each one begins with the protocol
    version and carries one request:
    - `info`, without a payload, which the daemon sends only while it waits for the agent at
      the machine's start;
    - `sample`, without a payload, while a client watches the distributions;
    - `shutdown`, without a payload;
    - `dialBack`, whose payload is the 32-byte nonce of a session that is opening.

    Commands, their arguments, environment, input and output travel only on connections that
    the agent dials, never on these.
  - **What such a process can learn:** the nonces, and when sessions open and when the
    machine is asked to stop.
  - **What it can fake:** the replies.
    - To `dialBack`:
      - a false `dialedBack` makes the session fail with `sessionDialBackMissing` once the
        nonce expires, after 5 seconds;
      - an error makes it fail at once with `sessionDialBackFailed`;
      - no reply makes it fail after the reply timeout of 10 seconds.
    - To `shutdown`, a false `shutdownAcknowledged` delays the stop by 5 seconds, and no reply
      by 10. Virtualization.framework's stop request then still powers the machine off
      cleanly (`VirtualMachine.stop`).
    - A false `agentInfo` could only matter during a start.
    - A false `sampled` shows false memory figures and a false address in that machine's row,
      as root in the guest can (see "Figures from the guest").
  - **What it can block:** every new session of that machine, until the machine stops.
  - **What it cannot do:** use a nonce. It cannot bind a source port below 1024, so the
    daemon refuses its dials before reading them, as above.
  - **What starts the window.** No way was found for a process without root to cause the
    restart; it can only wait for one that something else causes:
    - The agent accepts connections only from the host (`maw_vsock_accept_host`), and the
      kernel has no vsock loopback, so no guest process can send it anything.
    - It runs as root, so such a process cannot signal it.
    - `systemctl` needs root to stop or restart it.
    - The agent exits only when it cannot listen at start, or when `accept` fails for an
      unexpected reason (`AgentServer.acceptConnections`).
    - What remains is a crash of the agent, or the kernel's out-of-memory killer, which
      `OOMScoreAdjust=-900` makes pick the agent nearly last. Neither is known to be within
      such a process's reach.
  - **Mitigation, phase 12b.** One of two:
    - a systemd socket unit, written by `Guest/initramfs/init` beside the agent's service,
      that holds vsock port 19799 across restarts and hands the listening descriptor to the
      agent;
    - an agent port below 1024, which only a process with `CAP_NET_BIND_SERVICE` can bind,
      and which changes the protocol.
