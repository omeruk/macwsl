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
[Swift Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html):

```sh
swift build --swift-sdk aarch64-swift-linux-musl --product maw-agent
```

### Integration tests

`scripts/integration-test.sh` runs the whole test suite, including the integration tests that
boot real virtual machines. It builds, signs `mawd`, and sets `MAW_INTEGRATION=1`.
Without that variable, `swift test` skips the integration tests. They need an Apple silicon
Mac that is not itself a virtual machine, the guest files from `scripts/fetch-guest.sh`, and a
network connection. They install test distributions named `maw-it-<time>-...` with a daemon of
their own, remove them at the end, and download the Ubuntu image only if
`~/Library/Caches/maw/images` does not have it yet.

### Running tests with only the Command Line Tools

Some Command Line Tools releases ship `Testing.framework` but don't put it on the compiler's
framework search path, so `swift test` fails with `no such module 'Testing'`. Installing Xcode
fixes this. Without Xcode, pass the paths yourself:

```sh
DEV=/Library/Developer/CommandLineTools/Library/Developer
swift test -Xswiftc -F -Xswiftc $DEV/Frameworks \
    -Xlinker -rpath -Xlinker $DEV/Frameworks -Xlinker -rpath -Xlinker $DEV/usr/lib
```

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
it and leaves nothing behind but the partial download. To install without a terminal, name the
user and give the password on standard input:

```sh
printf '%s\n' "$password" | maw --install -u ayse
```

[`docs/distributions.md`](docs/distributions.md) describes what the installation does and
changes, and where its files are.

### First steps

```sh
maw                             # a login shell as your user, in your Linux home directory
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
last session ends, and the daemon exits after five idle minutes. `maw <command>` passes the
command line to your Linux shell with `-c`; the Mac's shell has already removed your quotes,
so use `-e` when the arguments must arrive unchanged. A session ends when its command or shell
exits. Without an installed distribution, `maw` reports that none is installed and names
`maw --install`.

### Removing a distribution

`maw --unregister` arrives in phase 06. Until then, stop the virtual machines and delete the
distribution's directory, which permanently deletes its disk:

```sh
maw --shutdown
rm -r "$HOME/Library/Application Support/maw/distros/Ubuntu-24.04"
```

To remove the daemon, which stops its virtual machines first:

```sh
mawd uninstall
```

Logs are in `~/Library/Logs/maw`: `mawd.log` for the daemon, `<distribution>.log` for each
distribution's console, including how each shutdown went, and `install-<distribution>.log` for
its installation. [`docs/daemon.md`](docs/daemon.md) describes the daemon in detail.

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

## Documentation

- [`CLAUDE.md`](CLAUDE.md): architecture, repository layout and conventions
- [`docs/decisions/`](docs/decisions/): design decisions and their reasons
- [`docs/protocol.md`](docs/protocol.md): the host and guest agent protocol
- [`docs/daemon.md`](docs/daemon.md): the daemon, its machines, and its XPC interface
- [`docs/ROADMAP.md`](docs/ROADMAP.md): phases and their status
