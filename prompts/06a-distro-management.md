# Phase 06a: Distro management

Read `CLAUDE.md`, `docs/decisions/`, `docs/daemon.md`, and `docs/security.md` first. Work on
branch `phase/06a-distro-management` from the latest `main`.

Phase 05 lets a person install Ubuntu and use it. This phase lets them manage what they have
installed: see their distributions and whether each one runs, choose the default, and stop one
distribution without stopping the others. It is the first half of phase 06; phase 06b adds
`--unregister`, `--export`, and `--import`. The daemon's side of this phase is also what the
terminal app's distributions screen will use in phase 11b, so design its messages for both
clients.

Keep this phase small. Phase 05 grew to 168 files and about 19,700 added lines because
unrelated fixes went into it. Here, anything that is not needed for the commands below goes
into a separate `fix/` branch or into "Known limitations and follow-up work", not into this
pull request. If the change grows beyond about 3,000 added lines outside `Tests/`, stop and
propose a split before going on.

## Goal

At the end of this phase, these commands work on the owner's Mac, with the signed build on the
`PATH`:

```sh
maw --list                       # installed distributions; * marks the default
maw --list --verbose             # with each one's state
maw --list --running             # only the running ones
maw --list --quiet               # names only, one per line, for scripts
maw --set-default <name>         # the distribution that plain `maw` opens
maw --terminate <name>           # stop that distribution's machine only
```

The short forms follow `wsl.exe`: `-l`, `-v`, `-q`, `-s`, `-t`.

## Product requirements

### Speed targets

Measure on the owner's Mac and record the median of 5 runs in the PR. If a target is missed,
report the number, where the time goes, and what would close the gap.

| Measurement | Target |
|-------------|--------|
| `maw --list --verbose`, daemon running, at least two distributions installed | under 50 ms |
| `maw --set-default <name>`, daemon running | under 50 ms |
| `maw --terminate <name>` of a running, idle distribution, to maw's exit | under 1 s |
| `maw --list` while the daemon is not running (launchd starts it) | report only |

### Experience rules

- **Output.** `--list` and `--list --verbose` use the table style of `maw --status` and
  `maw --list --online` (`Reports.table`). The states are `Running`, `Stopped`, `Starting`,
  and `Stopping`. `--quiet` prints names only, one per line, without a header or a marker.
- **Empty results.** With no distribution installed, `--list` and `--list --verbose` fail with
  the existing `noDistributionInstalled` error, which names `maw --install`, and exit with 1,
  as plain `maw` does. `--quiet` prints nothing and exits with 0, so that scripts can loop over
  its output. `--running` with no running distribution prints one line that says so and exits
  with 0; with `--quiet`, it prints nothing.
- **Combinations.** `--running` and `--quiet` combine with each other and with `--list`;
  `--verbose` combines with `--running` but not with `--quiet`. None of them combines with
  `--online`, which keeps its phase 05 meaning. A combination that is not allowed is a usage
  error, exit status 64, as for other invalid combinations today.
- **Success is quiet.** `--set-default` and `--terminate` print nothing and exit with 0 when
  they succeed, as `--shutdown` does today. `--terminate` of a distribution that is installed
  but not running succeeds and starts no machine.
- **Names.** A name is matched against the installed distributions without regard to case,
  as the file system does, and the stored spelling is what is recorded and printed. Catalog
  aliases such as `Ubuntu` are not installed names and are not accepted here.
- **Errors explain and suggest.** Every new failure is a `MawError` case with a message and a
  suggested fix, and the suggestion names only commands that work in this build. An unknown
  name suggests `maw --list`. Every printed line fits in 80 columns, `maw: ` included, for a
  name of 12 characters such as `Ubuntu-24.04`.
- **Sessions on a terminated distribution** end with the existing `machineStopped` error, and
  its reason names `maw --terminate`. A terminal session restores the terminal first, as
  today.

## Architecture

### Daemon interface

- New requests for listing the installed distributions with their states and the default,
  for setting the default, and for terminating one distribution. The listing comes from the
  daemon, which owns the distributions directory and the machines; clients do not read the
  daemon's files. Reply with the stored names, the default, and the machine state of each.
- This changes the daemon interface: increase `DaemonInterface.version` and update
  `docs/daemon.md`.
- The XPC client checks of `docs/security.md` apply to the new requests unchanged. Add to its
  section "The daemon's XPC service" that a client can now also change the default and stop
  one distribution: what any process of the same user could already do with `--shutdown`, so
  the same-user check stays the boundary.

### Terminate

- Stop the one machine the way `--shutdown` stops each machine today: a clean shutdown
  through the agent, then the framework's stop, then a forced stop, with the existing time
  limits. Its sessions end, and their clients receive `machineStopped` with a reason that
  names `maw --terminate`.
- **A machine that is still starting.** The phase 05 review found that `forceStop` does
  nothing while a machine is starting (CR-8, deferred to phase 12b). `--terminate` must have
  a defined behavior for a machine that is starting: either wait for the start to finish and
  then stop it, or cancel the start. State the choice in the plan, with its reason, and test
  it.
- **An installation in progress** under the same name is not a distribution yet. `--terminate`
  of that name fails as for any name that is not installed, and does not affect the
  installation.
- After a terminate, the next `maw -d <name>` starts the machine again, as after an idle stop.

### Default distribution

- `--set-default` records the stored name in `state.json` through
  `DistributionStore.setDefaultDistribution`, written atomically as today. It works whether or
  not the daemon runs any machine, and it does not start one.
- Plain `maw` and `maw --list` see the new default at once. The terminal app will read it
  through the same request from phase 11b on.

### Messages that waited for this phase

Update every place that says phase 06 will add one of these commands, or that suggests a
workaround for their absence. At least:

- `MawError.sessionConnectionEnded`: suggest `maw --terminate <name>` instead of
  `maw --shutdown` (`docs/daemon.md`, "Known limitations", the entry that names phase 06).
- `installationCancellationUnconfirmed` and `installationOutcomeUnknown`: suggest
  `maw --list` where they now suggest `maw -d <name> -e true`, if that is clearer.
- `Action.phase` and the `notImplemented` messages: `--list`, `--set-default`, and
  `--terminate` are implemented; `--unregister`, `--export`, and `--import` name phase 06b.
- `docs/daemon.md` (`--set-default`, the root file system repair command),
  `docs/distributions.md`, and `README.md`: say which phase now owns each item, 06b or later.

Search for `phase 06` and `PHASE 06` in `Sources/`, `docs/`, and `README.md`, and list each
match in the plan with what you will do with it.

## Tests

**Unit tests, run in CI:**
- Argument parsing: every new form and its short form; `--verbose`, `--running`, and
  `--quiet` only with `--list`; every combination under "Combinations"; the conflicts with
  other actions and with `-d`; a missing name.
- The output and exit status of each `--list` form with no distribution installed and with
  none running.
- The new requests and replies: their `Codable` round trip and the interface version.
- The daemon's handling against a fake store and registry: listing with and without a
  default, a stored default that is no longer installed, case-insensitive names, an unknown
  name, terminate of a running, a stopped, and a starting machine.
- The tables at 80 columns, `--quiet` output, and every new message, with the `maw: ` prefix.

**Integration tests** (`.integration`, through `scripts/integration-test.sh`):
- Install two test distributions from the cached image. Then:
  - `--list --verbose` shows both, with the right states and default, before and after one
    is started;
  - `--set-default` changes what plain `maw` opens, and the change survives a daemon restart;
  - `--terminate` stops one machine while the other keeps running and keeps its session;
  - a session open on the terminated distribution ends with `machineStopped` naming
    `maw --terminate`;
  - `--terminate` of a stopped distribution succeeds without starting it;
  - an unknown name fails with its error.
- The measurements under "Speed targets".
- Every test removes the distributions it created.

## Docs

- `docs/daemon.md`: the new requests, the interface version, and the terminate sequence.
- `docs/security.md`: the new requests (see "Daemon interface").
- `README.md`: listing, choosing the default, and stopping one distribution.
- `docs/ROADMAP.md`: mark 06a as done.

## Out of scope

- `--unregister`, `--export`, and `--import` (phase 06b).
- A command that repairs a distribution whose root file system failed its check.
- The terminal app's distributions screen (phase 11b).
- Fixing CR-8 for other callers of `forceStop`, and the other phase 12b limitations, except
  where "Terminate" above requires a defined behavior.
- Wrapping messages to the terminal's width (recorded for phase 12b).

## Acceptance criteria

- `swift build -Xswiftc -warnings-as-errors`, `swift test`, and `swift format lint --strict`
  pass, and CI and the Guest workflow are green.
- The commands under "Goal" behave as described on the owner's Mac.
- `scripts/integration-test.sh` passes, and the PR records every measurement under "Speed
  targets".
- The owner confirms:
  - the output of `maw --list` and `maw --list --verbose` is clear;
  - after `maw --set-default`, plain `maw` opens the chosen distribution;
  - with a shell open in another window, `maw --terminate` of its distribution ends that shell
    with a clear message and a working terminal, while a shell in another distribution keeps
    working.

## How to work

1. Present a short plan first. It must cover:
   - the new requests and replies, and the interface version;
   - the `--list` output, with an example of each form at 80 columns, including the output
     with no distribution installed and with none running;
   - the terminate sequence, and the behavior for a machine that is starting;
   - every `phase 06` reference and what happens to it;
   - an estimate of the added lines outside `Tests/`.

   Wait for approval.
2. Push early as a draft PR.
3. Ask the owner to run the interactive checks. You cannot type on their keyboard. The last
   check needs a second distribution: install a test distribution from the cached image
   first, so that the owner's `Ubuntu-24.04` is the other one, and remove the test
   distribution afterwards.
4. Finish with the PR, as described in the Workflow section of `CLAUDE.md`.
