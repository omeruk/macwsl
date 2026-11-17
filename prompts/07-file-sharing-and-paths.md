# Phase 07: File sharing and paths

Read `CLAUDE.md`, `docs/decisions/` (0001, 0013, 0015, 0018, and 0020 above all), `docs/daemon.md`,
`docs/protocol.md`, `docs/distributions.md`, `docs/security.md`, and
`docs/known-limitations.md` first.

Until now a distribution sees only its own disk. This phase gives it the Mac's files, the way
WSL gives a distribution `/mnt/c`: the owner's home directory appears in every distribution at
`/mnt/mac`, `maw` started in a directory of the Mac starts the Linux side in the same
directory, and `mawpath` translates paths between the two, as `wslpath` does. With it, a person
can keep a project in `~/Projects` on the Mac, edit it there, and build and run it in Linux
without copying anything.

The phase is delivered in two pull requests, in this order, each from the latest `main`:

- **A, `/mnt/mac`**, on branch `phase/07-mac-share`: the share, its mount in the guest, its
  security record, and the distributions screen's `mounts` row.
- **B, paths**, on branch `phase/07-paths`, after A is merged: the working directory's
  translation, the logind session for a shell with a working directory, `mawpath`, and the
  documentation of `maw --`'s argument joining.

Keep each pull request small. Anything not needed for this phase goes into a separate `fix/`
branch or into `docs/known-limitations.md`. If a plan's estimate exceeds 2,000 added lines
outside `Tests/`, say so in the plan; if the work exceeds 3,000 added lines outside `Tests/` in
one pull request, stop and ask before going on.

## The owner's decisions

These are decided. Do not reopen them in the plan; if a measurement shows that one cannot hold,
stop and report it with the numbers.

1. **The whole home directory, read and write.** The share is the owner's home directory
   (`FileManager.default.homeDirectoryForCurrentUser`), mounted read-write at `/mnt/mac` in
   every distribution's machine. `~/Library`, `~/.ssh`, and every other directory under it are
   included, as `/mnt/c` includes all of `C:`. `docs/security.md` says what this gives a
   distribution (see "Security").
2. **Outside the home directory, the Linux home directory.** When `maw` starts in a Mac
   directory that is not under the home directory, such as `/tmp` or `/Volumes/USB`, and no
   `--cd` is given, the session starts in the Linux user's home directory, and `maw` prints one
   line on standard error that names the directory and says why. The command still runs.
3. **No switch to turn the share off in this phase.** Every distribution gets the share.
   A setting to turn it off, for all distributions or for one, belongs to phase 12's
   `.mawconfig`; record it in `docs/known-limitations.md` under phase 12.

## Part 1 (pull request A, before the plan): what the platform does

Apple documents little about its virtiofs. Before you write the plan, measure on the owner's
Mac what the plan depends on, with a throwaway build on a branch of its own
(`spike/07-virtiofs`, never pushed, deleted afterwards). The spike changes only the host side:
it attaches the share to a distribution's machine, and its tests mount it by hand as root in
the guest (`mount -t virtiofs <tag> <directory>`), so the installed guest files serve
unchanged. Run it as temporary `.integration` tests through
`scripts/integration-test.sh --filter <suite>`, which installs the test daemon under its own
label, on a test distribution that the run installs from the cached image and removes
afterwards; never commit those tests. `scripts/integration-test.sh` builds the working tree,
so the binaries under `.build` are the spike's while it runs: when Part 1 is reported, switch
back to `main`, build, and run `./scripts/sign-dev.sh`, so that the owner's daemon finds
`main`'s binaries again, and say so in the report.

The test daemon shares the owner's real home directory. Every file that the spike writes
through the share goes into one directory that the spike creates for itself,
`~/Library/Caches/maw/spike-07/`, and removes even on failure. Nothing in the spike writes,
renames, or deletes anything else in the home directory, and outside its own directory the
spike only lists directories (`ls`); it never reads the contents of the owner's files.

Find out and report, with the commands and their output:

- **Ownership and permissions.** What `stat` shows in the guest for a file that the owner
  owns on the Mac, as `root` and as the default user (uid 1000); who owns, on the Mac, a file
  created from the guest by each of them; what `chown`, `chmod`, and `chmod +x` from the guest
  do on the Mac, and what they report in the guest; whether the default user can write a file
  of mode 644 and enter a directory of mode 700 that the owner owns; and what happens with a
  file of mode 000 that the owner owns. All of these files are created in the spike's
  directory. Apple's documentation (`VZVirtioFileSystemDevice`) says the framework reads and
  writes with the Mac user's identity and ignores the guest's ownership changes; confirm or
  correct that.
- **Privacy prompts (TCC).** Whether listing `~/Desktop`, `~/Documents`, `~/Downloads`, and
  `~/Library/Mail` from the guest makes macOS ask the owner (report only whether each listing
  succeeded and how many entries it had, never the names), which program the question names
  (`mawd`, the test daemon, or another), whether a refusal shows in the guest as an error or as
  an empty directory, and whether the question returns after `./scripts/sign-dev.sh` signs a
  new build. The owner must be at the Mac, with the lid open, for this run: tell the owner
  before it starts, and ask afterwards what appeared; you cannot see their screen. Never answer
  such a question on the owner's behalf, and never change the privacy settings (`tccutil`
  included).
- **Names.** What a file name with a non-ASCII letter (`ç`, written in NFC on one side and NFD
  on the other) looks like on the other side; what happens when the guest creates `a` and then
  `A` in one directory of the owner's volume, and whether that volume is case-sensitive.
- **Links.** What an absolute symbolic link created on the Mac (`/Users/…`) and one created in
  the guest (`/mnt/mac/…`) look like and resolve to on the other side; whether hard links work.
- **Speed.** Reading and writing a 1 GiB file, `ls -l` of a directory with 10,000 files, and
  `git status` twice in a clone of this repository that `git clone` on the Mac makes in the
  spike directory: the median and
  the slowest of 5 runs, as development figures, with the load average.
- **The mount.** The virtiofs tag and mount options that work, whether `mount -t virtiofs`
  needs anything beyond the kernel's `CONFIG_VIRTIO_FS=y` (`Guest/kernel/maw.config`), and what
  the device costs the machine's cold start, against the same build without it (median of 5).

Put the spike's results in the plan and, in short, in decision record 0021 (see "Docs"). If a
result makes one of the owner's decisions impossible or unsafe, stop and report before planning.

## Product requirements

### The share (A)

- **Every distribution's machine** gets one `VZVirtioFileSystemDeviceConfiguration` with a
  `VZSingleDirectoryShare` of the owner's home directory, read-write, and a fixed tag that the
  plan names. The tag is the same in every machine.
- **The provisioning machine never gets the share.** Installation, `--export`, and `--import`
  run programs of a root file system that may come from outside maw (`docs/security.md`, "The
  extraction"); that machine keeps having no access to the Mac's files. A unit test
  checks the provisioning machine's configuration for the absence of the device, and
  `docs/security.md` says it.
- **The mount happens at every boot, for every installed distribution, without reinstalling
  it.** `Ubuntu-24.04`, installed before this phase, gets `/mnt/mac` after the owner installs
  the new guest files and restarts its machine. maw does not write the mount into the
  distribution's `/etc/fstab`. The plan chooses where the mount is made: in the initramfs before
  `switch_root`, or as a runtime systemd unit under `/run/systemd/system`, as the agent's unit is
  provided (`Guest/initramfs/init`), and says why. The plan also says what creates the mount
  point if the distribution has no `/mnt/mac`, and what an export of such a distribution then
  contains.
- **A failed mount never fails the boot.** The machine boots, sessions work, the reason goes to
  the console log, and the daemon learns that the share is not mounted (see "The snapshot").
  B's working-directory fallback covers a session that would have started under `/mnt/mac`.
- **Ownership** in the guest follows what Part 1 found. If files show as owned by the user who
  looks at them, as Apple's documentation suggests, no mapping is added. If they show as
  uid 501 and the default user cannot write them, stop and report: that would make the share
  unusable for the default user, and the remedy (an idmapped mount, or another) is a decision
  for the owner.
- **Privacy prompts** follow what Part 1 found. `README.md` tells the owner what to expect and
  what to do: which program a question names, what refusing it means, and how to change the
  answer later in System Settings. If the question returns with every new development build,
  say so under "Development" in `README.md`, and record it in `docs/known-limitations.md` under
  phase 13, which signs the release build.

### The snapshot and the distributions screen (A)

- The daemon's snapshot reports, per running distribution, whether the share is mounted, and
  where: the Mac path and the Linux path. How the daemon learns it (for example from the agent)
  is the plan's choice, but not by parsing the console log; it must not add a request
  that runs for every snapshot if a fact known at boot suffices. This changes the daemon
  interface: increment `DaemonInterface.version`, update `docs/daemon.md`.
- The distributions screen's details box gets its `mounts` row, as
  `docs/design/terminal/Distributions.dc.html` shows it (`/mnt/mac ← ~`), for a running
  distribution with the share mounted. For a stopped one, or one whose mount failed, the row is
  left out, because an empty row would be a placeholder, as the known limitation says. This
  resolves "The distributions screen's details box has no `mounts` row".
- **`~/Library` is now writable from every distribution.** Resolve "A `distribution:<name>`
  setting is shown in the pane without a check" as the item suggests: show a name in the pane's
  notice only if it is a valid distribution name, or remove control characters first. The plan
  chooses one.

### The working directory (B)

`maw`'s help already promises this: "A Linux path, a macOS path (translated to its /mnt/mac
location), or ~ for the Linux home directory. Defaults to the current macOS directory."
B makes it true.

- **Without `--cd`**, a shell, a command (`maw <command>`, `maw -- <command>`), and `-e` start
  in the Linux path of `maw`'s current directory: the home directory itself becomes `/mnt/mac`,
  and a directory under it becomes `/mnt/mac/<the rest>`, with names passed through unchanged,
  spaces and non-ASCII letters included. The current directory comes from `getcwd`, and it is
  compared with the home directory after both are resolved, so that a directory under the home
  directory is never reported as outside it (for example when the home directory is reached
  through a link).
- **Outside the home directory**, or when `getcwd` fails (a directory deleted under the shell),
  the session starts in the Linux home directory and `maw` prints one line on standard error,
  for example `maw: /tmp is not shared with Linux; starting in the home directory.` The line
  fits in 80 columns for a typical path and is shown for a shell and for a command alike. It is
  never written to standard output.
- **When the translated directory cannot be used in the guest**, because the share is not
  mounted, the directory went away, or the user cannot enter it, the session also starts in the
  home directory, and `maw` prints a line that says so and why; when the share is not mounted,
  the line names the distribution's console log.
  This fallback applies only to the directory that `maw` chose itself; the guest must be able to
  tell the two apart, and `maw` must learn that the fallback happened, which may need a field in
  the exec request and in its reply. A change of the guest protocol increments
  `ProtocolVersion` and updates `docs/protocol.md`.
- **`--cd <directory>`** keeps its meaning and errors: `~` and `~/<path>`, as `maw` receives
  them, are the Linux home directory and a path under it (today `maw` refuses them, although
  `maw --help` promises `~`); an absolute Linux path is used as given; a Mac path under the
  home directory is translated; a Mac path outside it, such as `/Volumes/USB`, fails with an
  error that says it is not shared and suggests a Linux path (`SessionPlan.macOSDirectories`
  tells the two kinds of absolute path apart); a relative path is resolved against `maw`'s
  current directory on the Mac and then translated. A `--cd` directory that does not exist in
  the guest fails as it fails today; there is no fallback for a directory the user named.
- **The Mac's shell expands an unquoted `~`** before `maw` sees it: `maw --cd ~` reaches `maw`
  as `--cd /Users/alice` and starts in `/mnt/mac`, the Mac home directory, while
  `maw --cd '~'` starts in the Linux home directory. `maw --help` and `README.md` say so.
- **The terminal app's Linux tabs** keep starting in the Linux home directory: a new tab has no
  Mac directory of its own. Record it in `docs/known-limitations.md` if you find it worth
  changing later; do not change the app in B.

### The logind session (B)

Decision record 0015, "Consequence for phase 07", says that once every call carries a working
directory, no shell would be registered with `systemd-logind`. Resolve it:

- Choose among the three options listed there, and record the choice and its measurements in
  decision record 0022. Option 2 (the agent as `runuser -l`'s shell helper, which changes to the
  requested directory after the PAM session is open and then executes the user's shell as a
  login shell) is the expected choice, because it keeps the distribution's PAM stack and adds
  no file to the distribution. If the plan prefers another, it says why.
- A login shell started in a directory, by `--cd` or by translation, is registered with
  `systemd-logind` (`loginctl` lists it), has `XDG_RUNTIME_DIR`, and starts in that directory.
  A `--cd` directory that the user cannot enter fails with a clear error, never with a shell in
  another directory; a translated one falls back as described under "The working directory".
- **The warm prompt stays under its limit of 150 ms**, measured from a directory under the home
  directory, which is now the common case. "The warm prompt runs close to its limit of 150 ms"
  in `docs/known-limitations.md` says it is already close: report the median and the slowest of
  5 before and after, and if B adds more than 10 ms to the median, say where the time goes.

### `mawpath` (B)

`mawpath` runs inside a distribution and translates paths, as `wslpath` does:

```sh
mawpath /Users/alice/Projects/app     # Mac to Linux (the default): /mnt/mac/Projects/app
mawpath -u /Users/alice/Projects/app  # the same, -u stated
mawpath -m /mnt/mac/Projects/app      # Linux to Mac: /Users/alice/Projects/app
mawpath -a -m .                       # the Mac path of the current directory
mawpath -a <path>                     # an absolute result for a relative path
```

(`/Users/alice` stands for the owner's home directory on the Mac.)

- Flags follow `wslpath` where they apply: `-u` for Mac to Linux (the default), `-m` for Linux to
  Mac, `-a` for an absolute result. As with `wslpath`, a relative path gives a relative result
  without `-a`, and is resolved against the current directory with it. `-w` is not offered.
  `mawpath --help` describes them.
- A Linux path outside `/mnt/mac` given to `-m`, and a Mac path outside the home directory, fail
  with a message on standard error and a failure status, because the other side cannot see
  them. Paths are translated textually after `.` and `..` are resolved; the path need not exist,
  as with `wslpath`.
- `mawpath` needs the Mac home directory's path. The plan says how the guest learns it, in a way
  that keeps a path with spaces and non-ASCII letters intact (not the kernel command line if
  that cannot).
- `mawpath` is on `PATH` in a login shell, in `maw <command>`, and in `maw -e mawpath`, in every
  installed distribution, without reinstalling it. The plan says how (for example the agent's
  binary under another name, linked from a directory on the default `PATH` at boot, as
  `wslpath` links to `/init`), what it adds to the distribution's disk, and what an export then
  contains.

### `maw --` and quoting (B)

`maw <command> [<argument>...]` and `maw -- <command>` join their arguments with spaces into one
command line for the user's shell, as `wsl.exe` does, so the Mac shell's quoting is lost:
`maw -- sh -c 'echo a; echo b'` runs `sh -c echo a; echo b`. This is described only in code
(`Sources/maw/SessionPlan.swift`, `shellCommand(_:)`). Say it in `maw --help` and in
`README.md`, with the two ways to keep the arguments intact: `maw -e sh -c 'echo a; echo b'`,
and quoting the whole command line once, `maw -- 'echo a; echo b'`. No behavior changes.

### Speed targets

Measure through the test daemon on test distributions that the measurement installs from the
cached image and removes afterwards, and only in a directory that the run creates under
`~/Library/Caches/maw/` and removes even on failure. Record the median and the slowest of 5 runs
in each pull request, with the date, the commit, and the load average, as development
measurements. The owner then runs the same measurements under the owner's rule: a restarted Mac
on AC power, the lid open, Low Power Mode off, `caffeinate -dims`, only Terminal open, and a
one-minute load average under 2 before the start. Provide one command for that run, a script
under `scripts/` that runs the measurements through `scripts/integration-test.sh` as
`scripts/measure-transfer.sh` does, and tag the measurements so that the integration tests can
run without them. If a target is missed, report the number, where the time goes, and what would
close the gap.

| Measurement | Target | PR |
|-------------|--------|----|
| Cold start to a prompt, with the share, against `main` | adds under 100 ms to the median | A |
| Reading a 1 GiB file from `/mnt/mac` to `/dev/null` | report MB/s | A |
| Writing a 1 GiB file to `/mnt/mac` | report MB/s | A |
| `git status`, second run, in a clone of this repository under `/mnt/mac` | under 1 s | A |
| `ls -l` of a directory of 10,000 files under `/mnt/mac` | report | A |
| Warm start to a prompt from a directory under the home directory | under 150 ms | B |
| `maw -- pwd` from a directory under the home directory, warm | report | B |
| `mawpath` of one path | under 20 ms | B |

## Architecture

- **`MawVirtualization`** adds the directory share to `VMConfiguration` as data (the Mac path,
  the tag, read-only or not), and `VMConfiguration+Virtualization.swift` turns it into the
  Virtualization.framework device, as it does for disks and the network.
  `VirtualMachineHandle` sets it; `VirtualProvisioningMachine` does not.
- **The path translation** is a pure type in `MawCore`, so that `maw`, the agent, and the tests
  share one implementation that compiles on Linux: Mac to Linux, Linux to Mac, the home
  directory itself, `.` and `..`, a trailing slash, a path equal to a prefix of the home
  directory's name (`/Users/alice2` when the home directory is `/Users/alice`), spaces, and
  non-ASCII letters.
- **No new third-party dependency.** Approved ones only (`CLAUDE.md`).
- The plan says which parts change the guest files, the guest protocol, and the daemon
  interface, in each pull request.

## Security

Record in `docs/security.md`:

- **What the share gives a distribution.** Every process in a distribution that runs as root,
  or as the default user, can read and write the owner's home directory with the owner's
  rights on the Mac: `~/.ssh`, `~/Library/LaunchAgents` (a program there runs at the owner's
  next login, outside any VM), the other distributions' disks under
  `~/Library/Application Support/maw/distros/`, and `settings.json`. A distribution is
  therefore as trusted as a program the owner runs on the Mac, as with WSL's `/mnt/c`. Update
  the summary near the start of the file, which says that phase 07 adds `/mnt/mac`.
- **What it does not give.** Files that the owner cannot read on the Mac stay unreadable, the
  guest's ownership changes are ignored on the Mac, and privacy-protected folders are reached
  only as Part 1 found. The provisioning machine has no share.
- **Where a guest's input reaches the Mac.** The working directory and `mawpath`'s Mac home are
  computed on the Mac or handed to the guest; the plan shows that nothing the guest sends back
  is used as a Mac path.

## Guest files

Both pull requests change the guest files (A: the mount; B: the working-directory fallback and
`mawpath`). Follow `README.md`, "After a change of the guest protocol or the daemon interface",
and the rules for the shared working tree in `prompts/11c-distribution-figures.md`, "Installing
the builds": open each pull request as a draft as soon as Guest workflow paths have changed, so
that the Guest workflow builds the guest files, tell the owner before the first build that
changes the protocol or the interface, and give the owner the exact procedure to install the
branch's build, with `scripts/fetch-guest.sh`, and to return to `main`.

## Tests

Follow decision record 0018 for the test groups.

**Unit tests, run in CI:**
- The path translation, with every case under "Architecture".
- The working directory's choice in `maw`: inside the home directory, the home directory itself,
  outside it, `getcwd` failing, a resolved link, and each `--cd` form, with the warning line's
  text and its 80 columns.
- The exec request's new field, if one is added, through the protocol's encoding, and the
  agent's fallback: only for a directory `maw` chose, never for `--cd`.
- `mawpath`'s arguments, output, and errors.
- The machine configuration: the share for a distribution's machine, none for the provisioning
  machine.
- The snapshot's new field through `InterfaceCoding`, and the interface version.
- The app: the `mounts` row's presence and absence, and the pane's notice with a name that is
  not valid.

**Integration tests** (`.integration`, through `scripts/integration-test.sh`), on test
distributions from the cached image. The test daemon shares the owner's real home directory:
every test that writes through `/mnt/mac` does so only in a directory that the run creates under
`~/Library/Caches/maw/` and removes even on failure, and no test writes, renames, or deletes
anything else under `/mnt/mac`. The plan shows the helper that creates and removes that
directory.
- A: a file created on the Mac is read in the guest, and one created in the guest is read on the
  Mac with the owner as its owner; a file written by the default user is editable on the Mac;
  non-ASCII names; `/mnt/mac` present after a restart of the machine; the provisioning machine
  has no share (checked during an installation or an import of a test distribution; the plan
  says how).
- B: `maw -- pwd` from the test directory prints its `/mnt/mac` path; from `/tmp` it prints the
  Linux home directory and the warning; `--cd '~'`, `--cd '~/<path>'`, `--cd` with a Linux
  path, and with a Mac path outside the home directory; a login shell from the test directory
  is listed by `loginctl` and starts in that directory (extend `registersShellsWithLogind`);
  `mawpath` in both directions, inside a session.
- The measurements under "Speed targets", tagged as described there.

## Docs

- `docs/decisions/0021-mac-share.md` (A): what the platform does (Part 1's results), the share's
  scope and its reasons, where the mount is made, and what is left for phase 12 and 13.
- `docs/decisions/0022-working-directory-and-logind.md` (B): the option chosen from 0015, its
  measurements, and the fallback rules. Update 0015's "Consequence for phase 07" to point to it.
- `docs/daemon.md`: the share, the snapshot field, the interface version (A).
- `docs/protocol.md`: any change of the exec request, the protocol version (B).
- `docs/distributions.md`: `/mnt/mac`, what a distribution adds to its disk for it, and the
  working directory (A and B).
- `docs/security.md`: as described under "Security" (A, and B for the guest's input).
- `README.md`: `/mnt/mac`, the privacy prompts, the working directory, `mawpath`, and `maw --`'s
  argument joining.
- `docs/known-limitations.md`: remove what each pull request resolves (the three phase 07 items;
  "Linux tabs show no working directory" stays unless B resolves it), add what it defers (the
  switch to turn the share off, under phase 12; anything Part 1 found that is not fixed).
- `docs/ROADMAP.md`: 07 stays "Planned" after A and is marked done in B, with the two pull
  requests named as for 06b.
- Add this file to `prompts/` in pull request A.

## Out of scope

- Sharing anything outside the home directory, such as `/Volumes` or `/tmp`.
- A switch to turn the share off, a read-only share, or a share of chosen folders (phase 12).
- Changing which directory a Linux tab in the app starts in.
- Mapping file ownership beyond what Part 1 shows is needed.
- Running macOS programs from Linux, the clipboard, and `open` (phase 09).

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

The owner confirms, with the branch's build and guest files installed, using the signed `maw`
by its full path (it is not on the owner's `PATH`). The session gives every command.

After A:
- after `maw --terminate Ubuntu-24.04`, `maw -d Ubuntu-24.04 -- ls /mnt/mac` lists the owner's
  home directory;
- a file that the owner creates on the Mac in a directory the session names is readable in
  Linux; a file created there from Linux shows in Finder, owned by the owner, and opens in
  TextEdit; the owner deletes that directory at the end;
- `ls /mnt/mac/Desktop` from Linux behaves as `README.md` says about privacy prompts;
- the distributions screen shows `mounts  /mnt/mac ← ~` for `Ubuntu-24.04` while it runs, and no
  row while it is stopped;
- `Ubuntu-24.04` is otherwise unchanged: its shell, files, and default status.

After B:
- in Terminal, `cd ~/macwsl` and then `maw -- pwd` prints `/mnt/mac/macwsl`, and `maw` opens a
  shell there in which `loginctl` lists the session;
- `cd /tmp` and then `maw -- pwd` prints the Linux home directory, with the warning on standard
  error;
- `maw --cd '~' -- pwd` prints the Linux home directory, and `maw --cd ~ -- pwd` prints
  `/mnt/mac`;
- in that shell, `mawpath -a -m .` prints the Mac path of `~/macwsl`, and `mawpath` given that Mac
  path prints `/mnt/mac/macwsl`;
- `maw -e sh -c 'echo a; echo b'` prints `a` and `b` on two lines, as `README.md` says;
- `Ubuntu-24.04` is otherwise unchanged.

## How to work

1. Run Part 1 and report its results. Wait for the owner to read them.
2. Present a short plan for A. It must cover: Part 1's results and what follows from each; the
   share's configuration and tag; where and how the mount is made, and the mount point; a failed
   mount; the provisioning machine without the share; the snapshot field and the interface
   version; the `mounts` row; the pane's notice; the integration tests' directory helper; the
   guest files and the procedure to install and return; and an estimate of the added lines
   outside `Tests/`. Wait for approval.
3. Push A early as a draft pull request, as "Guest files" requires; ask the owner to install
   its build and to run A's checks and the official measurements; finish A as described in the
   Workflow section of `CLAUDE.md`. Wait for the owner to merge it.
4. Present a short plan for B from the latest `main`. It must cover: the working directory's
   rules and where each is applied (`maw` or the agent); the protocol change, if any; the logind
   option and its measured cost; how the guest learns the Mac home directory; where `mawpath`
   lives and how it reaches `PATH`; the help and README text for `maw --`; and an estimate of
   the added lines outside `Tests/`. Wait for approval.
5. Push B early as a draft pull request, ask the owner to install its build and to run B's
   checks and the official measurements, and finish B as for A.
