# Phase 01: Scaffold

Read `CLAUDE.md` first. It describes the product, the architecture, and the conventions you
must follow.

## Goal

Create the project skeleton so that every later phase has a place to land. No
virtualization code yet. At the end, `swift build` and `swift test` pass, and the `macwsl`
CLI exposes its full command surface with stubbed behavior.

## Tasks

1. **Package.swift**
   - Swift tools version 6.0, strict concurrency, platform `.macOS(.v14)`.
   - Create every target listed under "Repository layout" in `CLAUDE.md`. macOS-only targets
     must be excluded when building for Linux, so that
     `swift build --swift-sdk aarch64-swift-linux-musl --product macwsl-agent` can work
     later.
   - Dependency: `swift-argument-parser` only.

2. **MacWSLCore**
   - `DistroName` value type with validation (letters, digits, `.`, `-`, `_`, 1 to 64
     characters).
   - `MacWSLPaths`: every host path from "On-disk layout" in `CLAUDE.md`, with the base
     directory injectable for tests.
   - `MacWSLError`: typed error enum conforming to `LocalizedError`, with `errorDescription`
     and `recoverySuggestion`.

3. **macwsl CLI**
   Use `swift-argument-parser`. Accept the same spellings as `wsl.exe`:
   - `--install [<distro>]`, `--list` / `-l` with `--verbose` / `-v`, `--online` / `-o`
   - `-d` / `--distribution <name>`, `-u` / `--user <name>`, `--cd <path>`
   - `--set-default` / `-s <name>`, `--terminate` / `-t <name>`, `--shutdown`
   - `--export <name> <file>`, `--import <name> <file>`, `--unregister <name>`
   - `--status`, `--version` / `-v` (resolve the clash with `--list -v` the way `wsl.exe`
     does: `-v` means verbose only after `-l`)
   - `-- <command> [args...]` and `-e` / `--exec <command>`
   - With no arguments: open a shell in the default distro.

   `wsl.exe` uses a flag-style interface rather than subcommands, so model it as one root
   command with mutually exclusive actions, and validate the combinations. Every action
   currently prints `not implemented yet` to stderr and exits with code 1. Help text must be
   complete and polished, since it is user-facing.

4. **Placeholder executables**
   `macwsld` and `macwsl-agent` each have a `main.swift` that logs a startup line and exits.

5. **Tests** (swift-testing)
   - `DistroName` validation: valid names, invalid names, edge lengths.
   - `MacWSLPaths` with an injected base directory.
   - CLI argument parsing: every action parses into the right value, and invalid
     combinations (for example `--shutdown -d Ubuntu`) are rejected with a clear message.

6. **Tooling**
   - `.swift-format` config: 4-space indent, 100-column lines.
   - `.gitignore` for SwiftPM, Xcode, and macOS.
   - `scripts/sign-dev.sh`: ad-hoc signs `macwsld` with an entitlements file containing
     `com.apple.security.virtualization`. Add `Resources/macwsld.entitlements`.
   - GitHub Actions workflow on `macos-15` (Apple Silicon): build, test, lint.

7. **Docs**
   - `docs/decisions/0001-native-virtualization-framework.md`: why native
     Virtualization.framework rather than Lima or QEMU.
   - `docs/decisions/0002-one-vm-per-distro.md`: why one VM per distro for v1 (simpler
     isolation and lifecycle), and the trade-off against WSL2's single shared VM (memory
     use). Note that a shared VM may come later.
   - `README.md`: one paragraph on what the project is, plus build instructions.

## Out of scope

Anything that boots a VM, talks over vsock or XPC, or downloads files. Do not create the
Xcode app project yet.

## Acceptance criteria

- `swift build` and `swift test` pass on macOS with no warnings.
- `swift format lint --recursive Sources Tests` reports nothing.
- `swift run macwsl --help` shows the complete, readable command surface.
- `swift run macwsl -l -v` prints `not implemented yet` and exits 1.
- `swift run macwsl --shutdown -d Ubuntu` fails with a clear validation message.
- CI workflow file is valid.

## How to work

Start by presenting a short plan (files you will create, and how you will model the
`wsl.exe`-style flag interface). Wait for approval, then implement. Finish by updating the
status of phase 01 in `docs/ROADMAP.md`.
