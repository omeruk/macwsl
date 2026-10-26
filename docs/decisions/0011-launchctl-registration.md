# 0011: During development, mawd install registers the daemon with launchctl

- Status: Accepted
- Date: 2026-10-22

## Context

`mawd` runs as a per-user LaunchAgent with the label `dev.maw.mawd`, which vends a Mach service
of the same name. launchd starts it when a client connects. `CLAUDE.md` names `SMAppService`
for the registration. `SMAppService.agent(plistName:)` requires the agent's plist inside the
calling app's bundle (`Contents/Library/LaunchAgents`) and the executable inside the bundle
too. maw has no bundle that contains `mawd` until packaging, in phase 13. Until then,
development builds run from `.build/debug`.

The options considered:

1. **Build an app bundle for development now.** Phase 13 would do this work early, and every
   rebuild would need an extra bundling step before the daemon could run.
2. **Run `mawd serve` by hand.** A Mach service can only be looked up when launchd vends it,
   so there would be no on-demand start, and every test would need a running process.
3. **Write the LaunchAgent plist and load it with `launchctl bootstrap`.** This is what
   `SMAppService` does internally, without the bundle requirement.

## Decision

Option 3, as `mawd install` and `mawd uninstall`:

- `mawd install` writes `~/Library/LaunchAgents/dev.maw.mawd.plist` and loads it with
  `launchctl bootstrap gui/<uid>`. The plist runs the absolute path of the `mawd` that ran the
  command, with `serve` as the argument. It vends the Mach service `dev.maw.mawd`, has
  `ProcessType` `Interactive`, and sends standard output and error to
  `~/Library/Logs/maw/mawd.log`. It has neither `RunAtLoad` nor `KeepAlive`: launchd starts the
  daemon on the first connection, and an idle daemon exits.
- `mawd install` is idempotent. When the agent is already loaded, it is unloaded with
  `launchctl bootout`, which stops the daemon with SIGTERM, and loaded again, so that a rebuilt
  `mawd` takes effect. `bootout` returns before launchd has removed the job, and until then
  launchd refuses a `bootstrap` of the same label ("Bootstrap failed: 5: Input/output error").
  `mawd install` therefore waits, for up to 30 seconds, until `launchctl print` no longer finds
  the job, and then runs `bootstrap` once; if the job is still there, it fails with
  `launchAgentNotRemoved`. `mawd uninstall` waits in the same way.
- `mawd uninstall` asks a running daemon to stop its machines, unloads the agent, and removes
  the plist. The logs are kept.
- Hidden options (`--label`, `--log-directory`, `--machine-idle-timeout`,
  `--daemon-idle-timeout`) register a second daemon under another label. The integration
  tests use them, so that they never touch the installed daemon.

## Moving to SMAppService in phase 13

Phase 13 bundles `mawd` into `maw.app`:

1. The plist moves to `maw.app/Contents/Library/LaunchAgents/dev.maw.mawd.plist`, with
   `BundleProgram` (`Contents/MacOS/mawd`) in place of an absolute `ProgramArguments[0]`, and
   `AssociatedBundleIdentifiers` naming the app.
2. The app registers it with `SMAppService.agent(plistName: "dev.maw.mawd.plist").register()`
   on first launch, and the user approves it in System Settings > Login Items.
3. `mawd install` and `mawd uninstall` remain for development builds. Before registering with
   `SMAppService`, the app removes a development agent of the same label with `launchctl
   bootout`, so that launchd never has two jobs for one Mach service.

The label, the Mach service name, the log location, and the XPC interface stay the same, so
clients are unaffected.

## Consequences

- The plist names the executable's path, so launchd starts a rebuilt `mawd` the next time it
  launches the daemon. A daemon that is still running keeps the old code until it exits;
  `mawd install` restarts it. A plain `swift build` also replaces the signature that
  `scripts/sign-dev.sh` adds, so the README tells developers to rebuild with the script. When the client and the running daemon speak different interface versions, `maw`
  reports the mismatch with `mawd install` as the fix; a daemon of an older build with the same
  interface version is not detected.
- The plist names a path inside the build directory. Deleting `.build` leaves a registered
  agent that cannot start; `mawd install` from a new build replaces it.
