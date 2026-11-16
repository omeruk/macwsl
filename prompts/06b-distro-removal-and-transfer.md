# Phase 06b: Distro removal and transfer

Read `CLAUDE.md`, `docs/decisions/`, `docs/daemon.md`, `docs/distributions.md`,
`docs/security.md`, and `docs/known-limitations.md` first. Work on branch
`phase/06b-distro-removal-and-transfer` from the latest `main`.

Phase 06a let a person list their distributions, choose the default, and stop one. This phase
completes distribution management with the three commands that phase 06a left: removing a
distribution, exporting it to an archive, and creating one from an archive. With them, a person
can back up a distribution, move it to another Mac, keep several copies of one, and remove one
without deleting files by hand.

Keep this phase small. Anything that is not needed for the three commands goes into a separate
`fix/` branch or into `docs/known-limitations.md`, not into this pull request. If the plan's
estimate exceeds 2,500 added lines outside `Tests/`, propose a split into two pull requests
before going on: A with `--unregister` and `--export`, B with `--import`. If the work exceeds
3,000 added lines outside `Tests/` in one pull request, stop and ask before going on.

## Goal

At the end of this phase, these commands work on the owner's Mac, with the signed build:

```sh
maw --unregister <name>                        # ask on a terminal, stop it, delete it
maw --unregister <name> --yes                  # the same without the question
maw --export <name> <file>                     # write its root file system to a tar archive
maw --export <name> ubuntu.tar.gz              # compressed, chosen by the file's extension
maw --export <name> <file> --format tar.xz     # or by --format: tar, tar.gz, or tar.xz
maw --export <name> -                          # the archive to standard output
maw --import <name> <file>                     # create a distribution from an archive
maw --import <name> <file> -u <user>           # with <user> as its default user
maw --import <name> -                          # the archive from standard input
```

`maw --export Ubuntu-24.04 - | maw --import Copy -` makes a copy of a distribution. The forms
follow `wsl.exe`, except that `--import` takes no install location, because the daemon owns
the distributions directory, and that `--format vhd` is not offered, because maw's disks are
not VHD files. Four additions have no `wsl.exe` counterpart, and each is a deliberate
decision of the owner: the question before `--unregister` and `--yes`, the format from the
file's extension, `-u` for `--import`, and the line that names a new default.

## Product requirements

### What each command does

- **`--unregister <name>`** stops the distribution's machine if it runs, in the way
  `--terminate` does, and then deletes its directory, with its disk image and `distro.json`, as
  one step that cannot leave half a distribution behind: the daemon first renames the directory
  into its staging directory and then deletes it there, and removes such leftovers when it
  starts, as it already does for an installation's staging directory.
- **The question.** When standard input is a terminal, `maw` asks on the terminal, through
  `PromptTerminal` as `--install` asks, before it sends the request: "Delete <name> and its
  disk for good? [y/N] ". It asks only after the daemon has resolved the name, so that a name
  that is not installed fails with `distributionNotInstalled` without a question, and the
  question shows the stored spelling. Only `y` or `yes`, in any case, goes on; anything else,
  an empty line, Ctrl-D, or Ctrl-C ends `maw` with nothing changed and a failure status.
  `--yes` skips the question. When standard input is not a terminal, as in
  a script, a pipe, or the integration tests, nothing is asked, as with `wsl.exe --unregister`.
  `--yes` is accepted only with `--unregister`. `maw --help` and `README.md` say plainly that
  the command deletes the disk.
- **The logs go with it.** After the machine has stopped, the daemon deletes the
  distribution's console log, `~/Library/Logs/maw/<name>.log`, its provisioning log,
  `install/<name>.log`, and the console log of its last export (see `--export`), so that
  a later distribution of the same name starts with logs of its own. `mawd.log` keeps the
  record of the removal: the name, the client's process ID, and the outcome. The reserved
  names (`Installer.reservedNames`) keep a removal from reaching `mawd.log` or another
  machine's log.
- **The default.** If the removed distribution is the one `state.json` names, the daemon clears
  that setting, so that the rule "otherwise the first installed one by name" applies and a
  later distribution of the same name does not become the default by accident. When the
  default distribution changes in this way to another installed one, the reply names it, and
  `maw` prints one line on standard error: "<new> is now the default distribution." When no
  distribution remains, or the default did not change, it prints nothing.
- **`--export <name> <file>`** writes the distribution's root file system to a tar archive,
  with owners, permissions, extended attributes (file capabilities among them), hard links,
  special files, and non-ASCII names kept, as the installation's extraction keeps them. The
  plan says whether POSIX ACLs survive with the guest's static `bsdtar` and the Mac's
  `/usr/bin/tar`, and the docs say what was found. The archive holds the root file system only,
  not `distro.json`, as `wsl.exe --export` does. The distribution's machine must not run:
  exporting a running distribution fails with an error that suggests `maw --terminate <name>`,
  so that the archive is consistent and no session is stopped without being asked.
- **The format.** `--format` chooses `tar`, `tar.gz`, or `tar.xz`. Without it, the file's
  extension chooses, ignoring case, as `tar -a` does: `.tar.gz` and `.tgz` give `tar.gz`,
  `.tar.xz` and `.txz` give `tar.xz`, and any other name, and `-`, give `tar`. A `--format`
  that is given always wins, even against the extension.
- **Before it reads the disk, the export runs the check that a start runs**
  (`Guest/initramfs/maw-check-root`, `e2fsck -p`) and fails as a start fails, with
  `rootFileSystemCheckFailed` (`docs/daemon.md`, "A root file system that fails its check"). It
  then mounts the disk read-only. A disk whose journal needs recovery, as after a forced stop,
  is thus written only as the next start would write it, and a disk that fails the check is not
  exported. The export's provisioning machine writes its console to a log of its own; it never
  replaces `~/Library/Logs/maw/install/<name>.log`, which `VirtualProvisioningMachine.boot`
  removes before it starts. The plan names that log.
- **`--import <name> <file>`** creates a distribution from an archive: a tar archive in any
  compression that `/usr/bin/tar` reads, such as one made by `maw --export`, `wsl.exe --export`,
  or a distribution's published root file system. It goes through the installation's steps
  that apply: the name check, a free space check, a new disk, formatting, extraction, the
  configuration that makes a root file system boot in maw, registration, and the first start.
  No user is created and no password is asked. As at installation, a distribution imported
  while none is installed becomes the default. If the first start fails, the distribution stays
  installed, as after an installation, but `maw --import` prints the start's error and exits
  with a failure status. Its suggestion first names the console log that explains the failure,
  and only then `maw --unregister <name>`, which deletes that log: a foreign root file system
  fails its first start more often than a catalog image.

### What `--import` configures

The imported root file system keeps its users, its files, and its locale. The daemon applies
only what a root file system needs to boot and work in maw. For an archive made by
`maw --export`, every step below finds its result already in place and changes nothing but the
host name, `/etc/machine-id`, and the MAC address:

- `/etc/hostname` and `/etc/hosts` from the new distribution's name
  (`Installer.hostname(for:)`), as at installation, so that two imports of one archive do not
  share a host name; an archive from WSL brings a generated `/etc/hosts` that this replaces;
- the files that `ProvisioningScript` owns, written as it writes them at installation, replacing
  what the archive has under those paths: `/etc/fstab`, `/etc/netplan/50-maw.yaml`, the
  `/etc/resolv.conf` link, the journal's size limit, and the masked units. The message-of-the-day
  diversion is added only if it is not in place yet. The plan lists anything else in an archive
  from WSL that would stop it from booting or reaching the network in maw (for example a
  `/etc/resolv.conf` that WSL generated, or `[boot] systemd` in `/etc/wsl.conf`), and what the
  import does about each;
- linger for the default user, as at installation, unless the default user is `root`, so that
  a login shell does not wait for the user manager;
- **`/etc/machine-id` emptied**, so that systemd generates a new one at the first boot.
  Otherwise two distributions imported from one archive would share the identity that
  systemd-networkd's DHCP client sends, and could receive the same address;
- a new MAC address in `distro.json`, as at installation;
- **the default user**: the user that `-u <user>` names, which must pass `UserName`'s rules and
  exist in the archive's `/etc/passwd`, or the import fails with `userNotFound` before
  registration; without `-u`, `[user] default` from the archive's `/etc/maw.conf` if it passes
  `UserName`'s rules and names a user in the archive's `/etc/passwd`; otherwise `[user] default`
  from `/etc/wsl.conf` under the same conditions; otherwise `root`, as `wsl.exe --import` does.
  The guest agent reads the default user from `/etc/maw.conf` and falls back to `root` only when
  the file names none (`SessionPlanner.account(for:system:)`), so the import writes the choice
  into `/etc/maw.conf`, keeping the file's other lines, whenever the file does not already name
  it; a `maw.conf` that names a missing user would otherwise make every session fail with
  `userNotFound`. `distro.json` records the same user. The command's last line names the user
  that sessions will run as; when that is `root` because nothing named another user, the line
  also suggests importing again with `-u <user>`.

Before the first start, the daemon checks that `/sbin/init` in the imported root file system
resolves to systemd, following links inside the imported root rather than the provisioning
machine's, and refuses a root file system whose init is not systemd with an error that names
the reason (CR-7 in `docs/known-limitations.md`). It also refuses an archive that
does not contain a root file system at its top level, for example one whose files are all under
a single directory, with an error that says what it found. Both refusals happen before
registration and remove everything the import created.

### Files, standard input, and standard output

- **The client opens the file, never the daemon.** `maw` opens `<file>` (or uses its standard
  input or output for `-`) and hands the open descriptor to the daemon over XPC, in the
  message's `descriptor` field, as the daemon hands a session's descriptor to clients
  (`Sources/MawXPC/InterfaceCoding.swift`). The daemon is a LaunchAgent
  without the user's privacy permissions: macOS refuses it, or asks the user on its behalf, for
  files in `~/Documents`, `~/Desktop`, `~/Downloads`, and removable volumes, which Terminal can
  already read. This also gives `-` its meaning without a second path.
- `--export` creates `<file>` with mode 600, because the archive holds `/etc/shadow` and every
  user's private files, refuses to replace an existing file, and removes the file it created
  when the export fails or is cancelled. `--export` to `-` when standard output is a terminal,
  and `--import` from `-` when standard input is a terminal, are refused before the daemon is
  asked.
- A reader that closes the pipe early, as `maw --export <name> - | head -c 1` does, ends the
  export as a failure with a clear message. The daemon gets `EPIPE`, never `SIGPIPE`, and keeps
  running.
- A slow reader or writer holds the provisioning machine back instead of making the daemon
  buffer: the plan states how back pressure reaches the guest in each direction, so that the
  memory target under "Speed targets" holds for a pipe as for a file.
- Progress goes to standard error, one line per step, redrawn in place only on a terminal, as
  `--install` reports it, so that `-` keeps standard output for the archive alone.

### Concurrency and cancellation

- While a distribution is being exported, a session on it, `--unregister`, and a second
  `--export` of it fail with an error that names the operation in progress, instead of waiting
  or starting its machine; `--terminate` and `--set-default` of it work as for any stopped
  distribution. While a distribution is being removed, every request that names it fails in the
  same way until the removal is done. The list keeps showing an exported distribution as
  `Stopped`; a new state for these operations is out of scope.
- An import reserves its name as an installation does: an installation or a second import of
  the same name fails while it runs, in any case of the letters. `installationInProgress` then
  names what holds the name; its message says "by another maw --install" today.
- Ctrl-C, the client's exit, or the daemon's stop ends an export or an import at once: the
  provisioning machine is stopped, the import's staging directory is removed, and the export's
  file is removed as above. `--unregister` is not interrupted once the rename has happened. The
  plan states what `--shutdown` does to an export or an import in progress, following what it
  does to an installation.
- A full volume fails the export or the import with `insufficientDiskSpace` or a clear write
  error, and leaves nothing behind. `--import` checks the free space before it starts, as
  `--install` does; the plan states the rule it uses for an archive whose uncompressed size is
  unknown.

### Speed targets

Measure through the test daemon, on test distributions that the measurement installs from the
cached Ubuntu 24.04 image and removes afterwards, never on the owner's distributions. Record
the median and the slowest of 5 runs in the pull request, with the date, the commit, and the
load average, as development measurements. The owner then runs the same measurements under the
owner's rule: a restarted Mac on AC power, Low Power Mode off, `caffeinate -dims`, only
Terminal open, and a one-minute load average under 2 before the start. Provide one command for
that run, and tag the measurements so that the integration tests can run without them. If a
target is missed, report the number, where the time goes, and what would close the gap.

| Measurement | Target |
|-------------|--------|
| `--unregister` of a stopped distribution, to maw's exit | under 1 s |
| `--unregister` of a running, idle distribution, to maw's exit | under 2 s |
| `--export` of a freshly installed test distribution to an uncompressed tar file | under 30 s; report MB/s |
| `--import` of that archive, to the end of the first start | under 30 s; report MB/s |
| The daemon's footprint during an export and an import of that archive, also through a pipe | grows by under 64 MiB |
| `--export --format tar.gz` and `--format tar.xz` of the same distribution | report only |

### Experience rules

- **Names** follow phase 06a: matched without regard to case against the installed
  distributions, with the stored spelling recorded and printed; catalog aliases are not
  installed names. `--import`'s new name follows the installation's naming rules.
- **Success is quiet** for `--unregister`, apart from the question and the line that names a
  new default. `--export` and `--import` print their progress lines
  and, at the end, one line that names the result: the archive's size, or the new
  distribution and its default user.
- **Errors explain and suggest.** Every new failure is a `MawError` case with a message and a
  suggested fix that names only commands that work in this build, and every printed line fits
  in 80 columns, `maw: ` included, for a name of 12 characters.
- **Sessions on an unregistered distribution** end with the existing `machineStopped` error,
  with a reason that names `maw --unregister`, and a terminal session restores the terminal
  first, as `--terminate` does.
- **The terminal app follows**, through the requests it already uses: a removed distribution
  leaves the distributions screen, the new-tab menu, and the command palette, and its open tabs
  end with the message above; an imported one appears. The daemon publishes a new snapshot
  for a removal and for an import, which also resolves "A watcher does not notice a distribution
  removed by hand" for removals through maw. The app gets no new actions in this phase.

## Architecture

### Reuse

- The provisioning machine (`VirtualProvisioningMachine`) does the Linux side of all three
  operations that touch a root file system: for `--export`, it mounts the distribution's disk
  read-only and runs `bsdtar -c` with the options that keep what extraction keeps, whose
  standard output reaches the daemon through the existing `exec` stream; for `--import`, it
  formats and extracts as an installation does, with `/usr/bin/tar` on the Mac re-encoding the
  archive from the client's descriptor. Compression for `--export` happens on the Mac, with
  `/usr/bin/tar`, as decompression does at installation. No new guest agent request is
  expected; if the plan finds that one is needed, it says why.
- The import's configuration extends `ProvisioningScript` with a mode that writes only the
  system part and leaves users alone, rather than a second script.
- `distro.json` records where an imported distribution came from instead of a catalog entry and
  an image SHA-256. Changing `DistroMetadata` increments its schema version and keeps reading
  version 1 files. The daemon never rewrites an existing version 1 file, so that `main`'s build
  keeps reading `Ubuntu-24.04` after the owner returns to it. The plan states what an earlier
  build does with an imported distribution's version 2 file (`DistributionStore.installed()`
  skips unreadable entries today), and the return-to-`main` procedure says so.

### Daemon interface

- New requests for unregister, export, and import, with the descriptor in the request, and
  progress events as `--install` sends them. This changes the daemon interface: increment
  `DaemonInterface.version` and update `docs/daemon.md`.
- The peer checks of `docs/security.md` apply unchanged. Add to "The daemon's XPC service" that
  a client can now delete a distribution and read and write its whole root file system through a
  descriptor it supplies: what any process of the same user can already do to the files in
  `distros/`, so the same-user check stays the boundary.

### Security

An imported archive is input from outside maw. Record in `docs/security.md`:

- the archive is never extracted on the Mac: `/usr/bin/tar` re-encodes it as a stream, and
  `bsdtar` extracts it inside the provisioning machine, so path traversal, links, and special
  files in it act only inside that machine and on the new disk;
- "The extraction" says that `/usr/bin/tar` runs with only its standard descriptors and
  `/dev/null` as input. For `--import` its input is the client's descriptor; update the
  bullet, and keep every other descriptor of the daemon out of `/usr/bin/tar`;
- the import's configuration runs programs of the imported root file system (`chroot` commands
  such as `getent` and `dpkg-divert`) inside the provisioning machine, which has no access to
  the Mac's files and no other disk;
- the default user from `/etc/wsl.conf` or `/etc/maw.conf` is validated with `UserName`'s rules
  before it is used.

### Guest files

The phase is expected to change paths that the Guest workflow watches, at least
`Sources/MawCore/` for the new errors and the metadata. Follow `README.md`, "After a change of
the guest protocol or the daemon interface", and the rules for the shared working tree in
`prompts/11c-distribution-figures.md`, "Installing the builds": open the pull request as a
draft as soon as those paths have changed, so that the Guest workflow builds the guest files,
tell the owner before the first build that changes the protocol or the interface, and give
the owner the exact procedure to install this branch's build and to return to `main`.

## Messages that waited for this phase

- `Action.phase` and the `notImplemented` messages: the three commands are implemented. Remove
  what no action uses any more, and say in the plan what stays and why.
- `maw --help`: the `--export` example names an installed distribution, not the alias
  `Ubuntu`; `--import`'s help no longer says the archive must come from `--export`.
- The suggestion of `distributionAlreadyInstalled` ("The README explains how to remove a
  distribution.") names `maw --unregister <name>`. `distributionDirectoryExists` keeps its
  rule that maw never changes a directory without `distro.json`: `--unregister` removes only
  installed distributions.
- `docs/distributions.md`, "Removing a distribution by hand", and `README.md`, "Removing a
  distribution": replaced by `--unregister`, with export and import described.

Search for `06b` in `Sources/`, `docs/`, `App/`, and `README.md`, and list each match in the
plan with what you will do with it.

## Tests

Follow decision record 0018 for the test groups: latency assertions in `Latency` suites, load
generators in `Load`.

**Unit tests, run in CI:**
- Argument parsing: each form, `--format` only with `--export` and only its three values, `-`
  for each, `--yes` only with `--unregister`, `-u` with `--import`, the conflicts with other
  actions and with `-d`, and missing operands.
- The format from the extension: each extension in both cases, a name without one, `-`, and
  `--format` against a contrary extension.
- The question before `--unregister`: asked only when standard input is a terminal and
  `--yes` is absent, and each answer, with nothing sent to the daemon unless the answer is yes.
  The terminal is a fake, as in `--install`'s tests.
- The new requests and replies: their encoding through `InterfaceCoding`, with the descriptor
  in the `descriptor` field, and the interface version.
- The daemon's handling against a fake store, registry, and provisioning machine: unregister of
  a running, a stopped, and the default distribution; a removal left half done by a crash and
  cleaned at the next start; an export of a running distribution refused; every refusal under
  "Concurrency and cancellation"; cancellation at each step removing what it created.
- The default user's choice from `/etc/maw.conf`, `/etc/wsl.conf`, and neither, including a
  name that fails `UserName`'s rules, a user that does not exist in the archive, and a
  `maw.conf` with other lines that the rewrite keeps.
- The import's configuration script on its own, as `ProvisioningScript`'s tests check it: the
  arguments are validated, and the system-only mode creates no user.
- `DistroMetadata` reading schema 1 and writing schema 2.
- Every new message at 80 columns with the `maw: ` prefix.

**Integration tests** (`.integration`, through `scripts/integration-test.sh`), on test
distributions from the cached image. The test daemon shares the owner's `distros/` directory
and `state.json`, so a wrong name in an `--unregister` test would delete the owner's
distribution. Every test therefore removes only names it created in that run, with a prefix
that no owner's distribution has, and the helper that unregisters refuses any other name. The
plan shows that helper. During development the session never runs `--unregister` against a
name it did not create, through any daemon.
- `--unregister` of a stopped and of a running distribution, with a session open on the running
  one ending with `machineStopped` naming `maw --unregister`, and of the default, with the
  line that names the new default; afterwards neither of the distribution's logs exists, and
  `mawd.log` records the removal.
- `--import -u <user>` with a user in the archive, and with one that is not: the second fails
  with nothing left behind.
- An export and an import under a new name, after which the new distribution boots, keeps
  owners, permissions, extended attributes, hard links, and a file with a non-ASCII name,
  keeps the default user, has its own host name, MAC address, and `/etc/machine-id`, and gets
  its own address when both run.
- `maw --export <name> - | maw --import <copy> -`.
- Each `--format`, read back by `--import`.
- An archive whose `/sbin/init` is not systemd, an archive with its root under one directory,
  and a truncated archive: each refused, with nothing left behind.
- An archive with only `/etc/wsl.conf` naming its default user, and none at all: sessions run
  as that user, and as `root`.
- `--export` to `-` read by a pipe that closes early: the export fails, nothing is left, and
  the daemon keeps serving.
- Ctrl-C during an export and during an import: nothing left behind.
- The measurements under "Speed targets", tagged as described there.
- Every test removes the distributions and files it created and protects the owner's
  `state.json`, as earlier phases' tests do.

## Docs

- `docs/daemon.md`: the new requests, the interface version, the removal sequence, and the
  provisioning machine's export and import.
- `docs/security.md`: as described under "Daemon interface" and "Security".
- `docs/distributions.md`: removing, exporting, and importing, the import's configuration, and
  the files on the Mac.
- `README.md`: the three commands.
- `docs/known-limitations.md`: remove the first three phase 06b items. The fourth, "A watcher
  does not notice a distribution removed by hand", stays true for a removal by hand: reword it
  so that `--unregister` is the supported way and a removal by hand remains the case it
  describes, and move it to the phase that owns it, or to "None yet". Add what this phase
  defers.
- `docs/ROADMAP.md`: mark 06b as done.

## Out of scope

- Removing, exporting, importing, or installing from the terminal app.
- `--format vhd`, `--vhd`, and importing a disk image.
- A distribution state such as "Exporting" in the list and on the distributions screen.
- Exporting a running distribution from a snapshot.
- Regenerating the host keys of an SSH server in an imported distribution.
- A command that repairs a distribution whose root file system failed its check.

## Acceptance criteria

- The root package: `swift build -Xswiftc -warnings-as-errors`; `swift build --build-tests
  -Xswiftc -warnings-as-errors`, then `scripts/test-groups.sh all .build/test-results`;
  `swift format lint --strict --recursive Sources Tests Package.swift`.
- `App/MawTerminalKit` builds and its tests pass, as CI's "Terminal app" job runs them.
- After every build or test command, `./scripts/sign-dev.sh`, so that the installed daemon
  stays signed.
- CI and the Guest workflow are green.
- `scripts/integration-test.sh` passes, and the pull request records the development
  measurements and the owner's official run under "Speed targets".
- The owner confirms, with this branch's build installed, using the signed `maw` by its full
  path (it is not on the owner's `PATH`):
  - while `Ubuntu-24.04` runs, `maw --export Ubuntu-24.04 ~/Desktop/ubuntu.tar` fails with a
    message that suggests `maw --terminate Ubuntu-24.04`, and creates no file;
  - after `maw --terminate Ubuntu-24.04`, the same command works without a privacy prompt that
    names `mawd`, and `ls -l` shows a file of mode 600;
  - `maw --import Copy ~/Desktop/ubuntu.tar` creates `Copy`, whose shell opens as the owner's
    user with the owner's files, and `hostname` prints `copy`;
  - `maw --unregister Copy` asks its question, and the answer `n` leaves `Copy` as it was;
  - with a shell open on `Copy` in another window, and on the distributions screen of the
    app, `maw --unregister Copy` answered with `y` ends the shell with a clear message and a
    working terminal, `Copy` leaves the screen, and `~/Library/Logs/maw/Copy.log` is gone;
  - `Ubuntu-24.04` is unchanged throughout: its shell, files, and default status;
  - the owner deletes `~/Desktop/ubuntu.tar` at the end; the session gives the command.

## How to work

1. Present a short plan first. It must cover:
   - the new requests and replies, the descriptor passing, and the interface version;
   - the removal sequence, and the cleanup of a removal left half done;
   - the export and import pipelines, end to end, with where each byte is compressed,
     decompressed, and written, how back pressure works in each direction, and what was found
     about POSIX ACLs;
   - the export's check of the disk, its read-only mount, and the name of its console log;
   - the import's configuration, what an archive from WSL needs beyond it, the default user,
     and the checks before registration;
   - the free space rule for `--import`;
   - every refusal and cancellation path, `--shutdown` and a closed pipe among them;
   - the metadata's new schema, and what `main`'s build does with it;
   - the integration tests' helper that refuses to unregister a name they did not create;
   - every `06b` reference and what happens to it;
   - an estimate of the added lines outside `Tests/`, and whether it splits into two pull
     requests.

   Wait for approval.
2. Push early as a draft pull request, as "Guest files" requires.
3. Ask the owner to install the branch's build and to run the interactive checks and the
   official measurements. You cannot type on their keyboard or see their screen.
4. Finish with the pull request, as described in the Workflow section of `CLAUDE.md`.
