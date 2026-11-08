# Known limitations

This file lists every known limitation and every piece of deferred work, grouped by the phase
that owns it. Every pull request adds the items it defers and removes the items it resolves.

Each item states what a user or a developer sees, the evidence, and the owning phase. Where
another document already describes an item in full, the item links to it. Evidence refers to
files on `main`, to pull request descriptions, and to review IDs such as CR-8, which pull
request #19 lists under "Review results". Commits from the branch of pull request #19 are not
cited, because that pull request was squash-merged and its branch commits are not reachable
from `main`.

## Phase 06a: Distro management

- **No `maw --list`, `maw --set-default`, or `maw --terminate`.**
  - **Seen:** The three commands fail with `notImplemented`: "--list is not implemented yet;
    phase 06 adds it." `maw --status` shows the running machines, but nothing lists the
    installed distributions, and the default is set only when the first distribution is
    installed.
  - **Evidence:** `Sources/maw/Action.swift:28`; pull request #19, "Known limitations and
    follow-up work"; `docs/daemon.md`, "Installing distributions" ("Phase 06 adds
    `maw --set-default`").
  - **Phase:** 06a (`prompts/06a-distro-management.md`).
- **`sessionConnectionEnded` suggests `maw --shutdown`.**
  - **Seen:** When a session's connection ends unexpectedly, the suggestion offers
    `maw --shutdown` to end a command that may still be running, which stops every running
    distribution.
  - **Evidence:** `Sources/MawCore/MawError.swift:475`; [docs/daemon.md, "Known
    limitations"](daemon.md#known-limitations), the entry on connections that end on the
    host's side.
  - **Phase:** 06a. The suggestion names `maw --terminate <name>` once that command exists.

## Phase 06b: Distro removal and transfer

- **No `maw --unregister`, `maw --export`, or `maw --import`.**
  - **Seen:** The three commands fail with `notImplemented` and name phase 06. A distribution
    is removed by hand: `maw --shutdown`, then deleting its directory.
  - **Evidence:** `Sources/maw/Action.swift:28`; pull request #19, "Known limitations and
    follow-up work"; [docs/distributions.md, "Removing a distribution by
    hand"](distributions.md#removing-a-distribution-by-hand) and `README.md`, "Removing a
    distribution", describe the manual removal.
  - **Phase:** 06b.
- **CR-7: An imported root file system whose `/sbin/init` is not systemd.**
  - **Seen:** On a distribution's machine, only systemd starts the agent, through the unit
    that the initramfs writes. A distribution whose `/sbin/init` is not systemd would fail to
    start with the generic timeout for the agent, without naming the reason.
  - **Evidence:** `Guest/initramfs/init:78`; pull request #19, "Review results", CR-7.
    Installation from the catalog cannot produce such a distribution.
  - **Phase:** 06b. `--import` checks `/sbin/init` and refuses such a file system by name.

## Phase 07: File sharing and paths

- **Shells with a working directory have no logind session.**
  - **Seen:** A login shell started with `--cd` skips `runuser -l`, so it is not registered
    with `systemd-logind`. Once phase 07 sends the Mac's working directory with every call, no
    shell would be registered, and `XDG_RUNTIME_DIR` and `systemctl --user` would depend on
    linger alone.
  - **Evidence:** [Decision record 0015](decisions/0015-sessions-through-pam.md), "Consequence
    for phase 07", which lists the options.
  - **Phase:** 07.

## Phase 11b: Linux sessions in the app

- **The terminal app is not a client of the daemon.**
  - **Seen:** The daemon accepts only `maw` and `mawd` as peers. The terminal app runs local
    shells only.
  - **Evidence:** [docs/daemon.md, "The terminal app"](daemon.md#the-terminal-app): phase 11b
    adds `dev.maw.app` to `PeerRequirement.identifiers`.
  - **Phase:** 11b.

## Phase 12: Configuration and lifecycle

- **No setting for `.fsync` disk synchronization.**
  - **Seen:** Every distribution uses `.full` synchronization. A user who prefers speed cannot
    choose `.fsync`; see "Accepted trade-offs" for the default.
  - **Evidence:** [Decision record 0013](decisions/0013-systemd-and-the-agent.md), item 6,
    "Disk", and "Measurements"; `docs/ROADMAP.md`, row 12.
  - **Phase:** 12, a `.mawconfig` setting.
- **The memory balloon is not driven.**
  - **Seen:** Memory that the guest has used stays with the machine's process until the
    machine stops.
  - **Evidence:** The balloon device is configured
    (`Sources/MawVirtualization/VMConfiguration+Virtualization.swift:51`), but no code sets its
    target size. [Decision record 0013](decisions/0013-systemd-and-the-agent.md), item 5.
  - **Phase:** 12.

## Phase 12b: Hardening

- **The dial-back exchange costs about 1.8 ms per session.**
  - **Seen:** Warm `maw -e true` measured 33 ms against 31 ms with host-opened sessions, within
    the target of 50 ms.
  - **Evidence:** [Decision record 0017](decisions/0017-dial-back-for-sessions.md), "What it
    costs" and "Consequences"; pull request #19, "Before and after the dial-back".
  - **Phase:** 12b. Two options, neither built or measured: a persistent request connection
    per machine, estimated to save 0.7 ms and requiring a protocol change; or reused threads in
    the daemon and the agent, estimated to save 0.1 to 0.3 ms without a protocol change.
- **Virtualization.framework can end the host's side of a guest-opened connection.**
  - **Seen:** Rarely, a running session ends with `sessionConnectionEnded`, and in bursts of
    64 sessions an accepted connection is reset. The command may keep running in the guest
    until the machine stops. The cause is not established.
  - **Evidence:** [docs/daemon.md, "Known limitations"](daemon.md#known-limitations) describes
    what the user sees, the exit status, and the mitigations. Pull request #19, Part 5a and
    "Known limitations and follow-up work", records the investigation: the mid-stream case in
    1 of 6 full integration runs, the burst case in 2 of 6.
  - **Phase:** 12b. Proposed next steps: a burst run with the agent's source port rotated
    instead of reused; a run that keeps each `VZVirtioSocketConnection` open for its session's
    lifetime; and a minimal reproduction outside maw for a Feedback Assistant report. Either
    mitigation changes the protocol.
- **Many messages are wider than 80 columns.**
  - **Seen:** Messages and suggestions are single lines, many longer than 80 columns, and
    some contain text of unknown length from Foundation or paths. Examples: the account prompt
    (90 columns), and, with the name `maw-capture`, the suggestion of
    `distributionAlreadyInstalled` (81) and `machineStopped` (85).
  - **Evidence:** `Sources/maw/InstallCommand.swift:372`, `Sources/MawCore/MawError.swift:375`;
    pull request #19, "Known limitations and follow-up work". Four messages are wrapped by hand,
    each with an 80-column test: the cancellation, the password with a control character, and
    the unconfirmed cancellation (`Tests/mawTests/FailureTests.swift`), and
    `sessionConnectionEnded` (`Tests/MawCoreTests/MawErrorTests.swift:259`).
  - **Phase:** 12b. Proposed: `CommandFailure` wraps its output at spaces to the terminal's
    width when standard error is a terminal, and leaves it unchanged otherwise.
- **CR-3: A resumed download does not check `Content-Range`.**
  - **Seen:** A `206` response is appended at the end of the partial file whatever range it
    carries. A server that ignores the requested start, which RFC 9110 forbids, shifts the
    file; the SHA-256 check then deletes it, and the download starts over. Integrity is not
    affected, because nothing reads an image before its SHA-256 matches.
  - **Evidence:** `Sources/MawDaemonKit/ImageCache.swift:305`; pull request #19, "Review
    results", CR-3.
  - **Phase:** 12b. Parse `Content-Range`, and start over from 0 when its start differs from
    the requested offset.
- **CR-8: `forceStop` does nothing while a machine starts.**
  - **Seen:** Ctrl-C during "Creating the virtual disk" takes effect only when the boot and
    the wait for the agent end: about a second normally, and up to 30 s if the agent does not
    answer. Past 5 s, `maw` reports `installationCancellationUnconfirmed`.
  - **Evidence:** `Sources/MawVirtualization/VirtualMachine.swift:287`; pull request #19,
    "Review results", CR-8.
  - **Phase:** 12b. Record the request and stop the machine as soon as the start completes,
    or stop a starting machine if the framework allows it; either needs an integration test.
    Phase 06a defines the behavior of `--terminate` for a starting machine on its own
    (`prompts/06a-distro-management.md`, "Terminate").
- **CR-11: Two copies of the `posix_spawn` setup.**
  - **Seen:** Developers maintain the same setup twice: the pipe, `/dev/null` input, the
    signal mask and defaults, `POSIX_SPAWN_CLOEXEC_DEFAULT`, and the exit status. There is no
    effect on users.
  - **Evidence:** `Sources/MawDaemonKit/StreamingProcess.swift:66` and
    `Sources/MawXPC/Launchctl.swift:166`; pull request #19, "Review results", CR-11.
  - **Phase:** 12b, a shared helper.
- **SR-M-2: The agent's port while the agent restarts.**
  - **Seen:** In the 100 ms before systemd restarts the agent, any guest process can bind
    vsock port 19799, receive the daemon's requests and session nonces, which it cannot use,
    and make new sessions of that machine fail until the machine stops. No way was found for a
    process without root to cause the restart.
  - **Evidence:** [docs/security.md, "Known gaps"](security.md#known-gaps) describes it in
    full; pull request #19, "Review results", SR-M-2.
  - **Phase:** 12b. A systemd socket unit that holds the port across restarts, or an agent
    port below 1024, which changes the protocol.
- **SR-M-3: `docs/security.md` has no entry for the LaunchAgent and `launchctl`.**
  - **Seen:** The document's entry points omit the LaunchAgent's plist and the `launchctl`
    registration, which date from phase 04b.
  - **Evidence:** `docs/security.md`, "Entry points"; pull request #19, "Review results",
    SR-M-3.
  - **Phase:** 12b, as part of the review of `docs/security.md` as a whole.
- **The integration tests' waits count time asleep.**
  - **Seen:** A Mac that sleeps during an integration run fails waits such as
    `waitForPrompt` at once on waking. The final runs of phase 05 used `caffeinate -dims`.
  - **Evidence:** `Tests/mawdTests/MawIntegration.swift:281`; pull request #19, "Known
    limitations and follow-up work".
  - **Phase:** 12b. Measure the waits with `SuspendingClock`, as `Launchctl.waitUntilRemoved`
    does.

## Phase 13: Packaging and release

- **The ad-hoc code signing requirement does not identify maw's builds.**
  - **Seen:** Any local program can claim the identifiers `dev.maw.maw` and `dev.maw.mawd`, so
    the same-user check is the boundary of the XPC service.
  - **Evidence:** [docs/security.md, "The daemon's XPC
    service"](security.md#the-daemons-xpc-service) and [docs/daemon.md, "Tightening in phase
    13"](daemon.md#tightening-in-phase-13).
  - **Phase:** 13, signing with a Developer ID and a team identifier in the requirement.
- **Guest files come from CI artifacts rather than signed releases.**
  - **Seen:** `scripts/fetch-guest.sh` trusts whoever can get a Guest workflow run to succeed.
  - **Evidence:** [docs/security.md, "Guest files from CI"](security.md#guest-files-from-ci).
  - **Phase:** 13, signed guest releases.
- **The daemon is registered with `launchctl bootstrap`, not `SMAppService`.**
  - **Seen:** `mawd install` writes the LaunchAgent's plist and loads it with `launchctl`.
  - **Evidence:** [Decision record 0011](decisions/0011-launchctl-registration.md);
    [docs/daemon.md, "Registration with launchd"](daemon.md#registration-with-launchd).
  - **Phase:** 13, with the app bundle.

## No phase yet

- **The root file system repair command.**
  - **Seen:** maw reports a root file system that fails its check and leaves the disk image
    unchanged except for what `e2fsck -p` repaired. A repair needs e2fsck from a Linux system,
    run on a copy of the image.
  - **Evidence:** [docs/daemon.md, "Known limitations"](daemon.md#known-limitations) describes
    it and the proposed command.
  - **Phase:** None yet. Pull request #19 assigned it to phase 06;
    `prompts/06a-distro-management.md` places it out of the scope of 06a and does not assign it
    to 06b.
- **Guest-opened vsock behavior is measured on one Mac only.**
  - **Seen:** That a guest-opened connection does not stop the machine's vsock traffic when the
    host leaves it unread is measured only on an M1 Pro with macOS 27.0.1. macOS 14 to 26 are
    untested, and Apple documents neither behavior.
  - **Evidence:** [Decision record 0017](decisions/0017-dial-back-for-sessions.md),
    "Consequences". The freeze tests detect a regression wherever
    `scripts/integration-test.sh` runs; CI does not run them.
  - **Phase:** None yet.
- **Discard on macOS 14 is not verified.**
  - **Seen:** Whether the guest's disk accepts discard requests on macOS 14 is not known.
  - **Evidence:** [Decision record 0013](decisions/0013-systemd-and-the-agent.md),
    "Discard".
  - **Phase:** None yet; it needs a Mac running macOS 14.
- **Three product sites block a thread from async code, and `Launchctl.run`'s time limit counts
  time asleep.**
  - **Seen:** Each blocks for milliseconds in practice. A Mac that sleeps during a `launchctl`
    call can exceed the 60-second limit and report `launchctlTimedOut`.
  - **Evidence:** `Sources/mawd/Install.swift:54` and `Launchctl.waitUntilRemoved`, which call
    `launchctl` synchronously; `Sources/MawClient/DaemonClient.swift:133`, which runs
    `launchctl print` on the connect path when the service is not found;
    `Sources/MawDaemonKit/VirtualProvisioningMachine.swift:189`, which writes a provisioning
    step's input; and `Sources/MawXPC/Launchctl.swift:99`, which measures the limit with
    `ContinuousClock`. Pull request #19, "Known limitations and follow-up work".
  - **Phase:** None yet.
- **Sessions opened at once are bounded by 64 connections.**
  - **Seen:** The agent replies `busy` beyond 64 connections, and the host keeps at most 64
    sessions waiting for their dial (`sessionDialBackBusy`). By the code, a 65th session opened
    while 64 are served fails. Bursts of 64 succeed; more is not tested.
  - **Evidence:** `Sources/MawProtocol/ProtocolVersion.swift:29`,
    `Sources/MawVirtualization/DialBackGate.swift:34`.
  - **Phase:** None yet.
- **Virtualization.framework's connection descriptor is not closed on exec.**
  - **Seen:** Nothing, because maw compensates. `VZVirtioSocketConnection.fileDescriptor` had
    `FD_CLOEXEC` clear on all 37 connections of one test run. The daemon keeps a duplicate with
    close-on-exec and closes the framework's connection at once, and its `posix_spawn` calls
    pass `POSIX_SPAWN_CLOEXEC_DEFAULT`.
  - **Evidence:** `Sources/MawVirtualization/VirtualMachine.swift:389`; pull request #19,
    "Known limitations and follow-up work". It is listed because the framework's behavior is
    outside maw's control.
  - **Phase:** None yet.
- **Machine processes from phase 04 outlived their daemons.**
  - **Seen:** Four Virtualization processes started by phase 04's tests remained until the Mac
    restarted. With the current code, a machine's process exits about 110 ms after SIGKILL to
    the daemon or to `mawd debug-boot`. What left them behind is not established.
  - **Evidence:** `scripts/integration-test.sh:165` fails a run that leaves such a process
    behind; pull request #19, "Known limitations and follow-up work".
  - **Phase:** None yet.
- **A Mac locale that glibc lacks falls back to `C.UTF-8`.**
  - **Seen:** With a Mac locale such as `en_TR`, sessions use `C.UTF-8`. Characters type and
    count correctly, but messages and collation are not localized.
  - **Evidence:** `Sources/MawCore/GuestLocale.swift:9`.
  - **Phase:** None yet; the guest has no such locale to generate.
- **Each boot archives about 8 MB of journal.**
  - **Seen:** The journal grows by about 8 MB per boot; the cause is not established. It is
    capped at 256 MB.
  - **Evidence:** `Sources/MawDaemonKit/ProvisioningScript.swift:123` sets the cap; pull
    request #19, "Known limitations and follow-up work", records the growth.
  - **Phase:** None yet.
- **The password's copies in memory are not wiped.**
  - **Seen:** Swift strings cannot be wiped, so copies may remain in the memory of `maw` and
    `mawd` until it is reused.
  - **Evidence:** [docs/security.md, "The password"](security.md#the-password).
  - **Phase:** None yet.
- **The cost of the input window is not measured on an idle Mac.**
  - **Seen:** The cost of 1.7 % was measured while the Mac's load average was between 2 and 8.
    The record planned a repeat on an idle Mac before phase 05 was complete; it was not
    repeated, because the build before the window cannot use the current guest files without
    replacing the installed daemon's.
  - **Evidence:** [Decision record 0016](decisions/0016-input-window.md), "The window's size and
    the report's form"; pull request #19, "Throughput and the input window".
  - **Phase:** None yet.
- **The entries of `docs/daemon.md`, "Known limitations", that name no phase.**
  - **Seen:** A connection that arrives while an idle daemon exits fails with
    `daemonUnreachable`. launchd's `ThrottleInterval` delays a restart within 10 seconds of a
    start. The daemon does not detect a client of the same interface version from another
    build. The installer refuses the names `initramfs`, `mawd`, and `debug-boot-console`.
  - **Evidence:** [docs/daemon.md, "Known limitations"](daemon.md#known-limitations).
  - **Phase:** None yet.

## Accepted trade-offs

Deliberate choices that a decision record explains and that no phase plans to change.

- **Full disk synchronization by default.** `.full` makes `apt-get install build-essential`
  4.2 times slower than `.fsync` (17.58 s against 4.20 s), in exchange for data that survives
  a crash or power loss of the Mac.
  [Decision record 0013](decisions/0013-systemd-and-the-agent.md). Phase 12 adds a setting for
  `.fsync` (above); the default stays.
- **OpenPGP is not checked at installation.** The catalog pins each image's SHA-256, so maw
  needs no OpenPGP implementation, at the cost of a new release of maw for a new image.
  [Decision record 0012](decisions/0012-ubuntu-image.md), "Trade-offs".
- **Output from the guest is slower on guest-opened connections.** 1.3 GB of output took a
  median of 2,996 ms with the dial-back against 2,455 ms with host-opened sessions (22 %).
  The cost lies in Virtualization.framework's transport, and no buffer or write size closed
  it. [Decision record 0017](decisions/0017-dial-back-for-sessions.md), "What it costs".
- **Guest root can make session opens fail.** While a session opens, a guest process with
  `CAP_NET_BIND_SERVICE` can hold the places for unauthenticated connections or bind every
  source port below 1024. It cannot obtain a session without the nonce, and the failure is
  limited to its own machine. [Decision record 0017](decisions/0017-dial-back-for-sessions.md),
  "Consequences";
  [docs/security.md, "The dial-back listener"](security.md#the-dial-back-listener).
- **Ctrl-C typed in a terminal session is a byte of input.** As in ssh, it stays behind input
  that the guest has not read. Only signals sent to maw and window sizes overtake input.
  [Decision record 0016](decisions/0016-input-window.md), "Consequences".
- **The input window costs about 1.7 % of input throughput over vsock**, and the agent holds
  up to 1 MiB of input per session, against 256 KiB before.
  [Decision record 0016](decisions/0016-input-window.md). The repeat of the measurement on an
  idle Mac is listed under "No phase yet".
- **Guest files and the host must come from the same build.** A host and guest files from
  different builds fail at session open with `guestAgentVersionMismatch` (protocol version 3,
  `Sources/MawProtocol/ProtocolVersion.swift:7`). `scripts/fetch-guest.sh` installs guest
  files built from the same commit. [Decision record 0016](decisions/0016-input-window.md),
  "Consequences".
