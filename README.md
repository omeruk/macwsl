# maw

maw is a Linux subsystem for macOS in the spirit of WSL2. You install a Linux distribution
(Ubuntu first) and run it in a lightweight virtual machine that boots in about a second. Your
Mac home directory is shared at `/mnt/mac`. You use it from the `maw` command, which accepts
the same flags as `wsl.exe`, or from a native tabbed terminal app. VMs run on Apple's
Virtualization.framework, with no QEMU, Lima or Docker underneath. maw is in early
development; see [the roadmap](docs/ROADMAP.md) for what works today.

### Renamed from MacWSL

The project was called MacWSL until October 2026; the repository keeps that name.
[Decision record 0009](docs/decisions/0009-rename-to-maw.md) lists every renamed executable,
module, path, and guest file. If you ran it before the rename, move its files once:

```sh
ditto "$HOME/Library/Application Support/MacWSL" "$HOME/Library/Application Support/maw" && rm -r "$HOME/Library/Application Support/MacWSL"
```

`ditto` merges into the directory the terminal app already uses and keeps its `settings.json`.
Then install guest files built with the new names with `scripts/fetch-guest.sh`. The old log
directory, `~/Library/Logs/MacWSL`, can be deleted.

## Requirements

- A Mac with Apple Silicon, running macOS 14 Sonoma or later
- Xcode 16 or later, or a Swift 6 toolchain

## Building

```sh
swift build                                   # build the CLI, daemon and libraries
swift test                                    # run the unit tests
swift format lint --recursive Sources Tests   # lint
./scripts/sign-dev.sh                         # build and ad-hoc sign maw and mawd
swift run maw --help                          # see the command surface
```

Virtualization.framework refuses to create VMs from unsigned binaries, and the daemon accepts
only a `maw` with the identifier that the script signs it with, so run `scripts/sign-dev.sh`
after any build that relinks `maw` or `mawd`.

The guest agent runs inside Linux and is built with the
[Swift Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html),
from the swift.org toolchain and SDK that `Guest/agent/SWIFT` pins; Xcode's toolchain cannot
use the SDK. `Guest/README.md` describes their one-time installation. A local agent build is
optional, since `scripts/fetch-guest.sh` installs guest files that CI built:

```sh
scripts/build-guest-agent.sh                  # writes .build/guest-agent/maw-agent
```

### Integration tests

`scripts/integration-test.sh` runs the whole test suite, including the integration tests that
boot real virtual machines. It builds, signs `mawd`, and sets `MAW_INTEGRATION=1`.
Without that variable, `swift test` skips the integration tests. They need an Apple silicon
Mac that is not itself a virtual machine, the guest files from `scripts/fetch-guest.sh`, and a
network connection. They install test distributions named `maw-it-<time>-...` with a daemon of
their own, remove them at the end, and download the Ubuntu image only if
`~/Library/Caches/maw/images` does not have it yet. The script fails the run if the guest
agent started more than once in one boot of a machine. When a test fails, it keeps the test
daemon's logs and the agent's journal and prints where they are.

### Test groups

Tests that assert latency sit in nested suites named `Latency`, and tests that generate heavy
load in nested suites named `Load`. CI runs the tests in three groups, so that load never
delays a latency test: every other test in parallel, then the latency tests one at a time,
then the load generators one at a time. It then checks that every test ran in exactly one group
(`docs/decisions/0018-test-groups.md`). To run the groups the way CI does:

```sh
swift build --build-tests
scripts/test-groups.sh all .build/test-results
```

### Running tests with only the Command Line Tools

Some Command Line Tools releases ship `Testing.framework` but don't put it on the compiler's
framework search path, so `swift test` fails with `no such module 'Testing'`. Installing Xcode
fixes this. Without Xcode, pass the paths yourself:

```sh
DEV=/Library/Developer/CommandLineTools/Library/Developer
swift test -Xswiftc -F -Xswiftc $DEV/Frameworks \
    -Xlinker -rpath -Xlinker $DEV/Frameworks -Xlinker -rpath -Xlinker $DEV/usr/lib
```

### After a change of the guest protocol or the daemon interface

`maw`, `mawd`, the guest files, and the app refuse each other when they come from builds with a
different guest protocol (`guestAgentVersionMismatch`, `docs/protocol.md`) or daemon interface
(`daemonVersionMismatch`, `docs/daemon.md`). The installed daemon is the `mawd` in this working
tree, so every `swift build` replaces the program that launchd starts next. After pulling such a
change, with the app closed and from the repository's root:

```sh
.build/out/Products/Debug/maw --shutdown          # 1. stop every machine with the old build
git pull --ff-only                                # 2. the new sources
scripts/fetch-guest.sh <branch>                   # 3. guest files that CI built for the branch
./scripts/sign-dev.sh                             # 4. build and sign maw and mawd
.build/out/Products/Debug/mawd install            # 5. restart the daemon from the new build
(cd App && xcodegen && xcodebuild build -project maw.xcodeproj -scheme maw \
    -configuration Debug -skipPackagePluginValidation)   # 6. rebuild the app
.build/out/Products/Debug/maw -- uname -r         # 7. check: prints the guest kernel's release
```

- `scripts/fetch-guest.sh` installs the newest successful Guest workflow run on the branch, and
  names that run's commit in its first line. Check that it is the commit of the newest change to
  a path that `.github/workflows/guest.yml` watches, or a later one; without a branch it uses
  `main`.
- Step 1 matters because `fetch-guest.sh` replaces the guest files without stopping any
  machine. `maw --shutdown` does nothing when the daemon does not run.
- Run `scripts/sign-dev.sh` after every later `swift build` or `swift test`, which remove the
  signature that the daemon needs.

### Privacy questions for development builds

Distributions reach the Mac's files through `mawd` (`/mnt/mac`, below), so macOS's privacy
protection asks about `mawd` the first time a distribution opens a protected folder, such as
`~/Desktop`, `~/Documents`, or `~/Downloads`. A development build is signed ad hoc, and macOS
treats every build whose code differs as a new program: after each such build, the question
comes back for every protected folder, also for those allowed before. Folders that need Full
Disk Access, such as `~/Library/Mail`, are refused without a question. Phase 13 signs the
release build, so that an answer lasts across updates
([docs/known-limitations.md](docs/known-limitations.md)).

When installing the build of phase 07's first pull request, the owner answers Allow for
Desktop, Documents, and Downloads, and grants `mawd` no Full Disk Access. An answer can be
changed later in System Settings → Privacy & Security → Files and Folders, under `mawd`.

## Using maw

`maw` runs Linux distributions through the maw daemon, `mawd`, which launchd starts when `maw`
needs it.

1. Install the guest files and build. `scripts/sign-dev.sh` builds `maw` and `mawd` and signs
   them: `mawd` needs the virtualization entitlement, and the daemon accepts only a `maw`
   signed by the script.

   ```sh
   scripts/fetch-guest.sh
   scripts/sign-dev.sh
   ```

2. Put the build directory on your `PATH`, for example in `~/.zshrc`:

   ```sh
   export PATH="$HOME/path/to/maw/.build/debug:$PATH"
   ```

3. Register the daemon with launchd, once. Run it again after rebuilding, so that a running
   daemon restarts with the new build.

   ```sh
   mawd install
   ```

### Installing Ubuntu

```sh
maw --list --online     # the distributions that can be installed
maw --install           # Ubuntu 24.04 LTS, the recommended one
```

maw downloads the image (388 MB, once; an interrupted download resumes), verifies its SHA-256,
and asks for the name and password of your Linux account. The name does not need to match your
Mac user name; the password is what `sudo` asks for. The installation takes about 10 seconds
after the download, and ends in a shell in the new distribution. Ctrl-C at any point cancels
it and leaves nothing behind but the download in the image cache, complete or partial. To install without a terminal, name the
user and give the password on standard input:

```sh
printf '%s\n' "$password" | maw --install -u ayse
```

The questions go to the terminal itself, `/dev/tty`, not to standard output or standard
error, so `maw --install 2>&1 | tee install.log` keeps the progress in a file and still asks
on the terminal; neither the questions nor the answers reach the file.

[`docs/distributions.md`](docs/distributions.md) describes what the installation does and
changes, and where its files are.

### First steps

```sh
maw                             # a login shell as your user, in the current directory
maw -- sudo apt update          # package management
maw -- uname -r                 # the maw kernel, 6.18.x-maw
maw -u root -- id -u            # run as root: prints 0
maw -e sh -c 'exit 3'; echo $?  # -e runs the command directly, without a shell: prints 3
echo hello | maw -e cat         # standard input reaches the command: prints hello
maw --status                    # the daemon, its virtual machines, and their sessions
maw --shutdown                  # stop every virtual machine
maw --version                   # the versions of maw, the daemon, and the guest files
```

The first command starts the daemon and boots the distribution, which takes under a second;
later commands reuse it, and shells in several terminals share it. It stops a minute after the
last session ends, and the daemon exits after five idle minutes. A session ends when its
command or shell exits. Without an installed distribution, `maw` reports that none is installed
and names `maw --install`.

**How `maw --` joins its arguments.** `maw <command> [<argument>...]` and `maw -- <command>`
join their arguments with spaces into one command line for your Linux shell, as `wsl.exe`
does, so the quoting of your Mac shell is lost: `maw -- sh -c 'echo a; echo b'` runs
`sh -c echo a; echo b`, which prints an empty line and then `b`. Keep the arguments intact in
one of two ways:

```sh
maw -e sh -c 'echo a; echo b'   # -e runs the command directly: prints a and b
maw -- 'echo a; echo b'         # one quoted command line for the Linux shell: the same
```

### The working directory

`maw` starts Linux in the directory you are in on the Mac, under `/mnt/mac`:

```sh
cd ~/Projects/app && maw -- pwd    # /mnt/mac/Projects/app
cd ~ && maw -- pwd                 # /mnt/mac
cd /tmp && maw -- pwd              # your Linux home directory, and on standard error:
                                   # maw: /private/tmp is not shared with Linux; starting in
                                   # the home directory.
```

- **Outside your home directory**, such as in `/tmp` or `/Volumes/USB`, Linux cannot see the
  directory, so the session starts in your Linux home directory, and `maw` says so in one line
  on standard error. The same happens when the directory you are in was deleted, or when Linux
  cannot enter it, for example because `/mnt/mac` is not mounted; `maw` then says why.
- **`--cd`** chooses the directory: `--cd /tmp` is Linux's `/tmp`, `--cd ~/src` a directory
  under your Mac home directory, `--cd ../other` a path relative to where you are, and
  `--cd '~'` your Linux home directory. A Mac path outside your home directory, such as
  `--cd /Volumes/USB`, is an error, and so is a `--cd` directory that Linux cannot enter.
- **Quote the `~`.** Your Mac shell turns an unquoted `~` into your Mac home directory before
  `maw` sees it, so `maw --cd ~ -- pwd` prints `/mnt/mac`, and `maw --cd '~' -- pwd` prints
  your Linux home directory.
- **Shells are logind sessions** in any directory: `loginctl` lists them, and
  `XDG_RUNTIME_DIR` and `systemctl --user` work.
- **Tabs of the terminal app** start in your Linux home directory: a new tab has no Mac
  directory of its own.

### Translating paths with mawpath

`mawpath` runs inside every distribution and translates paths, as `wslpath` does in WSL:

```sh
mawpath /Users/you/Projects/app     # Mac to Linux, the default: /mnt/mac/Projects/app
mawpath -u /Users/you/Projects/app  # the same, -u stated
mawpath -m /mnt/mac/Projects/app    # Linux to Mac: /Users/you/Projects/app
mawpath -a -m .                     # the Mac path of the current directory
mawpath -a src                      # an absolute result for a relative path
```

Without `-a`, a relative path gives a relative result. A path that the other side cannot see,
outside `/mnt/mac` or outside your Mac home directory, is an error, and the path need not
exist. `mawpath --help` describes the flags. maw links `/usr/local/bin/mawpath` to its guest
agent when a distribution starts; if `/usr/local/bin` is missing or is a link, the console log
says so ([docs/distributions.md](docs/distributions.md#mawpath)).

### The Mac's files in Linux (/mnt/mac)

Your home directory is `/mnt/mac` in every distribution, as `C:` is `/mnt/c` in WSL:

```sh
maw -- ls /mnt/mac                            # your Mac home directory
maw -- cat /mnt/mac/Projects/app/README.md    # ~/Projects/app/README.md on the Mac
```

- **It is read-write, with your rights.** Root and the distribution's user can read and change
  everything in your home directory that you can, `~/.ssh` and `~/Library` included. Run only
  software that you would run on the Mac itself ([docs/security.md](docs/security.md)).
- **Every file shows your Linux user as its owner**, so `git` and other tools that check
  ownership accept your projects. Other Linux users are held to each file's mode, and on the
  Mac every file that Linux creates is yours.
- **macOS asks about `mawd`** the first time a distribution opens `~/Desktop`, `~/Documents`,
  `~/Downloads`, or another protected folder. If you refuse, the folder shows as `Operation not
  permitted` in Linux, not as an empty folder. To change the answer, open System Settings →
  Privacy & Security → Files and Folders, and switch the folder on or off under `mawd`.
  Folders that need Full Disk Access, such as `~/Library/Mail`, are refused without a
  question.
- **Names ignore case.** The Mac's volume does not tell `a` from `A`, so in `/mnt/mac` they are
  one file: `echo 1 > a; echo 2 > A` leaves one file, `a`, holding `2`. A rename that changes
  only the case, such as `mv notes Notes`, fails with "are the same file"; rename through
  another name instead. Names with letters such as `ç` arrive as they were written.
- **Absolute links work only on the side that made them.** A link to `/Users/you/...` made on
  the Mac leads nowhere in Linux, and one to `/mnt/mac/...` made in Linux leads nowhere on the
  Mac. Relative links work on both sides.
- **Listing large directories is slower than on the Mac**: `ls -l` of 10,000 files took
  1.2 s in Linux in the official measurements, and 0.08 s on the Mac in the development
  figures; the two come from runs under different load. In the official measurements, a
  1 GiB file was written at 1,185 MB/s and read at 2,635 MB/s, and a second `git status` in a
  clone of maw's repository took 41 ms. All are medians of 5 runs on an M1 Pro;
  [decision record 0021](docs/decisions/0021-mac-share.md) has every figure and how it was
  measured.
- **Just after a change on the Mac**, Linux can for a fraction of a second still see the old
  size of a file or the old contents of a directory that was replaced.
- **Only your home directory is shared**, not `/Volumes` or `/tmp`.

If the share cannot be mounted, the distribution still starts, and its console log,
`~/Library/Logs/maw/<name>.log`, has a line `maw-initramfs: /mnt/mac is not mounted:` with the
reason. [docs/distributions.md](docs/distributions.md#the-macs-files-mntmac) describes the
mount.

### Reaching a Linux server from the Mac as localhost

A server that a distribution runs is reachable on the Mac as `localhost`, as in WSL, with no
command and no setting:

```sh
maw -- python3 -m http.server 8000      # in Linux
curl -s localhost:8000 | head -3         # on the Mac, or open http://localhost:8000 in Safari
```

- **What is forwarded.** Every TCP port on which a running distribution listens, on `0.0.0.0`,
  `::`, `127.0.0.1`, or `::1`, is forwarded to the same port on the Mac's `127.0.0.1` and `::1`,
  within a second of the server starting, and ends within a second of the server stopping or
  when the distribution stops. A server bound to the guest's `127.0.0.1` is forwarded too.
  Other machines on your network cannot reach it: maw listens on the Mac's loopback addresses
  only, and any program on this Mac, including other users' programs, can connect.
- **The Mac's ports come first.** A port that a Mac program uses, or that another distribution
  already forwards, is not forwarded, and maw never picks another port. Once the port is free
  on the Mac, restart the server in Linux. While a distribution forwards a port, a Mac program
  that wants it may fail to bind it, or bind it without receiving `localhost` connections; stop
  the Linux server, or run `maw --terminate <name>`.
- **Ports below 1024 are not forwarded**: macOS reserves them on the loopback addresses for
  administrators. Use port 1024 or above, such as 8080 instead of 80.
- **UDP is not forwarded.**
- The distributions screen shows the forwarded ports (`forwarded  localhost:8000 → 8000`), and
  the reason for each port that was not forwarded when the pointer rests on the row.
  [docs/decisions/0023-localhost-forwarding.md](docs/decisions/0023-localhost-forwarding.md)
  describes the design.

### DNS in Linux, VPNs included

Linux looks names up through the Mac's own resolver, as WSL's DNS tunneling does: a name that
the Mac resolves, through a VPN, a corporate DNS server, or a resolver file under
`/etc/resolver/`, resolves in Linux too, and stops resolving when the Mac stops resolving it,
without restarting the distribution.

```sh
maw -- getent hosts github.com           # an address, through the Mac
maw -- resolvectl status                 # the DNS server is 169.254.77.53, the guest agent
```

- Every distribution with systemd-resolved, as Ubuntu has, uses it, and nothing is written into
  the distribution: maw configures it in `/run` at every boot. The DNS server of the virtual
  network, `192.168.64.1`, is not used.
- A name without dots, such as `buildhost`, is tried with the Mac's search domains.
- A, AAAA, CNAME, MX, TXT, SRV, and PTR records are answered; other types are not supported.
- The daemon's log, `~/Library/Logs/maw/mawd.log`, counts the answers once a minute, without
  names.
  [docs/decisions/0024-dns-through-the-mac.md](docs/decisions/0024-dns-through-the-mac.md)
  describes the design.

### Managing distributions

```sh
maw --list                      # the installed distributions; * marks the default
maw --list --verbose            # with the state of each virtual machine (also maw -l -v)
maw --list --running            # only the distributions whose virtual machine runs
maw --list --quiet              # the names only, one per line, for scripts (also maw -l -q)
maw --set-default Work          # plain maw now opens Work (also maw -s Work)
maw --terminate Work            # stop Work's virtual machine and no other (also maw -t Work)
```

Names are matched without regard to case, and maw prints each as it was installed. A catalog
alias such as `Ubuntu` is not an installed name; use the name that `maw --list` shows.
`--set-default` and `--terminate` print nothing when they succeed, and neither starts a
virtual machine: `--terminate` of a distribution that is not running succeeds at once.

`--terminate` ends every session in the distribution, and each reports that the virtual machine
stopped because `maw --terminate` was run. The next command there starts the machine again.
`--running` also lists the distributions whose machine is starting or stopping, so this loop
stops every distribution that has a machine:

```sh
for name in $(maw --list --running --quiet); do maw --terminate "$name"; done
```

With no distribution installed, `maw --list` says so and exits with status 1, as plain `maw`
does; `maw --list --quiet` prints nothing and exits with 0. With none running,
`maw --list --running` prints "No distribution is running." and exits with 0.

### Removing, exporting, and importing a distribution

```sh
maw --unregister Work                    # ask, then stop Work and delete it with its disk
maw --unregister Work --yes              # the same without the question
maw --export Work work.tar               # write Work's root file system to a tar archive
maw --export Work work.tar.gz            # compressed, chosen by the file's extension
maw --export Work work.tar --format tar.xz   # or by --format: tar, tar.gz, or tar.xz
maw --export Work - | ssh other-mac 'cat > work.tar'   # the archive to standard output
maw --import Copy work.tar.xz            # create Copy from a tar archive
maw --import Copy work.tar -u ayse       # with ayse, a user in the archive, as its default user
maw --export Work - | maw --import Copy -   # copy Work through a pipe
```

`--unregister` permanently deletes the distribution's disk and every file in it. On a
terminal it asks "Delete Work and its disk for good? [y/N]" and goes on only after `y` or
`yes`; without a terminal on standard input, as in a script, and with `--yes`, it asks
nothing. It stops the distribution's virtual machine first, which ends its sessions with the
reason "maw --unregister was run", and deletes its logs. If it was the default, maw names the
new default on standard error.

`--export` writes the root file system of a stopped distribution; stop a running one with
`maw --terminate` first. maw creates the file itself with mode 600, because the archive
holds `/etc/shadow` and every user's files, and never replaces an existing file. The format
follows the extension, as `tar -a` does: `.tar.gz`, `.tgz`, and `.gz` give `tar.gz`;
`.tar.xz`, `.txz`, and `.xz` give `tar.xz`, in any case; any other name, and `-`, give an
uncompressed `tar`. A `--format` that is given always wins. Progress goes to standard error,
and Ctrl-C cancels the export and removes the file. POSIX ACLs are not kept
([`docs/known-limitations.md`](docs/known-limitations.md)).

`--import` creates a distribution from a tar archive, such as one from `maw --export` or
`wsl.exe --export`, uncompressed or compressed with gzip, bzip2, xz, compress, or lzip, or from
standard input for `-`. It keeps the archive's
users, files, and locale, and changes only what the distribution needs to boot in maw: its host
name, its network, its machine ID, and a new MAC address. No user is created and no password is
asked. Sessions run as the user that `-u` names, or else as the default user of the archive's
`/etc/maw.conf` or `/etc/wsl.conf`, or else as `root`; maw's last lines name that user. An
archive whose files are all under one directory, or whose `/sbin/init` is not systemd, is
refused. If the first start fails, the distribution stays installed, and maw names its console
log. [`docs/distributions.md`](docs/distributions.md) lists what the import changes.

> **Importing an archive runs its programs with your files.** They run at the import's first
> start and at every later start of the distribution, as you, with read-write access to your
> home directory through `/mnt/mac`. Import only archives that you trust, as you would run
> only programs that you trust ([docs/security.md](docs/security.md)).

To remove the daemon, which stops its virtual machines first:

```sh
mawd uninstall
```

Logs are in `~/Library/Logs/maw`: `mawd.log` for the daemon, `<distribution>.log` for each
distribution's console, including how each shutdown went, `install/<distribution>.log` for
its installation or import, and `export/<distribution>.log` for its last export. [`docs/daemon.md`](docs/daemon.md) describes the daemon in detail.

## Booting the guest on your Mac

> **Build with `scripts/sign-dev.sh`, not `swift build`, before you boot.** Virtualization.framework
> only runs virtual machines for executables signed with the virtualization entitlement, and
> every `swift build` or `swift test` that relinks `mawd` removes the signature.
> `scripts/sign-dev.sh` builds and signs in one step. If you forget, `mawd` stops with a
> message that names the script.

`mawd debug-boot` boots the guest kernel and initramfs directly, without the daemon, and stops
the virtual machine when the command ends. It is useful when developing the guest:

```sh
scripts/fetch-guest.sh                                    # 1. install the CI-built guest files
scripts/sign-dev.sh                                       # 2. build and sign mawd
.build/debug/mawd debug-boot --exec -- uname -a           # 3. run one command in the guest
.build/debug/mawd debug-boot --shell                      #    or open a shell in the guest
```

`--exec -- <command> [<argument>...]` runs one command through the guest agent. Standard
input, output, and error are connected to the command, SIGINT, SIGTERM, and SIGHUP are passed
to it, and `mawd` exits with the command's exit status (128 plus the signal number if a
signal ended it, 127 if the command does not exist) once the virtual machine has shut down:

```sh
echo hello | .build/debug/mawd debug-boot --exec -- cat             # prints hello
.build/debug/mawd debug-boot --exec -- sh -c 'exit 3'; echo $?      # prints 3
```

`--shell` runs `/bin/sh -l` in the guest on a pseudo-terminal that follows your terminal's
window size. Ctrl-C goes to the guest. To stop the virtual machine and return to your shell,
type `~.` at the start of a line, that is, after pressing Enter, as in ssh. `~?` lists the
escape sequences, and `~~` types a single `~`. The `~` sequences work on every keyboard
layout. Ctrl-] works as well, but needs the Option key on many non-US layouts, such as
Turkish, German, and French; `--detach-key ^Q` chooses another control key, and
`--detach-key none` turns it off.

`--interactive` connects the terminal to the guest's console (`hvc0`) instead, with the same
escape sequences. It adds `maw.debug=shell` to the kernel command line, which makes the
guest's `init` run a shell on the console. This is useful when the agent itself does not
start.

Each command reports `boot: banner after <n> ms` and, with `--exec` and `--shell`,
`boot: agent ready after <n> ms`. The guest's console is written to
`~/Library/Logs/maw/debug-boot-console.log`, which also records how the virtual machine
shut down, for example `shutdown: clean after 56 ms via the guest agent`. Run
`.build/debug/mawd debug-boot --help` for the other options, such as `--cmdline`,
`--memory`, and `--disk`. If the terminal is ever left in raw mode, for example after
`kill -9`, `stty sane` restores it.

## Running the terminal app

The terminal app, maw, lives in `App/`. Its code is the `App/MawTerminalKit` package; the
Xcode project is generated from `App/project.yml` with XcodeGen.

1. `xcodebuild -downloadComponent MetalToolchain` (once; SwiftTerm compiles a Metal shader)
2. `brew install xcodegen`
3. `cd App && xcodegen`
4. Open `maw.xcodeproj` and run the `maw` scheme. On the first build, Xcode asks you to trust
   SwiftTerm's `SwiftTermBuildInfoPlugin`; choose Trust & Enable.

Run `xcodegen` again after pulling a change to `project.yml`. The package's tests run without
Xcode's project: `swift test --package-path App/MawTerminalKit`.

### Linux tabs

⌘T, the title bar's `+`, and Shell > New Tab open a tab of the new-tab profile, which is the
default distribution unless the settings say otherwise (see "The new-tab profile" below). A
Linux tab runs the distribution's login shell, as `maw` does, and starts its virtual machine
first if it is stopped. The tab is named `linux` until the session opens, and then takes the
distribution's name. Shell > New Tab and the command palette (⌘⇧P) also offer the default
distribution, each installed distribution by name, and the local shell; the list is read from
the daemon when the menu or the palette opens.

- **Nothing installed.** When no distribution is installed, the tab opens the local shell and
  says so in one line: "No Linux distribution is installed, so this tab opened the local
  shell." When the daemon is not installed, it opens the local shell with maw's message and
  the suggestion to run `mawd install`.
- **Errors.** Any other failure to reach the daemon or to open the session is shown in the
  pane as `maw` prints it, with its suggestion. A tab never opens the local shell in place of a
  distribution in these cases, so that a command meant for Linux does not run on the Mac.
- **A new session.** When a session ends or fails, for example after
  `maw --terminate <name>`, the pane shows `[↩ new session]`. Enter starts a new session of the
  same profile in the same pane and keeps the scrollback.
- **Splits.** ⌘D and ⌘⇧D in a Linux pane open another session of the distribution that the pane
  opened.
- **Closing.** Closing a pane, a tab, or a window, or quitting the app, asks first while a
  program runs in a Linux tab, and names it, for example "sleep is still running and will be
  ended." At the shell's prompt it closes without asking.

### The new-tab profile

The settings (⌘,), page `general`, field `default profile`, choose what ⌘T opens. The app
stores the choice as `defaultProfile` in `~/Library/Application Support/maw/settings.json`:

| `defaultProfile` | ⌘T opens |
|------------------|----------|
| `default-distribution` | The default distribution, the one that `maw --set-default` chose. This is the initial value. |
| `local` | The local shell. |
| `distribution:<name>` | The distribution named `<name>`, for example `distribution:Ubuntu-24.04`. |

If the distribution that `distribution:<name>` names is not installed, ⌘T opens the default
distribution instead and says so in one line, for example "Debian-13 is not installed. This tab
opened Ubuntu-24.04, the default distribution." If nothing is installed, the tab opens the
local shell as described above.

### The distributions screen

⌘⇧L, or View > Distributions, opens the distributions screen. It lists the installed
distributions with the state of each one (starting, running, stopping, or stopped), marks the
default, and shows live figures:

| Column | What it shows |
|--------|---------------|
| MEMORY | Memory in use inside the guest, as `free` reports it as used. |
| CPU | The CPU use of the machine's process on the Mac, in percent of one core, as Activity Monitor shows it; it may exceed 100 %. |
| DISK | The space the disk image takes on the Mac, and the most it can grow to: `2.2G/256G`. |
| UPTIME | The time since the machine started. |
| KERNEL | The running guest's kernel, or the one the next start boots. |

A stopped distribution shows its disk and kernel only. Below the table, a details box shows the
selected distribution's default flag, user, and disk image, and while it runs its IPv4
address, the ports forwarded to the Mac (`forwarded  localhost:8000 → 8000`, with the reason
for each port that was not forwarded in the row's help text), the Mac's home directory mounted
at `/mnt/mac` (`mounts  /mnt/mac ← ~`), the time from
its start to its agent (`boot`), and the memory its process takes on the Mac (`host memory`).
A memory chart shows the last 60 seconds of MEMORY while it runs. A figure that is not known
is left empty.

The screen follows the daemon while it is visible in a window: a machine that starts or stops
for any reason, such as a tab in another window, `maw` in a terminal, or the idle stop, changes
its row at once, and the figures follow every 1.5 seconds. Reading them never starts a machine
or keeps one running. While no window shows the screen, because another tab is selected or the
window is minimized or covered, the app holds no connection for it and the daemon samples
nothing. When the daemon cannot be reached, the screen shows maw's message and suggestion, and
tries again after 1, 2, 4, 8, and 16 seconds, then every 30 seconds while it stays visible.

| Key | Action |
|-----|--------|
| ↩ | Open a tab in the selected distribution. |
| `s` | Stop the selected distribution while it starts or runs. When sessions are open in it, the screen asks first and names their number. |
| `d` | Make the selected distribution the default, as `maw --set-default` does. |
| `i` | Install a distribution. This arrives in a later version; until then, use `maw --install`. |
| esc | Return to the previous tab. |

## Documentation

- [`CLAUDE.md`](CLAUDE.md): architecture, repository layout and conventions
- [`docs/decisions/`](docs/decisions/): design decisions and their reasons
- [`docs/protocol.md`](docs/protocol.md): the host and guest agent protocol
- [`docs/daemon.md`](docs/daemon.md): the daemon, its machines, and its XPC interface
- [`docs/distributions.md`](docs/distributions.md): installing distributions, and what maw
  changes in them
- [`docs/security.md`](docs/security.md): every way into the guest and the host, and what
  protects it
- [`docs/known-limitations.md`](docs/known-limitations.md): known limitations and deferred
  work, by the phase that owns them
- [`docs/ROADMAP.md`](docs/ROADMAP.md): phases and their status
