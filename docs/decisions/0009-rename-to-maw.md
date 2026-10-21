# 0009: The project is renamed from MacWSL to maw

- Status: Accepted
- Date: 2026-10-21

## Context

The project began as MacWSL, after the Windows feature it is modeled on. Phase 11a introduced
the terminal app under the name maw, with the bundle identifier `dev.maw.app` and its settings
in `~/Library/Application Support/maw`, while every other component still carried the old
name: the `macwsl` and `macwsld` executables, the `MacWSL*` modules, the guest's
`macwsl-agent`, and the `-macwsl` kernel. Two names for one product confuse users and make
every later phase choose between them. The CLI and the daemon are connected over XPC in phase
04b, which adds more names (the Mach service, the LaunchAgent), so the rename is done before it.

There are no users yet, so nothing on disk needs to be migrated by code.

## Decision

Every component takes the name maw, in lowercase as the app writes it. The repository name,
the checkout directory, the vsock port 19799, and the historical record (`prompts/` and
decision records 0001 to 0008) keep the old name.

### Mapping

| Kind | Old | New |
|------|-----|-----|
| Package | `MacWSL` | `maw` |
| Executables | `macwsl`, `macwsld`, `macwsl-agent` | `maw`, `mawd`, `maw-agent` |
| Modules | `MacWSLCore`, `MacWSLProtocol`, `MacWSLVirtualization`, `MacWSLDaemonKit`, `MacWSLAgentKit`, `MacWSLCommandLine`, `CMacWSLSystem` | `MawCore`, `MawProtocol`, `MawVirtualization`, `MawDaemonKit`, `MawAgentKit`, `MawCommandLine`, `CMawSystem` |
| Test targets | `MacWSL*Tests`, `macwslTests`, `macwsldTests` | `Maw*Tests`, `mawTests`, `mawdTests` |
| Types | `MacWSL`, `MacWSLD`, `MacWSLError`, `MacWSLPaths`, `MacWSLVersion` | `Maw`, `Mawd`, `MawError`, `MawPaths`, `MawVersion` |
| C interface | `CMacWSLSystem.h`, `macwsl_*`, `MACWSL_SPAWN_STAGE_*` | `CMawSystem.h`, `maw_*`, `MAW_SPAWN_STAGE_*` |
| Error prefixes | `macwsl:`, `macwsld:` | `maw:`, `mawd:` |
| Logging and queues | subsystem `dev.macwsl`, queues `dev.macwsl.vm.<name>`, `dev.macwsl.agent` | `dev.maw`, `dev.maw.vm.<name>`, `dev.maw.agent` |
| Entitlements | `Resources/macwsld.entitlements` | `Resources/mawd.entitlements` |
| Environment | `MACWSL_INTEGRATION`, `MACWSLD_PATH`, `MACWSL_SWIFT`, `MACWSL_CONTAINER_RUNTIME`, `MACWSL_GUEST_CACHE`, `MACWSL_KERNEL_DIR` | `MAW_INTEGRATION`, `MAWD_PATH`, `MAW_SWIFT`, `MAW_CONTAINER_RUNTIME`, `MAW_GUEST_CACHE`, `MAW_KERNEL_DIR` |
| Host paths | `~/Library/Application Support/MacWSL`, `~/Library/Logs/MacWSL`, `~/.macwslconfig` | `~/Library/Application Support/maw`, `~/Library/Logs/maw`, `~/.mawconfig` |
| Guest configuration | `/etc/macwsl.conf` | `/etc/maw.conf` |
| Kernel | `Guest/kernel/macwsl.config`, `CONFIG_LOCALVERSION="-macwsl"`, build user and host `macwsl` | `Guest/kernel/maw.config`, `"-maw"`, `maw` |
| Kernel command line | `macwsl.test=`, `macwsl.debug=` | `maw.test=`, `maw.debug=` |
| Initramfs | `/sbin/macwsl-agent`, `/sbin/macwsl-shutdown`, `/etc/macwsl-initramfs-version` | `/sbin/maw-agent`, `/sbin/maw-shutdown`, `/etc/maw-initramfs-version` |
| Console messages | `macwsl-initramfs …`, `macwsl-agent self-test: ok`, `macwsl-agent ready …`, `macwsl-shutdown: …` | `maw-initramfs …`, `maw-agent self-test: ok`, `maw-agent ready …`, `maw-shutdown: …` |
| Guest build | builder image `macwsl-guest-builder` | `maw-guest-builder` |
| CI artifacts | `macwsl-agent`, `macwsl-guest` | `maw-agent`, `maw-guest` |
| Planned tools | `macwslpath` (phase 07) | `mawpath` |

## Consequences

- **Existing host files.** The host directory moves from `~/Library/Application Support/MacWSL`
  to `~/Library/Application Support/maw`, which already holds the app's `settings.json`.
  Existing installations move it once, by hand, as the README describes:

  ```sh
  ditto "$HOME/Library/Application Support/MacWSL" "$HOME/Library/Application Support/maw" && rm -r "$HOME/Library/Application Support/MacWSL"
  ```

  `ditto` merges into the existing directory and leaves `settings.json` unchanged. The old log
  directory, `~/Library/Logs/MacWSL`, can be deleted; the next boot writes its log under
  `~/Library/Logs/maw`.
- **Guest files.** Guest files built before the rename must be replaced. The host still
  reaches an older guest's agent over vsock, but `mawd debug-boot` recognizes only the
  `maw-initramfs` banner and passes `maw.debug=shell`, so with an older guest it reports no
  banner time and `--interactive` starts no debug shell. `scripts/fetch-guest.sh` installs the
  renamed guest from the `maw-guest` artifact.
- **Releases.** `guest-v*` tags and their release notes made before the rename keep the old
  names. Later releases use the new ones.
- **Historical record.** `prompts/` and decision records 0001 to 0008 describe the project as
  it was when they were written and are not edited. They refer to the old names.
