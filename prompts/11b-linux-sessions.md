# Phase 11b: Linux sessions in the app

Read `CLAUDE.md`, `docs/decisions/`, `docs/design/terminal/`, `docs/protocol.md`,
`docs/daemon.md`, `docs/security.md`, and `docs/known-limitations.md` first. Work on branch
`phase/11b-linux-sessions` from the latest `main`.

Phase 11a built the terminal app with the local shell. This phase makes the app a client of
the daemon: it opens Linux distributions in tabs, offers each one as a profile, and shows the
installed distributions on the distributions screen with their state, through the requests that
phase 06a added. Phase 11c adds the live resource figures of that screen.

Keep this phase small. Anything that is not needed for the features below goes into a separate
`fix/` branch or into `docs/known-limitations.md`, not into this pull request. If the change
grows beyond about 3,000 added lines outside `Tests/`, stop and propose a split before going on.

## Goal

At the end of this phase, on the owner's Mac, with the daemon installed and `Ubuntu-24.04` the
default distribution:

- **⌘T opens the default distribution.** A new tab opens a login shell in the distribution that
  `maw --set-default` chose, and follows a later change of it. With no distribution installed,
  it opens the local shell.
- **Profiles.** The new-tab menu and the command palette offer the local shell and one profile
  per installed distribution.
- **The distributions screen** lists the installed distributions with their state and the
  default, and can open a tab in one, make one the default, and stop one.
- **Closing a Linux tab asks first** when a program other than the shell runs in it, as it
  does for the local shell. Closing a window and quitting the app do the same for every tab.
- **Errors appear in the pane** with maw's own message and suggested fix, as `maw` prints them.

## Product requirements

### Speed targets

Measure on the owner's Mac and record the median of 5 runs in the PR. If a target is missed,
report the number, where the time goes, and what would close the gap. Measure in code, through
the session layer, not by watching the screen.

| Measurement | Target |
|-------------|--------|
| A new Linux session in a running distribution, from its start to the first bytes of the prompt | under 150 ms, as warm `maw` |
| A new Linux session in a stopped distribution, from its start to the first bytes of the prompt | under 2 s, as cold `maw` |
| The foreground-program report (below), from the request to the answer | under 100 ms |
| About 1.3 GB of output in a Linux tab (`head -c 1000000000 /dev/zero \| base64`) | report the time and the app's peak memory; the app stays responsive throughout |
| Typing latency: from sending a key to receiving its echo, in a Linux session | report only |

### Experience rules

- **Errors explain and suggest.** A session that cannot open, or that ends because its machine
  stopped or its connection ended, shows maw's `MawError` message and suggested fix in the pane,
  as `maw` prints them, and never a raw Swift error. The pane then offers to start a new session,
  as it does for a local shell that has ended.
- **It feels like a terminal.** Turkish characters type and display correctly, `vi`, `top`, and
  `htop` work, and resizing the window resizes the guest's terminal.
  - `TERM` names the terminal that the app emulates, not one inherited from an environment.
  - The locale follows the same rules as the app's local shell (`ShellLocale`); the agent falls
    back to `C.UTF-8` where the distribution lacks it. Phase 11a found that an invalid locale
    breaks multibyte input.
- **Output never freezes the app.** A flood of output is read only as fast as the terminal view
  draws it, as `TerminalSessionDelegate` requires, and the app's memory stays bounded.
- **The app never invents data.** Distributions come from the daemon. Columns that phase 11c
  fills show an empty value until then, not a placeholder number.
- **Closing is safe.** When a program other than the shell runs in a Linux tab, closing the tab
  or the window, or quitting the app, asks first and names the program.
  - The answer must be current: a program that has just ended does not trigger the question.
  - Waiting for the answer never blocks the main thread. If no answer arrives within 500 ms,
    for example because the guest does not respond, the app asks anyway and says that a program
    may be running.

## Architecture

### Package wiring

- `App/MawTerminalKit` depends on the root package through `.package(path: "../..")`, as
  decision record 0008 planned. The root package exports the library products that the app
  needs, such as `MawClient`; add only those. Update decision record 0008.
- CI's "Terminal app" job must keep building and testing the app. The root build and the guest
  agent's Linux build must not start to need SwiftTerm or the Metal Toolchain.

### The daemon accepts the app

- The daemon's peer requirement (`Sources/MawXPC/PeerRequirement.swift`) accepts the app's
  signing identifier, `dev.maw.app`, besides `dev.maw.maw` and `dev.maw.mawd`.
- Update `docs/security.md`, "The daemon's XPC service": the app is a client; the same-user
  check stays the boundary until phase 13 adds the team identifier.

### Descriptors in the app

- The app starts local shells, and every descriptor it receives for a Linux session must be
  closed on exec before any local shell can start, as `maw` and `mawd` already ensure
  (`F_DUPFD_CLOEXEC`). Otherwise a local shell, and every program it starts, inherits the Linux
  sessions. Test it, and add it to `docs/security.md`.

### The foreground-program report

- The agent can tell the host which program runs in the foreground of a terminal session: the
  foreground process group of the session's pseudo-terminal (`tcgetpgrp` on its primary side),
  and that group's program name from `/proc`.
  - "None" means that the shell itself is in the foreground.
  - When the group's leader has exited, as in some pipelines, report a program without a name
    rather than none.
  - Pipe sessions have no foreground program.
- The host asks only when it needs the answer, such as before closing a tab, so that an idle
  session carries no extra traffic. Design the exact message in the plan.
- This changes the protocol: increase its version and update `docs/protocol.md`. A host and
  guest files of different versions keep failing with `guestAgentVersionMismatch`; check that
  its suggestion names the command that installs matching guest files.
- The request is available to both `maw` and the app. `maw` itself does not use it in this
  phase.

### Linux sessions

- **The core in the root package.** Put the part of a Linux session that needs neither SwiftTerm
  nor AppKit in the root package, for example in `MawClient`: opening the session, the lease,
  the exec request, output with flow control, input, resize, the foreground request, and how the
  session ends. It uses the existing client and protocol code, and does not reimplement framing,
  the handshake, flow control, or the dial-back. The integration tests can then run it against
  the test daemon.
- **`LinuxSession` in the app** is a `TerminalSession` that wraps that core and runs the user's
  login shell. Its `displayName` is the distribution's name.
- **Lease.** Each Linux tab holds its session's lease exactly while it is open. Closing the tab
  ends the lease, so that the machine's idle stop works, and quitting the app ends them all.
  `maw` holds a lease for as long as its XPC connection is open; state in the plan how the app
  ends one tab's lease.
- **Titles and directories.** Titles come from OSC 0 and 2. The working directory comes only
  from OSC 7; the app does not poll the guest for it. Ubuntu's shell does not send OSC 7 by
  default, so Linux tabs show no directory; record that in `docs/known-limitations.md`.
- **Closing** a Linux tab ends its session as closing a terminal window ends an ssh session:
  the guest's shell receives SIGHUP.
- Nothing outside the session layer may depend on which kind of session it is.

### Profiles and the new-tab setting

- One profile per installed distribution, from `listDistributions`, besides the local shell.
  The list is refreshed when the new-tab menu, the command palette, or the distributions screen
  opens, and after an action on the screen; it is not polled.
- The new-tab setting offers "the default distribution", the local shell, and each installed
  distribution. Its initial value is "the default distribution", which follows
  `maw --set-default` and falls back to the local shell when nothing is installed. A setting
  that names a distribution that is no longer installed falls back the same way, and the new
  tab says so in one line.

### The distributions screen

- A `DistributionProvider` backed by the daemon replaces `NoDistributions`. It shows each
  distribution's name, state, and the default marker, as `Distributions.dc.html` lays them out.
  Extend the app's distribution state to the four states the daemon reports: starting, running,
  stopping, and stopped. MEMORY, CPU, DISK, UPTIME, and KERNEL stay empty until phase 11c.
- Actions, through the command registry: open a tab in the selected distribution, make it the
  default, and stop it. Stopping asks first when the distribution has open sessions, and says
  how many; count every session the daemon reports (`status`), not only the app's tabs. The
  install action keeps its "arrives in a later version" note.
- When the daemon cannot be reached, the screen says so with maw's message and suggestion
  instead of showing the empty state.

## Tests

**Unit tests, run in CI:**
- The peer requirement accepts `dev.maw.app` and still refuses other identifiers.
- The new protocol message: its encoding, its round trip, and the version check.
- The agent's foreground report: the process-group logic against a pseudo-terminal where the
  platform allows it, and the name lookup, including a group whose leader has exited.
- The session core against a scripted daemon and agent on socket pairs, as `maw`'s tests do:
  output, input, resize, a title, an end with an exit status, an end because the machine
  stopped, an end of the connection, and the foreground report, including one that does not
  answer in time.
- Descriptors: a session's descriptor is closed on exec, and a local shell started after it
  does not inherit it.
- In `App/MawTerminalKit`: the profiles, the new-tab setting and its fallbacks, the provider,
  the screen's actions, and the close and quit confirmations, against a fake daemon client.

**Integration tests** (`.integration`, through `scripts/integration-test.sh`):
- The session core against the test daemon on a test distribution: the prompt arrives, input
  echoes, a resize reaches the guest, and closing ends the guest's shell.
- The foreground report on a real distribution: none at the prompt, `sleep` while `sleep 30`
  runs, and none again after it ends.
- The speed targets above.
- Every test removes the distributions it created and protects the owner's `state.json`, as
  phase 06a's tests do.

## Docs

- `docs/protocol.md`: the new message and the version.
- `docs/security.md`: the app as a client of the daemon, and the descriptors in the app.
- `docs/daemon.md`: the app as a client.
- Decision record 0008: the dependency on the root package.
- `README.md`: using Linux distributions in the app.
- `docs/known-limitations.md`: remove the items this phase resolves, such as "The terminal app
  is not a client of the daemon", and add what it defers.
- `docs/ROADMAP.md`: mark 11b as done.

## Out of scope

- The live resource figures of the distributions screen, its details box, and its memory chart
  (phase 11c).
- Installing, removing, exporting, or importing a distribution from the app (phases 06b and
  later).
- Registering the daemon with `SMAppService`, and the team identifier in the peer requirement
  (phase 13).
- Reconnecting a session after the daemon or the machine restarts; the pane offers to start a
  new session instead.
- The working directory of Linux tabs without OSC 7.

## Acceptance criteria

- `swift build -Xswiftc -warnings-as-errors`, `swift test`, and `swift format lint --strict`
  pass for the root package and for `App/MawTerminalKit`; CI, including the "Terminal app"
  job, and the Guest workflow are green.
- `scripts/integration-test.sh` passes, and the PR records every measurement under "Speed
  targets".
- The owner confirms, on the Turkish keyboard:
  - ⌘T opens a shell in `Ubuntu-24.04` quickly, Turkish characters type correctly, `vi`, `top`,
    and `htop` work, and `top` follows a resize of the window;
  - with `sleep 60` running in a Linux tab, ⌘W asks first and names `sleep`, and so does ⌘Q;
    at the prompt, ⌘W closes the tab without asking;
  - the distributions screen shows the installed distributions with their state and the
    default, and its actions open a tab, make a distribution the default, and stop one;
  - `maw --terminate Ubuntu-24.04` from Terminal.app, while a Linux tab is open, ends that tab
    with maw's message, and the pane offers a new session;
  - about 1.3 GB of output does not freeze the app.

## How to work

1. Present a short plan first. It must cover:
   - the package wiring, and the products the root package adds;
   - the foreground-program message, its place in the protocol, and the version;
   - the session core and `LinuxSession`: where each part lives, opening, the lease, output and
     flow control, resize, closing, and every way a session ends;
   - how the app makes received descriptors close on exec;
   - how the profiles and the provider get the list, and when they refresh it;
   - the screen's actions and their confirmations;
   - a split of the implementation into parts, each ending with the checks passing, and which
     part changes the guest files;
   - an estimate of the added lines outside `Tests/`.

   Wait for approval.
2. Push early as a draft PR, so that the Guest workflow builds the new guest files.
3. Ask the owner to run the interactive checks. You cannot type on their keyboard.
4. Finish with the PR, as described in the Workflow section of `CLAUDE.md`.
