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
- `main` always builds and passes tests. Never commit to `main` directly.
- Each phase gets its own branch from the latest `main`: `phase/NN-short-name` (for example
  `phase/02-kernel`). Small fixes outside a phase use `fix/short-name`.
- Keep commits small, with messages in the imperative mood.
- When a phase is done, update `docs/ROADMAP.md` with its status in the same branch.
- When every acceptance criterion passes locally, push the branch and open a pull request
  into `main` with `gh pr create`. Title: `Phase NN: <name>`. Fill in the body from
  `.github/pull_request_template.md`, including the actual result of each acceptance
  check.
- Never merge a pull request yourself. The owner reviews and merges.

## Writing standards

Commit messages, pull request titles and descriptions, review comments, and replies are
part of the project's permanent record. Write them in English, in a formal, precise, and
neutral register.

### General rules

- Use complete sentences and a neutral tone.
- State facts and measured results. Do not speculate. Where something is uncertain, say so
  explicitly and explain how it will be resolved.
- No emoji, exclamation marks, slang, or conversational filler. For example, avoid "just",
  "simply", "basically", "Good catch!", and "LGTM".
- Refer to code by repository-relative path, and add a line number where relevant
  (`Sources/macwsl/ArgumentNormalizer.swift:42`). Put identifiers, commands, and flags in
  backticks.
- Report failures, skipped checks, and known limitations as plainly as successes.

### Commit messages

- **Subject line:**
  - Imperative mood, capitalized, no trailing period, at most 72 characters.
  - May carry a module prefix, for example
    `CLI: Reject --shutdown combined with --distribution`.
- **Body:** Separated from the subject by a blank line and wrapped at 72 columns. It
  explains what changed and why, not how.

### Pull requests

- **Title:** `Phase NN: <Name>` for phase work. Otherwise `<Area>: <Summary>`, in the same
  form as a commit subject.
- **Body:** Follows `.github/pull_request_template.md`. Every section is filled in, or
  marked "Not applicable." with a one-line reason.

### Review comments and replies

- **Comment structure:** Each comment states three things, in this order:
  1. The observation.
  2. Its impact.
  3. The proposed resolution.
- **Replying to a comment:**
  - Name the commit that addresses it, or give the reason no change was made.
  - Do not resolve a thread you did not open unless the change fully addresses it.

### Merging

- Pull requests are squash-merged.
- The squash commit title is the pull request title, followed by the pull request number.
- The squash commit body is the pull request's Summary section.
