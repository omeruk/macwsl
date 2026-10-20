# MacWSL

A WSL2-style Linux subsystem for macOS. Users install Linux distributions (Ubuntu first),
run them in lightweight VMs that boot in about a second, and use them from a `macwsl` CLI
(modeled on `wsl.exe`) or from a native, tabbed terminal app (modeled on Windows Terminal).

The goal is a professional, shippable product, not a demo. Favor correctness, clear error
messages, and clean resource handling over feature count.

## Platform constraints

- Apple Silicon only (arm64). macOS 14 Sonoma or later.
- Swift 6 with strict concurrency. Swift Package Manager for everything except the `.app`
  bundle.
- Host virtualization uses Apple's `Virtualization.framework` directly. No QEMU, Lima, or
  Docker dependency.
- Any binary that creates a VM must be signed with the `com.apple.security.virtualization`
  entitlement (ad-hoc signing is fine for local development).

## Architecture

```
 macwsl (CLI)          MacWSL.app (SwiftUI + SwiftTerm)
      \                     /
       \   XPC (launchd)   /
        +----- macwsld -----+        per-user LaunchAgent, owns all VMs
                  |
                  | Virtualization.framework
                  v
     +------------------------------+
     | Linux VM (one per distro)    |
     |  macwsl-agent  <-- vsock --> |  exec, PTY, signals, resize, status
     |  /mnt/mac      <-- virtiofs  |  user's Mac home directory
     |  rootfs on sparse raw disk   |
     +------------------------------+
```

- **macwsld**: per-user daemon registered with `SMAppService`. Owns VM lifecycle
  (start, stop, idle shutdown, sleep/wake handling). Exposes an XPC Mach service. For
  interactive sessions it connects to the guest over vsock and hands the connection's file
  descriptor to the client over XPC, so terminal bytes do not pass through the daemon.
- **macwsl**: CLI built with `swift-argument-parser`. Mirrors `wsl.exe` semantics and flags
  where they make sense on macOS (`--install`, `--list --verbose`, `-d`, `--shutdown`,
  `--terminate`, `--set-default`, `--export`, `--import`, `--unregister`, `-- <command>`).
- **macwsl-agent**: guest init helper and daemon, written in Swift and built with the Swift
  Static Linux SDK (musl, fully static). Listens on vsock. Runs commands with or without a
  PTY, forwards stdio, signals, window size, and exit codes.
- **Guest kernel and initramfs**: our own minimal arm64 kernel config (virtio, virtiofs,
  vsock, ext4, binfmt_misc for Rosetta). Booted with `VZLinuxBootLoader`. The initramfs
  contains busybox, e2fsprogs, and the agent. It formats and provisions new distro disks
  inside the VM, so the host never needs Linux filesystem tooling.
- **MacWSL.app**: SwiftUI app using SwiftTerm. Tabs, one profile per distro, themes, and a
  JSON settings file.

Design decisions and their reasons live in `docs/decisions/`. Read them before changing
architecture.

## Repository layout

```
Package.swift
Sources/
  MacWSLCore/            shared models, paths, config parsing, errors (macOS + Linux)
  MacWSLProtocol/        host <-> guest wire protocol (macOS + Linux)
  MacWSLVirtualization/  Virtualization.framework wrappers (macOS only)
  MacWSLDaemonKit/       daemon logic, XPC interface (macOS only)
  macwsl/                CLI executable
  macwsld/               daemon executable
  macwsl-agent/          guest agent executable (Linux only)
Tests/                   one test target per library, swift-testing
Guest/
  kernel/                kernel config fragment + build script
  initramfs/             initramfs build script
App/                     Xcode project for MacWSL.app
docs/                    architecture, protocol spec, decisions
prompts/                 phase prompts used to build this project
```

## On-disk layout (host)

- `~/Library/Application Support/MacWSL/distros/<name>/disk.img` sparse raw ext4 disk
- `~/Library/Application Support/MacWSL/distros/<name>/distro.json` metadata
- `~/Library/Application Support/MacWSL/kernel/` kernel and initramfs
- `~/Library/Logs/MacWSL/` daemon and per-VM console logs
- `~/.macwslconfig` global settings (like `.wslconfig`): memory, CPUs, swap, idle timeout
- `/etc/macwsl.conf` inside each distro (like `wsl.conf`): default user, automount, boot
  command

## Commands

```sh
swift build                                   # host targets
swift test                                    # unit tests
swift build --swift-sdk aarch64-swift-linux-musl --product macwsl-agent   # guest agent
swift format lint --recursive Sources Tests   # lint
./scripts/sign-dev.sh                         # ad-hoc sign with virtualization entitlement
```

Integration tests that boot a real VM are tagged `.integration` and only run on a Mac.

## Conventions

- Use `async`/`await` and actors. No `DispatchQueue` in new code unless an Apple API
  requires it, and wrap those at the boundary.
- Errors are typed enums conforming to `LocalizedError`, with a user-facing message and a
  suggested fix. The CLI never prints a raw Swift error.
- Log with `os.Logger` (subsystem `dev.macwsl`, one category per module). Never `print` from
  library code.
- Keep platform-specific code in its own module. `MacWSLCore` and `MacWSLProtocol` must
  compile on Linux.
- Every new feature ships with unit tests. Anything touching VM lifecycle also needs an
  integration test.
- Do not add a third-party dependency without recording the reason in `docs/decisions/`.
  Approved so far: `swift-argument-parser`, `swift-log` (guest only), `SwiftTerm`.

## Workflow

- Work one phase from `prompts/` at a time. Plan first, show the plan, then implement.
- Keep commits small, with messages in the imperative mood.
- When a phase is done, update `docs/ROADMAP.md` with its status.
