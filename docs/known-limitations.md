# Known limitations

This file lists every known limitation and every piece of deferred work, grouped by the phase
that owns it. Every pull request adds the items it defers and removes the items it resolves.

Each item states what a user or a developer sees, the evidence, and the owning phase. Where
another document already describes an item in full, the item links to it. Evidence refers to
files on `main`, to pull request descriptions, and to review IDs such as CR-8, which pull
request #19 lists under "Review results". Commits from the branch of pull request #19 are not
cited, because that pull request was squash-merged and its branch commits are not reachable
from `main`.

## Phase 06b: Distro removal and transfer

- **No `maw --unregister`, `maw --export`, or `maw --import`.**
  - **Seen:** The three commands fail with `notImplemented`: "--unregister is not implemented
    yet; phase 06b adds it." A distribution is removed by hand: `maw --terminate <name>`, then
    deleting its directory.
  - **Evidence:** `Sources/maw/Action.swift:29`; pull request #19, "Known limitations and
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
- **The `maw --help` example of `--export` names the alias `Ubuntu`.**
  - **Seen:** `maw --help` shows `maw --export Ubuntu ubuntu.tar`. `Ubuntu` is a catalog alias,
    not an installed name, and phase 06a does not accept aliases where a command needs an
    installed distribution.
  - **Evidence:** `Sources/maw/Maw.swift:45`; pull request #22, "Known limitations and
    follow-up work".
  - **Phase:** 06b, which implements `--export` and gives the example an installed name.
- **A watcher does not notice a distribution removed by hand while no machine runs.**
  - **Seen:** A distribution whose directory is deleted by hand stays in the snapshots of
    `watchDistributions` until the next snapshot: a sample of a running machine, a state change,
    an installation, or a new default.
  - **Evidence:** `FigureSampler.snapshot(after:)` reads the installed distributions only when
    the sequence number has grown (`Sources/MawDaemonKit/FigureSampler.swift`); nothing watches
    the distributions directory.
  - **Phase:** 06b, whose `maw --unregister` removes a distribution through the daemon and can
    publish a new snapshot.

## Phase 07: File sharing and paths

- **Shells with a working directory have no logind session.**
  - **Seen:** A login shell started with `--cd` skips `runuser -l`, so it is not registered
    with `systemd-logind`. Once phase 07 sends the Mac's working directory with every call, no
    shell would be registered, and `XDG_RUNTIME_DIR` and `systemctl --user` would depend on
    linger alone.
  - **Evidence:** [Decision record 0015](decisions/0015-sessions-through-pam.md), "Consequence
    for phase 07", which lists the options.
  - **Phase:** 07.
- **A `distribution:<name>` setting is shown in the pane without a check.**
  - **Seen:** When `defaultProfile` in `~/Library/Application Support/maw/settings.json` names
    a distribution that is not a valid name, ⌘T opens the default distribution, and the pane's
    notice includes the stored text unchanged. The pane passes the notice to the terminal
    emulator, so control characters in the text take effect there. The file is the user's own,
    so this matters only if the file share lets the guest write `~/Library`.
  - **Evidence:** `Profile.makeSession(localShell:cores:)` in
    `App/MawTerminalKit/Sources/MawTerminalKit/Session/Profile+Session.swift`, whose notice
    takes the name as the setting gives it; `PaneController.write(_:style:)`. Pull request
    #26, security review.
  - **Phase:** 07, if its file share exposes `~/Library` to the guest: show only a valid
    distribution name, or remove control characters before the notice is written.

## Phase 08: Networking

- **The first DNS query after the DHCP lease is not answered.**
  - **Seen:** In a distribution machine, the first DNS query that `systemd-resolved` sends to
    the NAT's server (192.168.64.1), within about 20 ms of the DHCP lease, receives no answer.
    The lookup completes only after `systemd-resolved` times that query out at about 5.0 s and
    asks the IPv6 link-local server instead, so a lookup that begins in about the first 5.5
    seconds of a boot can take about 5 s. Its effect on a user's first lookup after a cold start
    is not measured.
  - **Evidence:** Part 4b of phase 06a, on 2026-11-08 (M1 Pro, macOS 27): a temporary
    integration test on test distributions, each boot's journal (`-o short-monotonic`), and in
    some passes `SYSTEMD_LOG_LEVEL=debug` for `systemd-resolved` and `systemd-timesyncd`. The
    lookup observed was `systemd-timesyncd`'s resolution of `ntp.ubuntu.com`, which was usually
    still pending in about the first 5.5 seconds of a boot; in 20 boots stopped at once after
    systemd reported `running`, all 20 had it pending at the stop. Under `.fsync`
    synchronization, 5 of 10 instrumented boots tried to resolve before the network was up and
    failed at once, so no lookup was pending. Why the first query is not answered is not
    determined.
  - **Resolved part:** Shutdowns soon after a boot waited 5 s for `systemd-timesyncd` while this
    lookup was pending, and fell back to Virtualization.framework's stop request. [Decision
    record 0013](decisions/0013-systemd-and-the-agent.md), item 7 (pull request #23), orders
    `systemd-timesyncd` after `systemd-resolved`, which removes that wait without depending on
    this item; the decision record lists the measurements.
  - **Phase:** 08, together with DNS under VPNs.

## Phase 11c: Live figures on the distributions screen

- **The distributions screen shows no figures, details box, or memory chart.**
  - **Seen:** The MEMORY, CPU, DISK, UPTIME, and KERNEL cells of every distribution are empty,
    and the details box and the memory chart do not appear. The screen shows the name, the
    state, and the default marker, which is all that `listDistributions` reports.
  - **Evidence:** `DaemonDistributions.make(entry:isDefault:)` in
    `App/MawTerminalKit/Sources/MawTerminalKit/Distributions/Distributions.swift` sets only
    those three; `DistributionsContent` shows the two boxes once a distribution has details or
    a memory history.
  - **Phase:** 11c, which fills the fields of `DistributionInfo` from the daemon.
- **An open distributions screen does not follow machines that it did not start or stop.**
  - **Seen:** The screen reads the daemon's list when it becomes the selected tab, after each
    of its actions, and when a tab opened from it has started. A machine that starts or stops
    for another reason, such as a tab opened in another window, `maw` in a terminal, or the
    idle stop, keeps its earlier state on a screen that stays in view, until the screen is
    selected again.
  - **Evidence:** `WindowModel.tabs` and `WindowModel.perform(_:)` in
    `App/MawTerminalKit/Sources/MawTerminalKit/Window/WindowModel.swift`; pull request #26,
    code review. The list is never polled, as phase 11b's plan requires.
  - **Phase:** 11c, whose live figures need the screen to follow the daemon while it is in
    view.

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
  - **Related:** The distribution figures' host memory, the footprint of the machine's process,
    does not fall when the guest frees memory, while MEMORY, from the guest, does. [Decision
    record 0020](decisions/0020-distribution-figures.md), "Evidence".
- **The distribution figures name the default user from `distro.json` only.**
  - **Seen:** `watchDistributions` reports the user that the installation recorded, even when
    `/etc/maw.conf` in the distribution names another.
  - **Evidence:** `FigureSampler.figures(_:)` reads `DistroMetadata.defaultUser`
    (`Sources/MawDaemonKit/FigureSampler.swift`).
  - **Phase:** 12, which reads `/etc/maw.conf`'s setting.

## Phase 12b: Hardening

- **Two of phase 11c's speed targets are missed: each sample opens a connection of its own and
  reads the guest's figures.**
  - **Seen:** In the owner's official measurements, while a client watches one running
    distribution, the guest agent's CPU time per sample was 1.473 ms (95th percentile 1.687 ms)
    against a target of 0.5 ms, and the machine's process cost 0.357 % of one core (95th
    percentile 0.431 %) above its unwatched cost over 60 seconds against a target of 0.2 %. Of a
    sample, the fixed cost of a request on a host-opened connection, measured with `info`, is
    0.569 ms of the agent and 2.900 ms of the machine's process; reading `/proc` and calling
    `getifaddrs` add 0.90 ms and 1.2 ms. The development measurements gave 1.155 ms and 0.372 %,
    with a fixed cost of 0.821 ms and 3.20 ms. The owner accepted both misses on 2026-11-12 and
    kept this item on 2026-11-13 after the official measurements: the cost is a fraction of one
    percent of one core, only while a distributions screen is visible, and zero otherwise.
  - **Evidence:** [Decision record 0020](decisions/0020-distribution-figures.md), "What it
    costs": the official measurements of 2026-11-13 at `6829e27` and `694eb11`, after a restart
    and with only Terminal open, and the development measurements of 2026-11-12 at load averages
    from 2.1 to 6.6.
  - **Phase:** 12b. Reusing one connection per run, about 80 to 100 lines, would remove most of
    the fixed cost; it changes the protocol and needs new guest files. By the official figures
    that is 71 % of the machine's process's time per sample but only 39 % of the agent's, whose
    larger part is the reading of the figures. Where that time goes in the agent is not
    measured.
- **The dial-back exchange costs about 1.8 ms per session.**
  - **Seen:** Warm `maw -e true` measured 33 ms against 31 ms with host-opened sessions, within
    the target of 50 ms.
  - **Evidence:** [Decision record 0017](decisions/0017-dial-back-for-sessions.md), "What it
    costs" and "Consequences"; pull request #19, "Before and after the dial-back".
  - **Phase:** 12b. Two options, neither built or measured: a persistent request connection
    per machine, estimated to save 0.7 ms and requiring a protocol change; or reused threads in
    the daemon and the agent, estimated to save 0.1 to 0.3 ms without a protocol change.
- **The warm prompt runs close to its limit of 150 ms.**
  - **Seen:** `DistributionIntegrationTests.measuresWarmPrompt`, added in phase 05, checks the
    median of five warm starts of `maw` to a prompt against the limit of 150 ms that
    `prompts/05-distro-install.md` sets. In the full integration run at `8dc2d12` (pull request
    #29) it measured a median of 155 ms (165, 120, 155, 141, 167 ms) and failed; the run's load
    average was 4.28 at its start and 3.87 at its end. Run alone twice afterwards, it passed
    with medians of 147 and 142 ms, at load averages of 3.51 and 3.66 at their starts.
  - **Evidence:** Pull request #29, "Verification". The limit is unchanged.
  - **Phase:** 12b. Where the time to the prompt goes on a warm machine is not measured; the
    dial-back exchange above is one known part of it.
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
    (90 columns), the message of `installationOutcomeUnknown` (184 columns with
    `Ubuntu-24.04`), and, with the name `maw-capture`, the suggestion of
    `distributionAlreadyInstalled` (81).
  - **Evidence:** `Sources/maw/InstallCommand.swift:372`, `Sources/MawCore/MawError.swift:383`;
    pull request #19, "Known limitations and follow-up work". Seven messages have an 80-column
    test, wrapped by hand where needed: the cancellation, the password with a control
    character, the unconfirmed cancellation, `machineStopped` with the daemon's own reasons,
    `distributionNotInstalled`, and the suggestion of `installationOutcomeUnknown`
    (`Tests/mawTests/FailureTests.swift`), and `sessionConnectionEnded`
    (`Tests/MawCoreTests/MawErrorTests.swift:275`).
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
    `--terminate` does not depend on this fix: for a machine that is starting, it waits for the
    start to finish and then stops the machine ([docs/daemon.md, "Terminating one
    distribution"](daemon.md#terminating-one-distribution)).
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
- **Some shutdowns soon after a boot take about 2.6 s.**
  - **Seen:** A few clean shutdowns through the agent, of machines that had booted shortly
    before, took about 2.6 s, against about 0.3 to 1.0 s for the others. They stayed within the
    daemon's limit (`VirtualMachineHandle.stopTimeout`) and did not fall back to
    Virtualization.framework's stop request. The cause is not measured.
  - **Evidence:** Phase 06a on 2026-11-08 (M1 Pro, macOS 27.0.1): two terminates of 2,676 ms,
    in the full integration run of part 5, and 2,564 ms, in the owner's third check, about 10 s
    after that machine's boot; and one shutdown of 2,683 ms in part 4c. Pull request #22,
    "Notes for reviewers".
  - **Phase:** 12b. Measure where these shutdowns spend the time, for example in each boot's
    journal.
- **Two dial-back errors suggest `maw --shutdown`.**
  - **Seen:** `sessionDialBackFailed` and `sessionDialBackMissing` suggest restarting every
    virtual machine with `maw --shutdown`, where `maw --terminate <name>` would restart only
    the one affected. The errors carry no distribution name.
  - **Evidence:** `Sources/MawCore/MawError.swift:488` and `:492`; pull request #22, "Known
    limitations and follow-up work".
  - **Phase:** 12b. Carry the distribution's name in both errors, which changes `MawError`
    and the daemon interface, and suggest `maw --terminate <name>`.
- **`RootFileSystemIntegrationTests` stops every machine.**
  - **Seen:** Its `installAndStop` runs `maw --shutdown`, which stops every machine of the test
    daemon, where the other integration tests stop only their own distribution with
    `maw --terminate`.
  - **Evidence:** `Tests/mawdTests/RootFileSystemIntegrationTests.swift:106`;
    `MawIntegration.remove` in `Tests/mawdTests/MawIntegration.swift` uses `maw --terminate`.
    Pull request #22, "Known limitations and follow-up work".
  - **Phase:** 12b. Stop only the installed test distribution, with `maw --terminate <name>`.
- **A tab ended by the distributions screen's stop names `maw --terminate` as the reason.**
  - **Seen:** After `s` on the distributions screen stops a distribution, each of its tabs
    shows "The virtual machine 'Ubuntu-24.04' stopped:" followed by "maw --terminate was
    run.", although the user ran no command.
  - **Evidence:** `DaemonService.terminateReason` in
    `Sources/MawDaemonKit/DaemonService.swift`; the `terminate` request carries no reason of
    its client.
  - **Phase:** 12b: the reason names what stopped the machine, such as the terminal app.
- **The terminal app's local shell start waits on the main thread until the shell runs.**
  - **Seen:** `maw_terminal_spawn` forks, and the parent reads the child's report pipe until
    `execve` closes it. Before `execve`, the child changes to the start directory, the home
    directory. If that `chdir` blocks, for example on a network home directory whose server
    does not answer, the app's main thread waits with it, and every window stops responding
    until it returns. SwiftTerm's `forkpty`, which `main` used, did not wait for the child.
  - **Evidence:** `App/MawTerminalKit/Sources/CMawTerminal/terminal.c`, `maw_terminal_spawn`
    and `start_child`; `PseudoTerminalProcess.init`, called from `LocalShellSession.start` on
    the main actor. Found by reading the code; not reproduced.
  - **Phase:** 12b. Wait for the report on another thread, and report a failure to start
    through `session(_:didFailWith:)`.
- **A login shell that runs `exec` with another shell asks before closing.**
  - **Seen:** A user whose `.bashrc` runs `exec zsh`, for example, is asked "zsh is still
    running and will be ended." when closing the tab at the prompt. The agent reports a login
    shell whose command name differs from the account's shell as the program it has run with
    `exec`, as the owner decided, so that `exec vim` still asks.
  - **Evidence:** `Sources/MawAgentKit/ForegroundProbe.swift`, `execedProgram`; pull request
    #25, code review. `MawAgentKit` is a Guest workflow path, which pull request #25 does not
    change after its first part.
  - **Phase:** 12b. Treat a command name listed in the guest's `/etc/shells` as a shell.
- **Two copies of a thread that writes queued input.**
  - **Seen:** Developers maintain the same condition-variable queue, drained by a thread of
    its own, twice. They already differ: one drops pending input when it finishes, and one
    waits for room on a non-blocking descriptor. There is no effect on users.
  - **Evidence:** `InputForwarder` in `Sources/MawClient/DistributionSession.swift` and
    `TerminalInput` in
    `App/MawTerminalKit/Sources/MawTerminalKit/Session/PseudoTerminalProcess.swift`; pull
    request #25, code review.
  - **Phase:** 12b, a shared type in `MawClient` that takes the write as a closure.
- **The terminal view draws output at about 25 MB/s.**
  - **Seen:** `head -c 1000000000 /dev/zero | base64`, 1.35 GB of output, takes about 53 s in
    a tab of the optimized app, and about 7 minutes by the rate of an unoptimized build such as
    Xcode's Debug configuration. The app stays responsive and its memory bounded throughout,
    because output is read only as fast as the view consumes it.
  - **Evidence:** Pull request #25, "Speed targets" (2026-11-10, a restarted, idle Mac on AC
    power): medians of 5 runs of 53.0 s in a Linux tab and 53.7 s in a local tab, about 25.5
    and 25.2 MB/s; in an unoptimized build, 100 MB of input (135 MB of output) took 41.8 s and
    41.5 s, about 3.2 MB/s. The Linux path itself carries 1.3 GB into `cat > /dev/null` at
    262 MB/s in the same integration run, and local and Linux tabs run at the same rate, so the
    limit is in the terminal view's parsing and drawing, not in the Linux path. Where the time
    goes inside the view has not been profiled.
  - **Phase:** 12b. Profile the terminal view's parsing and drawing with Instruments during a
    flood, and reduce the work per byte where the profile shows it.

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
- **The terminal app's suggestions for three errors name development steps.**
  - **Seen:** For `clientSignatureRejected` and `daemonVersionMismatch`, the app suggests
    building the app with Xcode and the daemon from the same commit and running
    `mawd install`; for `virtualizationEntitlementMissing`, signing the daemon with
    `scripts/sign-dev.sh` and running `mawd install`. A user of a signed app has neither Xcode
    nor the repository's scripts.
  - **Evidence:** `LinuxSession.suggestion(for:)` in
    `App/MawTerminalKit/Sources/MawTerminalKit/Session/LinuxSession.swift`.
  - **Phase:** 13, which bundles the daemon with the app and words these suggestions for a
    signed app, such as reinstalling the app.
- **The daemon is registered with `launchctl bootstrap`, not `SMAppService`.**
  - **Seen:** `mawd install` writes the LaunchAgent's plist and loads it with `launchctl`.
  - **Evidence:** [Decision record 0011](decisions/0011-launchctl-registration.md);
    [docs/daemon.md, "Registration with launchd"](daemon.md#registration-with-launchd).
  - **Phase:** 13, with the app bundle.

## No phase yet

- **`maw` shows no distribution figures.**
  - **Seen:** `maw --list --verbose` keeps the columns of `wsl.exe --list --verbose`, and
    `maw --status` shows no memory, CPU, or disk per distribution. Only the terminal app's
    distributions screen asks for them.
  - **Evidence:** [Decision record 0020](decisions/0020-distribution-figures.md);
    `prompts/11c-distribution-figures.md`, "Out of scope".
  - **Phase:** None yet; figures would go into `maw --status`, maw's own command.
- **The daemon builds a snapshot more often than needed with several distributions or
  watchers.**
  - **Seen:** Each sampled distribution publishes a snapshot of its own, so one interval with
    three running distributions wakes each watcher three times. Watchers that a change wakes
    together each build the same snapshot once. Each build reads every `distro.json` and the
    manifest and `stat`s every disk image. Sampling stays once per machine per interval.
  - **Evidence:** `FigureSampler.finish` and `FigureSampler.snapshot(after:)` in
    `Sources/MawDaemonKit/FigureSampler.swift`; pull request #29, code review. Not measured with
    more than one distribution; the terminal app holds one watch.
  - **Phase:** None yet. Publishing one snapshot per interval, and building it once per change,
    would remove the repetition.
- **`maw` suggests `--create-disk` when an installed distribution's disk image is missing.**
  - **Seen:** `maw -d <name>` reports `diskImageNotFound` with the suggestion "Pass
    --create-disk <size> to create it as a sparse image.", an option of `mawd debug-boot` that
    neither `maw` nor the terminal app has. The app shows its own suggestion instead: restore
    the image from a backup, or remove the distribution and install it again.
  - **Evidence:** `Sources/MawCore/MawError.swift`, `recoverySuggestion` for
    `diskImageNotFound`; `App/MawTerminalKit/Sources/MawTerminalKit/Session/LinuxSession.swift`,
    `suggestion(for:)`. `MawCore` is a Guest workflow path, which phase 11b does not change after
    its first part.
  - **Phase:** None yet; a `fix/` branch gives the error a suggestion for `maw` that depends on
    where it arises.
  - **Related:** The app words its own suggestion for twelve errors whose suggestion in
    `MawCore` names a step of `maw` (`LinuxSession.suggestion(for:)`), so each such error has
    two suggestions to keep in step. The same `fix/` branch can give `MawError`'s suggestions
    the context in which they are shown, `maw` or the app, so that `MawCore` holds both.
  - **Related:** The distributions screen shows maw's own suggestion for every error, as
    `maw` prints it (`runtimeErrorText`), in its table when the daemon cannot be asked and in
    the alert of an action that failed. For `clientSignatureRejected` and
    `daemonVersionMismatch` it therefore names `scripts/sign-dev.sh` and `mawd install` rather
    than the app's build, and for `launchctlTimedOut` "Run the command again", where the
    screen's retry is ⌘⇧L or the key of the action. The same `fix/` branch can word these.
- **The distributions screen's stop does not order its two requests.**
  - **Seen:** After `s`, the screen sends `terminate` and reads the list while the guest shuts
    down, so that the row reads stopping. The list's request opens a connection of its own
    first, so it usually reaches the daemon after `terminate`, but nothing orders the two. If
    it arrived first, the row would read running until the stop completed, and then stopped.
    This has not been observed.
  - **Evidence:** `DaemonDistributions.stop(_:)` in
    `App/MawTerminalKit/Sources/MawTerminalKit/Distributions/Distributions.swift`; pull
    request #26, code review. `terminate` is answered only once the machine has stopped.
  - **Phase:** None yet. Ordering the two needs the daemon to report that a stop has begun,
    which changes the daemon interface.
- **Linux tabs show no working directory.**
  - **Seen:** A Linux tab's label and the key hint bar show the distribution's name without
    the working directory that a local tab shows. The app takes a Linux session's directory
    only from OSC 7, and never polls the guest; Ubuntu's bash does not send OSC 7.
  - **Evidence:** `LinuxSession.terminalReportedWorkingDirectory(_:)` and
    `refresh(isVisible:)` in
    `App/MawTerminalKit/Sources/MawTerminalKit/Session/LinuxSession.swift`;
    `prompts/11b-linux-sessions.md`, "Out of scope".
  - **Phase:** None yet; phase 07, which translates working directories, is a candidate, for
    example by having the distribution's shell send OSC 7.
- **A Linux session does not reconnect after the daemon or the machine restarts.**
  - **Seen:** The pane shows maw's message and suggestion, such as `machineStopped` or
    `daemonConnectionLost`, and offers a new session, which Enter starts. The shell and its
    programs in the guest are not recovered.
  - **Evidence:** `DistributionSession`'s endings (`docs/daemon.md`, "The client library");
    `prompts/11b-linux-sessions.md`, "Out of scope".
  - **Phase:** None yet.
- **Foreground program names are at most 15 bytes.**
  - **Seen:** A close question names a program by its command name from
    `/proc/<pid>/comm`, which Linux truncates to 15 bytes (`TASK_COMM_LEN`), so
    `systemd-journald` would appear as `systemd-journal`.
  - **Evidence:** `Sources/MawAgentKit/ForegroundProbe.swift`; `docs/protocol.md`, the
    `foregroundProgram` message.
  - **Phase:** None.
- **During an output flood the foreground answer can miss its 500 ms.**
  - **Seen:** The agent's answer travels on the session's connection behind the output that the
    app has not read yet, and the app reads only as fast as the terminal view draws. During a
    flood, closing a Linux tab can therefore say "A program may be running in Ubuntu-24.04,
    which did not answer within 500 ms." rather than name the program. This follows from the
    protocol's design and is not measured.
  - **Evidence:** `docs/protocol.md`, the foreground messages; `OutputPump` in
    `App/MawTerminalKit/Sources/MawTerminalKit/Session/OutputPump.swift`;
    `WindowModel.foregroundTimeout`.
  - **Phase:** None. The question still asks, so nothing closes without the user's consent.
- **Tests fill the cooperative pool for several seconds at the start of the general group.**
  - **Seen:** In CI, where `swift test` runs every test of the general group in one process,
    synchronous tests that are CPU-bound or that block occupy every thread of the cooperative
    pool for about 3 to 10 seconds after the group starts. The CPU-bound ones are mainly the
    argument parser's tests in a debug build (`ValidationTests`, `DebugBootParsingTests`),
    with `ImageCacheTests`, `DistributionStoreTests` and `RootCheckScriptTests`. The blocking
    one was `PeerRequirementTests.acceptsOnlyMawsIdentifiers`, which waited for `codesign`
    with `waitUntilExit()` in seven parallel cases; it now suspends instead, but `codesign`
    itself still competes for the CPU. While the pool is full, no other task in the process
    starts or resumes, so nearly every test that started before the stall reports its length
    as its duration. A test with a wall-clock deadline that runs on a thread of its own while
    its counterpart needs the pool can therefore fail, as
    `HandshakeTests.exchangesMatchingVersions()` did until its peer moved to a thread of its
    own (CI runs 42512716425, 42574910845, 42644895862, 42807002034 and 42834158953, each
    passing on a re-run). Any future test with that pattern can fail the same way. A deadline
    measured by a task, such as a `Task.sleep`, is delayed by the same stall and does not
    expire early.
  - **Evidence:** In each of those runs and in the passing run 42516767842 of `main`, tests
    from unrelated modules finish with the same duration to the millisecond, for example
    `reportsTheHostLimits()` at 5.373 s with about 60 others in run 42574910845, and the test
    events stop for seconds while tests are still being started. Locally, with the toolchain
    of CI's layout reproduced by `swift test --build-system native` (one test bundle, one
    process), the same signature appears: the stall lasts about 1.9 s on an idle 8-core Mac,
    2.5 s with 8 busy processes, 3.2 s with 16, and about 6 s with
    `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, which narrows the pool to one thread. The last
    condition reproduced the handshake failure, and timing probes showed the host taking its
    deadline at +0.0001 s and the peer's thread starting at +5.2 s. Samples of the local
    process during the stall show every pool thread running the tests named above. A thread
    sample from the CI runner itself is missing; the CI evidence is the log signature only.
    The default local build (`swiftbuild`, one test bundle per target) runs each target in a
    process of its own, so a plain local `swift test` shows a much shorter stall.
  - **Phase:** None; a `fix/` branch. Run the CPU-bound and blocking synchronous tests off the
    pool or in a group of their own, and keep tests with wall-clock deadlines independent of
    the pool, as `scripts/test-groups.sh` and `docs/decisions/0018-test-groups.md` do for
    load and latency. A helper in `Sources/MawProtocol/Threads.swift` that starts a thread at
    once and returns its result to await later would keep that rule in one place instead of
    a comment in each test; `Sources/MawProtocol` is a Guest workflow path, so the branch that
    fixed the handshake test changed test code only.
- **CI does not show SwiftUI behavior that begins with the macOS 27 SDK.**
  - **Seen:** SwiftUI chooses some behavior by the SDK of the running program, which under
    `swift test` is the test runner of the selected Xcode, not the test bundle
    ([decision record 0019](decisions/0019-swiftui-behavior-in-app-tests.md)). The `swift build`
    test bundle's `sdk 14.0` does not matter. The command palette's query field writes its
    unchanged text back when it receives the focus, with any SDK, and also whenever the view
    updates when the runner was linked with the macOS 27 SDK or later, on macOS 27.
    `CommandPaletteWindowTests` fails on both writes without the check in
    `WindowModel.setPaletteQuery(_:)`. CI's runner has macOS 26.7.2 and Xcode 26.6, whose
    macOS SDK is 26.5 and whose test runners record SDK 26.4 (run 43029390677), so CI catches
    only the first write: without the check, CI reports that the
    theme list opens on its first row, but not that each arrow is undone. On the owner's Mac,
    with Xcode 27.2, the test catches both.
  - **Evidence:** CI run 43027801133, of a deleted branch whose only change was the reverted
    check, on top of the branch that added the test: the "Terminal app" job printed
    `macOS SDK 26.5`, and the window test failed with 7 issues. The list opened on
    "maw Default" instead of "Dracula", and ↓ ↓ ↑ then moved to Catppuccin Mocha, Dracula, and
    Catppuccin Mocha. Locally, with the runner's build version rewritten by `vtool`, each arrow
    was undone with the SDK 27.0 and 27.2, and not with 15.0, 26.0, or 26.5.
  - **Phase:** None. It resolves when CI's runner has macOS 27 and an Xcode with the macOS 27
    SDK; until then, a change to the palette's SwiftUI views needs the app package's tests run
    on such a Mac.
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
  - **Seen:** With a Mac locale such as `en_TR`, sessions of `maw` and the terminal app's Linux
    sessions use `C.UTF-8`. Characters type and count correctly, but messages and collation are
    not localized. The app's Linux sessions first take the app's own `LC_ALL`, `LC_CTYPE`, or
    `LANG` when macOS accepts it, as its local shell does; an app started from a terminal that
    sets `LC_CTYPE=UTF-8`, a name that exists only on macOS, therefore also falls back to
    `C.UTF-8`, rather than to the Mac's language and region.
  - **Evidence:** `Sources/MawCore/GuestLocale.swift:9`; `LinuxSession.guestLocale` in
    `App/MawTerminalKit/Sources/MawTerminalKit/Session/LinuxSession.swift`, which follows
    `ShellLocale` as `prompts/11b-linux-sessions.md` requires.
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

- **CPU and host memory depend on an undocumented process.** The daemon finds a machine's
  `com.apple.Virtualization.VirtualMachine` process by the disk image it has open. If Apple
  changes the process model, the lookup finds nothing and the two figures stay empty; they are
  never wrong, and the integration tests fail.
  [Decision record 0020](decisions/0020-distribution-figures.md), "Evidence".

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
  different builds fail at session open with `guestAgentVersionMismatch` (protocol version 5,
  `Sources/MawProtocol/ProtocolVersion.swift:7`). `scripts/fetch-guest.sh` installs guest
  files built from the same commit. [Decision record 0016](decisions/0016-input-window.md),
  "Consequences".
