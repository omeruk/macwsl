# MacWSL

MacWSL is a Linux subsystem for macOS in the spirit of WSL2. You install a Linux distribution
(Ubuntu first) and run it in a lightweight virtual machine that boots in about a second. Your
Mac home directory is shared at `/mnt/mac`. You use it from the `macwsl` command, which accepts
the same flags as `wsl.exe`, or from a native tabbed terminal app. VMs run on Apple's
Virtualization.framework, with no QEMU, Lima or Docker underneath. MacWSL is in early
development; see [the roadmap](docs/ROADMAP.md) for what works today.

## Requirements

- A Mac with Apple Silicon, running macOS 14 Sonoma or later
- Xcode 16 or later, or a Swift 6 toolchain

## Building

```sh
swift build                                   # build the CLI, daemon and libraries
swift test                                    # run the unit tests
swift format lint --recursive Sources Tests   # lint
./scripts/sign-dev.sh                         # build and ad-hoc sign macwsld for VM access
swift run macwsl --help                       # see the command surface
```

Virtualization.framework refuses to create VMs from unsigned binaries, so run
`scripts/sign-dev.sh` after any build that relinks `macwsld`.

The guest agent runs inside Linux and is built with the
[Swift Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html):

```sh
swift build --swift-sdk aarch64-swift-linux-musl --product macwsl-agent
```

### Integration tests

`scripts/integration-test.sh` runs the whole test suite, including the integration tests that
boot real virtual machines. It builds, signs `macwsld`, and sets `MACWSL_INTEGRATION=1`.
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

Until the daemon and the CLI are connected, `macwsld debug-boot` boots the guest kernel and
initramfs directly, which is useful for development:

```sh
scripts/fetch-guest.sh                            # 1. install the CI-built kernel and initramfs
scripts/sign-dev.sh                               # 2. build and sign macwsld
.build/debug/macwsld debug-boot --interactive     # 3. boot and open the initramfs shell
```

In the interactive session, Ctrl-C goes to the guest. Ctrl-] stops the virtual machine and
returns to your shell. The guest's console is also written to
`~/Library/Logs/MacWSL/debug-boot-console.log`. Run `.build/debug/macwsld debug-boot --help`
for the other options, such as `--cmdline`, `--memory`, and `--disk`. If the terminal is ever
left in raw mode, for example after `kill -9`, `stty sane` restores it.

## Documentation

- [`CLAUDE.md`](CLAUDE.md): architecture, repository layout and conventions
- [`docs/decisions/`](docs/decisions/): design decisions and their reasons
- [`docs/ROADMAP.md`](docs/ROADMAP.md): phases and their status
