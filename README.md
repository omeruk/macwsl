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
./scripts/sign-dev.sh                         # build and ad-hoc sign mawd for VM access
swift run maw --help                          # see the command surface
```

Virtualization.framework refuses to create VMs from unsigned binaries, so run
`scripts/sign-dev.sh` after any build that relinks `mawd`.

The guest agent runs inside Linux and is built with the
[Swift Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html):

```sh
swift build --swift-sdk aarch64-swift-linux-musl --product maw-agent
```

### Integration tests

`scripts/integration-test.sh` runs the whole test suite, including the integration tests that
boot real virtual machines. It builds, signs `mawd`, and sets `MAW_INTEGRATION=1`.
Without that variable, `swift test` skips the integration tests. They need an Apple silicon
Mac that is not itself a virtual machine, and the guest files from `scripts/fetch-guest.sh`.

### Running tests with only the Command Line Tools

Some Command Line Tools releases ship `Testing.framework` but don't put it on the compiler's
framework search path, so `swift test` fails with `no such module 'Testing'`. Installing Xcode
fixes this. Without Xcode, pass the paths yourself:

```sh
DEV=/Library/Developer/CommandLineTools/Library/Developer
swift test -Xswiftc -F -Xswiftc $DEV/Frameworks \
    -Xlinker -rpath -Xlinker $DEV/Frameworks -Xlinker -rpath -Xlinker $DEV/usr/lib
```

## Booting the guest on your Mac

> **Build with `scripts/sign-dev.sh`, not `swift build`, before you boot.** Virtualization.framework
> only runs virtual machines for executables signed with the virtualization entitlement, and
> every `swift build` or `swift test` that relinks `mawd` removes the signature.
> `scripts/sign-dev.sh` builds and signs in one step. If you forget, `mawd` stops with a
> message that names the script.

Until the daemon and the CLI are connected, `mawd debug-boot` boots the guest kernel and
initramfs directly, which is useful for development:

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
- [`docs/ROADMAP.md`](docs/ROADMAP.md): phases and their status
