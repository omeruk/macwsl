# Phase 09: Interop

Read `CLAUDE.md`, `docs/decisions/` (0013, 0015, 0017, 0021, 0022, 0023, and 0024 above all),
`docs/daemon.md`, `docs/protocol.md`, `docs/distributions.md`, `docs/security.md`, and
`docs/known-limitations.md` first.

WSL lets a Linux process run a Windows program (`notepad.exe`, `clip.exe`, `explorer.exe .`),
with its output in the Linux terminal, and so reach the Windows clipboard and open files and
URLs in Windows applications. maw has nothing of the kind: a process in a distribution can read
and write the owner's home directory through `/mnt/mac` (decision record 0021), but it cannot
start a program on the Mac, cannot reach the Mac's clipboard, and `xdg-open` in a distribution
opens nothing. This phase adds all three.

A guest that can run programs on the Mac crosses the main trust boundary of maw
(`docs/security.md`, "Trust model"). Security is therefore the centre of this phase: every
requirement below is subordinate to "Security", and a measurement that shows a requirement
cannot be met safely stops the work until the owner has decided.

The phase is delivered in two pull requests, in this order, each from the latest `main`:

- **A, Mac commands**, on branch `phase/09-mac-commands`: a process in a distribution runs a
  program on the Mac, through the launcher `mac <command>` or as a Mach-O executable under
  `/mnt/mac` (decision 5), with its standard input, output, and error, its terminal, its
  signals, and its exit status; the switch on the Mac of decision 2; and the security model of
  this phase, in decision record 0025 and `docs/security.md`.
- **B, clipboard and `open`**, on branch `phase/09-clipboard-open`, after A is merged: the
  Mac's clipboard from Linux, as plain text through `pbcopy` and `pbpaste` on the guest's PATH
  (decisions 5 and 12), and `xdg-open`, and the programs that call it, opening files and URLs on
  the Mac within the limits of decision 13.

Keep each pull request small. Anything not needed for this phase goes into a separate `fix/`
branch or into `docs/known-limitations.md`. If a plan's estimate exceeds 2,000 added lines
outside `Tests/`, say so in the plan; if the work exceeds 3,000 added lines outside `Tests/` in
one pull request, stop and ask before going on.

## The owner's decisions

These are decided. Do not reopen them in the plan; if a measurement shows that one cannot hold,
stop and report it with the numbers.

1. **On by default.** Interop is on for every distribution, installed or imported, with no
   action of the owner's, as in WSL.
2. **A switch on the Mac, per distribution.** This phase adds a switch per distribution on the
   Mac: stored in `distro.json`, set through `maw` with a flag that the plan proposes, and shown
   by `maw --list --verbose`. This changes the daemon interface. Phase 12 adds the global
   default in `.mawconfig` and the guest-side preference `[interop] enabled` in `/etc/maw.conf`.
   A switch inside the distribution is not a boundary, because guest root can change it; only
   the switch on the Mac holds against guest root.
3. **Only guest root and the default user may ask.** Only processes of guest root and of the
   distribution's default user may ask, checked by the caller's user ID (`SO_PEERCRED`, or the
   means that Part 1 chooses). Processes in containers or in other user namespaces are refused.
   If Part 1 shows that they cannot be told apart from the distribution's own processes, stop
   and report.
4. **Any Mac program.** A request may start any program on the Mac that the owner can run.
5. **How a Mac program is named in Linux.** In A: a launcher, `mac <command>`, and Mach-O
   executables under `/mnt/mac`, run directly through a `binfmt_misc` entry whose name begins
   with `maw-`. In B: `pbcopy` and `pbpaste` on the guest's PATH. There is no share of the Mac's
   system directories, and the Mac's PATH is not appended to the guest's. Part 1 checks that no
   Ubuntu package or command in the image is named `mac`; if one is, stop and report.
6. **`mawd` starts every Mac program.**
7. **The Mac program's user and environment.** The user is always the owner, the daemon's user;
   no request changes it. The environment is fixed: `HOME`, `USER`, `LOGNAME`, `SHELL`,
   `TMPDIR`, and `LANG` from the daemon's environment, and
   `PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`;
   `TERM` from the guest only when the Mac program gets a pseudo-terminal. The owner's login
   shell environment is never read. Variables that the guest names in `MAWENV` are passed on
   unchanged, without path translation (out of scope), within the limits, and never replace a
   variable of the fixed set.
8. **The working directory.** A guest directory under `/mnt/mac` becomes the Mac path that it
   shares. A guest directory outside `/mnt/mac` becomes the Mac home directory, with a one-line
   notice on standard error.
9. **Path arguments.** Arguments reach the Mac program unchanged; `mawpath -m` translates a path
   by hand. Only `open` (B) translates its own argument.
10. **A locked, switched-out, or sleeping Mac.** While the owner's session is locked or is not
    on the console (fast user switching), clipboard and `open` requests are refused, and
    commands still run. If Part 1 shows that the lock cannot be detected reliably, stop and
    report. Sleep belongs to phase 12; decision record 0025 and `docs/known-limitations.md`
    record what a request sees until then.
11. **Logging.** `mawd.log` records one line per Mac program, rate-limited: the executable's
    name only (never its full path), the guest user ID, the process ID, the duration, and the
    exit status. Arguments, environment, working directory, input, output, clipboard text, and
    URLs are never logged.
12. **The clipboard.** Plain text only; reading and writing are both allowed; at most 16 MiB.
    When the clipboard's item is marked `org.nspasteboard.ConcealedType` or
    `org.nspasteboard.TransientType`, as password managers mark theirs, `pbpaste` prints
    nothing, writes one line on standard error, and exits with status 1; `docs/security.md` says
    so.
13. **`open` and `xdg-open`.** Only `http`, `https`, and `mailto` URLs, and files and folders
    under the shared home directory. The Mac side resolves the real path, symbolic links
    included, from its own home directory before it checks, and refuses anything that resolves
    outside it. Refused, whatever the extension says: files with an execute bit or a Mach-O
    header; bundles (`.app`, `.workflow`, `.action`, `.prefPane`, and other packages);
    `.command`, `.tool`, and `.terminal` files; installer packages (`.pkg`, `.mpkg`) and disk
    images (`.dmg`); `.webloc`, `.inetloc`, and `.fileloc` files; and every other URL scheme. The
    plan lists the refused types as UTTypes.
14. **Delivery.** The two pull requests A and B, and decision records 0025 and 0026, as
    described in this file.

## Part 1 (pull request A, before the plan): what the platform does

Before you write the plan, measure on the owner's Mac what the plan depends on, with a
throwaway build on a branch of its own (`spike/09-interop`, never pushed, deleted afterwards).
Run it as temporary `.integration` tests through `scripts/integration-test.sh --filter <suite>`,
which installs the test daemon under its own label, on a test distribution that the run
installs from the cached image and removes afterwards; never commit those tests.
`scripts/integration-test.sh` builds the working tree, so the binaries under `.build` are the
spike's while it runs: when Part 1 is reported, switch back to `main`, build, and run
`./scripts/sign-dev.sh`, so that the owner's daemon finds `main`'s binaries again, and say so in
the report.

Every Mac program that Part 1 starts is `/usr/bin/true`, `/bin/echo`, `/bin/cat`, `/usr/bin/env`,
`/bin/pwd`, `/bin/sleep`, `/usr/bin/sw_vers`, `/usr/bin/pbcopy`, `/usr/bin/pbpaste`,
`/usr/bin/open`, or a copy of one of them in the run's own directory; nothing contacts the
network, the local network included (the owner's Local Network permission for `mawd` stays off).

Find out and report, with the commands and their output:

- **The name `mac`.** That no package in the image and no command on a default user's PATH, in
  a test distribution, is named `mac` (`dpkg -S`, `apt-file` if the image has it, `command -v`,
  and `compgen -c`). If one is, stop and report (decision 5).
- **`binfmt_misc` in a distribution today.** What `/proc/sys/fs/binfmt_misc` holds on a test
  distribution after boot; whether `systemd-binfmt.service` runs and what it reports, and
  whether the image carries files in `/usr/lib/binfmt.d` (such as WSL's `WSLInterop.conf`) and
  what they do under maw. Whether an entry that the agent registers survives `systemctl restart
  systemd-binfmt` and `systemctl stop systemd-binfmt` (whose `--unregister` removes every entry,
  according to systemd-binfmt.service(8)), and whether a runtime file under `/run/binfmt.d`,
  written by the initramfs, is applied at every boot and after such a restart.
- **Recognizing Mach-O files.** A `binfmt_misc` entry for thin arm64 Mach-O executables
  (`MH_MAGIC_64`, `0xfeedfacf`, little-endian, followed by `CPU_TYPE_ARM64`, `0x0100000c`) and for
  universal ones (`FAT_MAGIC`, `0xcafebabe`, big-endian). `0xcafebabe` is also the magic of a Java
  class file: show that the entry's mask tells the two apart (a universal file's next four bytes
  are a small architecture count; a class file's are its version, 45 or above) with a real class
  file and a copy of a universal Mac program. Whether a Mach-O file under `/mnt/mac` keeps its
  execute bit and runs through the entry, what the interpreter receives as its arguments with the
  `P` flag and with `F`, how long the kernel takes from `execve` to the interpreter, and what a
  Mach-O file outside `/mnt/mac` (copied into the guest's `/tmp`) does.
- **Reaching the agent from a guest process.** How a process that a user in the guest starts
  reaches the agent: a Unix socket under `/run/maw` with `SO_PEERCRED`, or another way. Show what
  the agent learns of the caller: its user ID, and whether it runs in a container or in another
  user namespace, for a process in a Docker container and for one in another user namespace, as
  root there and not (decision 3). If such processes cannot be told apart from the
  distribution's own, stop and report.
- **Starting a Mac program from the daemon.** The environment that the test daemon, a
  LaunchAgent, has (launchd's `PATH`, `TMPDIR`, `LANG`, `HOME`, and anything else), and so the
  values of decision 7's fixed set; the time from the daemon's request to the exit of
  `/usr/bin/true` started with `posix_spawn`, median and slowest of 20; whether a Mac program
  that the daemon started outlives the daemon and the machine; and a pseudo-terminal on the Mac
  for a Mac program, with its window size.
- **Carrying the bytes.** Whether a connection that the agent dials can be given to the Mac
  program as its standard input or output directly, with no copy in the daemon, and what the Mac
  program then sees (a socket, not a pipe: `isatty`, `fstat`, `SIGPIPE`, half-close). The
  throughput of 1 GiB through `/bin/cat` on the Mac, from guest to guest, directly and through a
  copy in the daemon, median and slowest of 5, against `maw -e cat` (decision record 0017,
  "Consequences").
- **Privacy questions (TCC).** Which process macOS names when a Mac program that the daemon
  started reads a protected folder (`~/Documents`), and whether the owner's earlier answer for
  `mawd` applies to it. The owner must be at the Mac for this run: tell the owner before it
  starts, and ask afterwards what appeared. Never answer such a question on the owner's behalf,
  and send no Apple event (`osascript`) without the owner's consent for that run.
- **The clipboard from the daemon.** Whether `NSPasteboard` in the daemon, and `/usr/bin/pbcopy`
  and `/usr/bin/pbpaste` started by the daemon, read and write the owner's clipboard; whether
  each can see an item's types, `org.nspasteboard.ConcealedType` and
  `org.nspasteboard.TransientType` included (decision 12); whether macOS 27.0.1 shows a privacy
  alert for a programmatic read (Apple announced one for macOS's general pasteboard in 2025), and
  what `NSPasteboard.accessBehavior` reports; the time to write and read 1 KiB and 16 MiB of
  text, median and slowest of 5; and what each path does with text that is not valid UTF-8. Time
  it on a pasteboard of a unique name (`NSPasteboard(name:)`), never on the owner's general
  pasteboard. Touch the general pasteboard only for the privacy alert, with the owner's consent,
  at a time the owner chooses, after telling the owner that its content will be replaced.
- **Opening a URL from the daemon.** `/usr/bin/open` against `NSWorkspace.open` from the daemon,
  for one `https` URL that the owner agrees to: the time from the request to the call's return,
  which application comes to the front, and whether it opens while the screen is locked. Never
  open a file, an application, or another scheme on the owner's Mac in Part 1. Report from
  `open(1)` and Launch Services' documentation, without running them, what `open` does with an
  application bundle, a `.command` or `.terminal` file, and a URL of a custom scheme.
- **The owner's session.** What the daemon can learn, and how fast, about whether the owner's
  session is locked, is on the console, or is going to sleep: `CGSessionCopyCurrentDictionary`
  (`kCGSessionOnConsoleKey`, which Apple documents, and the screen lock key, which it does not),
  and the notifications for lock, session switch, and sleep. The owner locks and unlocks the
  screen for this run; tell the owner when. Fast user switching only if the owner already has a
  second account and agrees; never create one. If the lock cannot be detected reliably, stop and
  report (decision 10).
- **What the guest has for `open`.** On a test distribution: whether `xdg-utils` and `wslu` are
  installed, what `xdg-open https://example.com` does today, what `update-alternatives --display
  x-www-browser` and `www-browser` give, and what Python's `webbrowser`, `gh auth login --web`, and
  `git` credential helpers call (`BROWSER`, `xdg-open`, or an alternative).

Put the results in the plan and, in short, in decision record 0025 (see "Docs"). If a result
makes one of the owner's decisions impossible or unsafe, stop and report before planning.

## Product requirements

### Mac commands (A)

- **Starting.** A process in a distribution starts a Mac program through `mac <command>` or by
  executing a Mach-O file under `/mnt/mac` (decision 5), within the bounds of decisions 1 to 4. A
  request that interop does not allow (the distribution switched off, a guest user other than
  root and the default user, a process in a container or another user namespace) fails at once,
  with exit status 126 and one line on standard error that names the reason and the fix; it
  never waits and never falls back to anything.
- **Standard input, output, and error** reach the Mac program and come back in order, with
  half-close carried: `echo hi | mac cat` prints `hi` and ends, and `mac cat < /dev/null` ends
  at once. Output the guest does not read blocks the Mac program only, never the daemon, the
  machine's other connections, or new sessions (decision record 0017).
- **The terminal.** When the guest process's standard input, output, or error is a terminal, the
  plan says which of them the Mac program gets as a pseudo-terminal on the Mac and why, so that an
  interactive Mac program (`/usr/bin/top`, `/usr/bin/vim`) works; window size changes follow.
- **Signals.** Ctrl-C, Ctrl-Z, and the other signals that the guest process receives reach the
  Mac program by name, as `docs/protocol.md` already names them. The exit status is the Mac
  program's code, or 128 plus the Linux number of the signal that ended it, so that a Linux
  shell's `$?` reads as it would for a Linux program.
- **User, environment, and working directory**, as decisions 7 and 8 set them. A guest working
  directory under `/mnt/mac` is translated on the Mac side from the daemon's own home directory,
  never from a Mac path that the guest supplies.
- **Arguments** reach the Mac program unchanged (decision 9), as an argument vector to
  `posix_spawn`; no shell on the Mac interprets them unless the program itself is a shell.
- **The end.** When the guest process ends, its Mac program receives SIGHUP, and SIGKILL 2 seconds
  later if it still runs, as the agent treats a session whose host closes
  (`docs/protocol.md`, "Exec sessions"). When the machine stops, however it stops, every Mac
  program of that distribution ends in the same way. No Mac program outlives its distribution's
  machine or the daemon.
- **Errors.** A program that does not exist, is not executable, or is refused by macOS reports
  the Mac's reason on standard error with exit status 127 or 126, as a Linux shell would. The
  daemon unreachable, the machine stopping, and a refusal by decision 3 each have a message of
  their own. No raw Swift error reaches the guest.
- **The switch** of decision 2: a `maw` flag that the plan proposes sets it per distribution, it
  is stored in `distro.json`, and `maw --list --verbose` shows it. A change takes effect within
  1 second, without a restart of the machine. The daemon interface changes: increment
  `DaemonInterface.version`, update `docs/daemon.md`.
- **Limits.** The daemon caps the Mac programs running per distribution, the request rate, the
  size of the argument vector and of the environment, the variables that `MAWENV` names, and the
  bytes it buffers per stream; the plan names the limits and what the guest sees beyond them.

### The clipboard (B)

- **Writing.** Text written to `pbcopy` on the guest's PATH replaces the Mac's clipboard as one
  item of type `public.utf8-plain-text`, so that Cmd-V in a Mac application pastes it unchanged,
  line endings included.
- **Reading.** `pbpaste` on the guest's PATH prints the Mac's clipboard as text, and prints
  nothing, with status 0, when the clipboard holds no text.
- **Concealed and transient items.** When the clipboard's item is marked
  `org.nspasteboard.ConcealedType` or `org.nspasteboard.TransientType`, `pbpaste` prints nothing,
  writes one line on standard error, and exits with status 1 (decision 12).
- **Text that is not UTF-8**, from either side, is handled as the plan says from Part 1's
  results, never silently cut.
- **Sizes** beyond 16 MiB fail with a message; nothing is cut.
- The terminal app's OSC 52 handling (`PaneController.clipboardCopy`) stays as it is.

### `open` (B)

- **`xdg-open`** in a distribution, and the programs that open a browser through `BROWSER`,
  `xdg-open`, or `x-www-browser`, open a URL or a file under `/mnt/mac` on the Mac, within the
  limits of decision 13. The plan says from Part 1's results how the guest is pointed at maw's
  opener at every boot without writing the distribution's `/etc` or `/usr`, as `mawpath` is
  linked under `/usr/local/bin` (decision record 0022).
- **A file under `/mnt/mac`** is translated to its Mac path on the Mac side, and its real path,
  symbolic links included, is resolved from the daemon's own home directory before it is
  checked. A file elsewhere in the guest, or one whose real path lies outside the home
  directory, cannot be opened on the Mac, and the message says so.
- **What is refused** by decision 13 or decision 10 is refused with a message, never opened in
  another way.

## Speed targets

Measure through the test daemon on test distributions that the measurement installs from the
cached image and removes afterwards. Record the median and the slowest of 5 runs in each pull
request, with the date, the commit, and the load average, as development measurements. The
owner then runs the same measurements under the owner's rule: a restarted Mac on AC power, the
lid open, Low Power Mode off, `caffeinate -dims`, only Terminal open, and a one-minute load
average under 2 before the start. Provide one command for that run, a script under `scripts/`
that runs the measurements through `scripts/integration-test.sh` as `scripts/measure-dns.sh`
does, and tag the measurements so that the integration tests can run without them. If a target
is missed, report the number, where the time goes, and what would close the gap.

| Measurement | Target | PR |
|-------------|--------|----|
| A warm `mac /usr/bin/true` from a guest shell, to its exit status in the guest | under 30 ms | A |
| A copy of `/usr/bin/true` under `/mnt/mac`, run through the `binfmt_misc` entry | report, against `mac` | A |
| Throughput of 1 GiB through a Mac `/bin/cat`, guest to guest | report MB/s, against `maw -e cat` | A |
| The agent's CPU time per minute on an idle machine, with interop on | report, against `main` | A |
| Cold start to a prompt, against `main` | adds under 20 ms to the median | A, B |
| `pbcopy` of 1 KiB from the guest, to the text on the Mac's clipboard | under 50 ms | B |
| `pbpaste` of 1 MiB in the guest | under 100 ms | B |
| `xdg-open https://…` in the guest, to the Mac's open call returning | under 200 ms | B |

## Architecture

- **The request's path.** A guest process reaches the agent (Part 1 chooses how), the agent
  passes the request to the daemon, and `mawd` starts the Mac program (decision 6). The plan says
  how the request travels: an interop channel that the daemon opens through the dial-back, as
  the forwarding and DNS channels are (decision records 0023 and 0024), with one connection per
  stream that the agent dials with a nonce that the daemon registered, or another way. Every
  connection that carries a Mac program's bytes is one that the agent dials, never one that the
  daemon opens (decision record 0017). A new vsock port, if any, gets a `DialBackGate` of its own
  with budgets of its own.
- **Bytes through the daemon.** The plan says whether the Mac program's standard streams are the
  dialed connections themselves (Part 1, "Carrying the bytes") or a copy in the daemon, and how a
  pseudo-terminal on the Mac is relayed.
- **The guest side** is the agent's own binary, recognized by `argv[0]` as `mawpath` is (decision
  record 0022): linked as `/usr/local/bin/mac` in the way `mawpath` is, and under `/run/maw` as
  the `binfmt_misc` entry's interpreter (and, in B, as `pbcopy` and `pbpaste`); no new guest
  executable is shipped. It runs as the calling user and holds no privilege.
- **One `binfmt_misc` mechanism for phases 09 and 10.** Phase 10 registers Rosetta for x86_64
  ELF executables (Apple's registration names the handler `rosetta`, matches the x86_64 ELF
  header, and sets the flags `C`, `P`, and `F`). This phase's entry must not conflict with it: a
  name with the prefix `maw-`, a magic that matches Mach-O files only and never an ELF file,
  never the `C` flag, never a write to `/proc/sys/fs/binfmt_misc/status`, and never `-1` to an
  entry that maw did not register. The plan chooses where entries are registered (the agent at
  its start, a runtime file under `/run/binfmt.d` that the initramfs writes, or another way) so
  that phase 10 adds its entry in the same place, and records the choice in decision record 0025
  for phase 10.
- **The spawner** lives in `MawDaemonKit`, with one owner per distribution's machine, and ends with
  it. It uses `async`/`await` and actors; `posix_spawn`, a pseudo-terminal, and `waitpid` or a
  kqueue are wrapped at the boundary, as `CLAUDE.md` requires, through `CMawSystem` where Swift
  cannot make the call (decision record 0006).
- **The policy** that decides whether a request is allowed (decisions 1 to 3, 10, 12, 13) is a
  pure type with unit tests, applied by the daemon. The agent may refuse early, but the daemon
  decides.
- **The clipboard and the opener** (B) are their own types behind protocols, so that unit tests
  run them without the owner's pasteboard or Launch Services, and so that the integration tests
  can give the test daemon a pasteboard of a unique name and an opener that records its calls
  (hidden options of `mawd serve`, as `--without-dns` is, which `mawd install` neither accepts nor
  writes).
- **Path translation** between `/mnt/mac` and the Mac home directory is a pure type in `MawCore`,
  shared with `mawpath`, with unit tests.
- A change of the guest protocol increments `ProtocolVersion` and updates `docs/protocol.md`;
  a change of the daemon interface increments `DaemonInterface.version` and updates
  `docs/daemon.md`.
- **No new third-party dependency.** Approved ones only (`CLAUDE.md`).
- The plan says which parts change the guest files, the guest protocol, and the daemon
  interface, in each pull request.

## Security

Write decision record 0025 and `docs/security.md`'s new sections before the code they describe,
and show both in the plan. Record in `docs/security.md`:

- **The trust model.** Update "Trust model": with interop on, a distribution runs programs on the
  Mac as the owner at once, not only through files that it writes under `/mnt/mac` for later.
  Interop is on by default for installed and imported distributions alike (decision 1), and only
  the switch on the Mac (decision 2) turns it off; update the import's section ("Importing an
  archive is therefore running its programs on the Mac as the owner") for interop.
- **What a guest process can ask, and what it cannot.** Only guest root and the default user may
  ask, and processes in containers and other user namespaces are refused (decision 3); they may
  start any Mac program that the owner can run (decision 4). In every case a guest request cannot
  choose the Mac user, raise a privilege (no `sudo`, no authorization prompt, no set-user-ID path
  that maw adds), give the Mac program a descriptor of the daemon's, choose an address the daemon
  listens on, change the daemon's state or settings, or start a machine. Say what guest root can
  do that the default user cannot, and that a switch inside the distribution does not hold
  against guest root.
- **The Mac program's identity.** The user, the fixed environment and `MAWENV` of decision 7, the
  working directory of decision 8, and which process macOS names in a privacy question for it
  (Part 1). If it is `mawd`, say that a Mac program started from Linux uses the privacy
  permissions that the owner gave `mawd`, and that a question it causes names `mawd`, which the
  owner may take for maw itself.
- **Paths and arguments.** Arguments reach the Mac program unchanged (decision 9), and nothing
  the guest sends is used as a Mac path except the working directory's translation and `open`'s
  own argument, both computed from the daemon's own home directory.
- **Executables that the guest writes.** A Mach-O file that the guest writes under `/mnt/mac`
  carries no quarantine attribute and runs on the Mac without a Gatekeeper check, through the
  `binfmt_misc` entry or `mac`. Say so, and that the guest could already make the owner run it
  through `~/Library/LaunchAgents`.
- **A locked, switched-out, or sleeping Mac**, as decision 10 sets it, and what the daemon cannot
  detect (Part 1).
- **The `binfmt_misc` entry**: its flags and why `C` is never set, who can remove it (guest root,
  which only disables the direct execution of Mach-O files for that machine), and its relation to
  phase 10's.
- **The clipboard** (B): that reading it exposes to the distribution whatever the owner copies,
  except items marked `org.nspasteboard.ConcealedType` or `org.nspasteboard.TransientType`, which
  `pbpaste` refuses (decision 12), and that items a password manager does not mark so, passwords
  included, are exposed; its 16 MiB limit; and that its content is never logged.
- **Opening** (B): what decision 13 lets a guest open, how the real path is resolved before the
  check, and why application bundles, executables, `.command`, `.tool`, and `.terminal` files,
  installer packages, disk images, location files, and custom URL schemes are refused.
- **Where a guest's input reaches the Mac.** Requests, argument vectors, environment variables,
  working directories, stream bytes, signals, window sizes, clipboard text, and URLs come from the
  guest. The plan shows how each is bounded and validated, and that none is passed to a shell.
- **Logging**, as decision 11 sets it, with a test that the logs contain no argument, environment
  value, working directory, full path of an executable, clipboard text, or URL from a run.

## Guest files

Both pull requests change the guest files (A: the agent's guest side and interop channel, and
the initramfs for the `binfmt_misc` entry and the links; B: the clipboard, the opener, and the
`pbcopy` and `pbpaste` links). Follow `README.md`, "After a change of the guest protocol or the
daemon interface", and the rules for the shared working tree in
`prompts/11c-distribution-figures.md`, "Installing the builds": open each pull request as a
draft as soon as Guest workflow paths have changed, so that the Guest workflow builds the guest
files, tell the owner before the first build that changes the protocol or the interface, and
give the owner the exact procedure to install the branch's build, with `scripts/fetch-guest.sh`,
and to return to `main`. The owner installs the branch's build; never run
`scripts/fetch-guest.sh` or `mawd install` yourself.

## Tests

Follow decision record 0018 for the test groups.

**What the tests may touch on the Mac.** The automated tests never write the owner's general
pasteboard, never open a file, URL, or application on the owner's Mac, and never cause a privacy
question: they use the test daemon's pasteboard of a unique name and recording opener (see
"Architecture"). Mac programs started by the tests are limited to the ones Part 1 names, and
through `/mnt/mac` they write only in the run's own directory.

**Unit tests, run in CI:**
- The policy: a switched-off distribution, the default user and root, a refused user, a process
  in a container or another user namespace, a locked and a switched-out session for clipboard
  and `open` requests, and a request beyond each limit.
- Path translation: `/mnt/mac` and paths under it, paths outside it, `..`, links, and non-ASCII
  names in NFC and NFD.
- The environment of decision 7: the fixed set, `MAWENV` within and beyond its limits, a `MAWENV`
  name that would replace a variable of the fixed set, `TERM` with and without a
  pseudo-terminal, and that the daemon's own environment does not leak beyond it.
- The spawner: standard streams, half-close, a pseudo-terminal and its size, signals by name,
  exit codes and signal statuses, a program that does not exist or cannot be executed, and the
  end of every Mac program when the guest process ends and when the machine stops.
- The protocol messages and frames, and malformed or oversized ones.
- The `binfmt_misc` entry: its registration string, and that its magic and mask match thin and
  universal arm64 Mach-O headers and not ELF files or Java class files.
- B: the clipboard's text, its 16 MiB limit, and concealed and transient items; the opener's
  decisions for every URL scheme and file kind that decision 13 names, by UTType, and for links
  that resolve outside the home directory.
- The logs: no argument, environment value, working directory, full path of an executable,
  clipboard text, or URL appears in them.

**Integration tests** (`.integration`, through `scripts/integration-test.sh`), on test
distributions from the cached image:
- A: `mac /usr/bin/true` and `mac /usr/bin/false` give 0 and 1; `mac /bin/echo` with arguments
  that contain spaces, quotes, and `$`; `mac /bin/cat` with standard input, with `/dev/null`, and
  with 1 GiB (checksum); a Mac program in a pseudo-terminal sees `isatty` and its window size;
  Ctrl-C ends `mac /bin/sleep` with status 130; the working directory under `/mnt/mac` and
  outside it; a refused user, a process in another user namespace, and a switched-off
  distribution fail as specified; no Mac program survives `maw --terminate`; a Mach-O copy under
  the run's own directory runs through the `binfmt_misc` entry, and the entry is still there
  after `systemctl restart systemd-binfmt`.
- B: `pbcopy` and `pbpaste` against the test daemon's pasteboard, a concealed item included;
  `xdg-open` and Python's `webbrowser.open` reach the recording opener with the Mac path or URL; a
  refused URL scheme, a refused file type, a link that resolves outside the home directory, and a
  file outside `/mnt/mac` are refused.
- The measurements under "Speed targets", tagged as described there.

## Docs

- `docs/decisions/0025-mac-commands.md` (A): the owner's decisions, Part 1's results, the
  request's path, the spawner, the policy, the limits, the `binfmt_misc` mechanism for phase 10,
  what a request sees while the Mac sleeps, and the security model of this phase.
- `docs/decisions/0026-clipboard-and-open.md` (B): the clipboard's API and types, how the guest
  is pointed at the opener, what is opened and refused, by UTType, and the limits.
- `docs/daemon.md`: the spawner, the interop channel, the clipboard and the opener, the hidden
  test options, the interface change.
- `docs/protocol.md`: the new messages and frames, any new vsock port, the protocol version.
- `docs/distributions.md`: what a distribution sees for interop (`mac`, the `binfmt_misc` entry,
  the links under `/usr/local/bin` and `/run/maw`, `pbcopy` and `pbpaste`, `MAWENV`), and what is
  written to its disk, if anything.
- `docs/security.md`: as described under "Security".
- `README.md`: running Mac programs from Linux, the clipboard, `xdg-open`, and the switch.
- `docs/known-limitations.md`: remove what each pull request resolves, add what it defers (the
  global default in `.mawconfig` and `[interop] enabled` in `/etc/maw.conf`, under phase 12; what
  a request sees while the Mac sleeps, under phase 12; whether a running Mac program keeps its
  machine running, under phase 12's idle stop; anything Part 1 found that is not fixed).
- `docs/ROADMAP.md`: 09 stays "Planned" after A and is marked done in B, with the two pull
  requests named as for 08.
- This file reaches `main` through its own pull request before A; A does not add it again.

## Out of scope

- Rosetta and x86_64 Linux executables (phase 10). This phase's `binfmt_misc` work must leave
  phase 10 free to register its entry in the same mechanism, as "Architecture" requires.
- Linux graphical applications on the Mac's screen, as WSLg does.
- Running Linux commands from the Mac; `maw` already does that.
- The global default in `.mawconfig` and `[interop] enabled` in `/etc/maw.conf` (phase 12).
- A share of the Mac's system directories, and appending the Mac's PATH to the guest's.
- Sleep and wake handling beyond recording what a request sees, and the interplay of running Mac
  programs with the idle stop (phase 12).
- Clipboard types other than plain text, clipboard history, and drag and drop.
- Translating paths in environment variables, as `WSLENV`'s `/p` and `/l` flags do.
- Changes to the terminal app, its OSC 52 handling included.

## Acceptance criteria

For each pull request:

- The root package: `swift build -Xswiftc -warnings-as-errors`; `swift build --build-tests
  -Xswiftc -warnings-as-errors`, then `scripts/test-groups.sh all .build/test-results`;
  `swift format lint --strict --recursive Sources Tests Package.swift`.
- `App/MawTerminalKit` builds and its tests pass, as CI's "Terminal app" job runs them.
- After every build or test command, `./scripts/sign-dev.sh`, so that the installed daemon stays
  signed.
- CI and the Guest workflow are green.
- `scripts/integration-test.sh` passes, and the pull request records the development
  measurements and the owner's official run under "Speed targets".
- `/code-review` and `/security-review` ran on the complete diff against `main`, and the pull
  request states what each found and what was done about it (`CLAUDE.md`, "Workflow").

The owner confirms, with the branch's build and guest files installed, using the signed `maw`
by its full path (it is not on the owner's `PATH`). The session gives every command.

After A:
- in a shell in `Ubuntu-24.04`, `mac sw_vers -productVersion` prints the Mac's version, and
  `mac pwd` in `/mnt/mac/<a directory of the session's choosing>` prints its Mac path;
- `echo hello | mac cat` prints `hello`, and `mac false` gives `$?` 1;
- a copy of the Mac's `/usr/bin/true` in a directory under `/mnt/mac` runs directly from Linux,
  with `$?` 0;
- `mac top` runs full screen in the Linux terminal and follows a resize, and `q` ends it;
- Ctrl-C ends `mac sleep 100` at once, with `$?` 130;
- with interop switched off for `Ubuntu-24.04` through the flag of decision 2, the same command
  fails at once with the message that names the switch, `maw --list --verbose` shows the switch,
  and the command works again after it is switched on;
- a request from a guest user other than root and the default user is refused, with its message;
- `~/Library/Logs/maw/mawd.log` shows what decision 11 allows and none of the arguments used;
- no macOS question appeared, or the owner reports what appeared;
- `Ubuntu-24.04` is otherwise unchanged.

After B:
- in Linux, `echo maw-check | pbcopy`, then Cmd-V in TextEdit pastes `maw-check`;
- text copied in TextEdit is printed by `pbpaste` in Linux;
- `xdg-open https://example.com` opens the Mac's default browser on that page, and
  `xdg-open /mnt/mac/<a file of the session's choosing>` opens it in its Mac application;
- each request that decisions 12, 13, and 10 refuse is refused, with its message;
- no macOS question appeared, or the owner reports what appeared;
- `Ubuntu-24.04` is otherwise unchanged.

## How to work

1. Run Part 1 and report its results. Wait for the owner to read them.
2. Present a short plan for A. It must cover: Part 1's results and what follows from each; the
   draft of decision record 0025's security model and of `docs/security.md`'s new sections; the
   request's path and the guest side; `mac`, the `binfmt_misc` entry, and how phase 10 uses its
   mechanism; the spawner, its environment, and its end; the switch's flag and the interface
   change; the limits; the guest files and the procedure to install and return; and an estimate
   of the added lines outside `Tests/`. Wait for approval.
3. Push A early as a draft pull request, as "Guest files" requires; ask the owner to install its
   build and to run A's checks and the official measurements; finish A as described in the
   Workflow section of `CLAUDE.md`. Wait for the owner to merge it.
4. Present a short plan for B from the latest `main`. It must cover: the clipboard's API and why;
   how concealed and transient items are recognized; how the guest is pointed at the opener at
   every boot; the refused types as UTTypes, and how the real path is resolved; the limits; the
   protocol change, if any; and an estimate of the added lines outside `Tests/`. Wait for
   approval.
5. Push B early as a draft pull request, ask the owner to install its build and to run B's checks
   and the official measurements, and finish B as for A.
