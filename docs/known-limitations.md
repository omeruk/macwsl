# Known limitations

This file lists every known limitation and every piece of deferred work, grouped by the phase
that owns it. Every pull request adds the items it defers and removes the items it resolves.

Each item states what a user or a developer sees, the evidence, and the owning phase. Where
another document already describes an item in full, the item links to it. Evidence refers to
files on `main`, to pull request descriptions, and to review IDs such as CR-8, which pull
request #19 lists under "Review results". Commits from the branch of pull request #19 are not
cited, because that pull request was squash-merged and its branch commits are not reachable
from `main`.

## Phase 08: Networking

- **`localhost` forwarding was not checked with a VPN connected.**
  - **Seen:** Part 1 of phase 08 measured forwarding without a VPN; the owner chose not to run
    the VPN check. Forwarding uses vsock, not the NAT network, so a VPN is not expected to
    affect it, but that is not measured.
  - **Evidence:** [Decision record 0023](decisions/0023-localhost-forwarding.md), "What the
    platform does".
  - **Phase:** 08, pull request B, whose acceptance includes an owner check with a VPN.

## Phase 12: Configuration and lifecycle

- **The share of the home directory cannot be turned off.**
  - **Seen:** Every distribution has the owner's home directory at `/mnt/mac`, read-write, as
    the owner decided for phase 07. No setting turns it off, makes it read-only, or limits it
    to chosen folders, for all distributions or for one.
  - **Evidence:** [Decision record 0021](decisions/0021-mac-share.md);
    `prompts/07-file-sharing-and-paths.md`, "The owner's decisions", item 3.
  - **Phase:** 12, a `.mawconfig` setting.

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

- **`localhost` forwarding cannot be turned off.**
  - **Seen:** Every running distribution forwards its listening TCP ports to the Mac's
    loopback addresses. No setting turns it off, for all distributions or for one.
  - **Evidence:** [Decision record 0023](decisions/0023-localhost-forwarding.md);
    `prompts/08-networking.md`, "Out of scope".
  - **Phase:** 12, a `.mawconfig` setting.
- **DNS through the Mac cannot be turned off.**
  - **Seen:** Every distribution's DNS queries are answered by the Mac's resolver through the
    agent. No setting returns a distribution to the NAT network's server, for all
    distributions or for one.
  - **Evidence:** [Decision record 0024](decisions/0024-dns-through-the-mac.md);
    `prompts/08-networking.md`, "The owner's decisions", item 3.
  - **Phase:** 12, a `.mawconfig` setting.
- **A forwarded connection does not keep a machine running.**
  - **Seen:** The machine's idle stop counts sessions only. A server started with `nohup` or
    as a systemd service, whose session has ended, is forwarded only until the machine stops,
    60 seconds after its last session, even while a Mac program is connected to it; the
    connection then ends.
  - **Evidence:** `MachineRegistry.scheduleIdleStopIfUnused` counts the daemon's leases;
    `prompts/08-networking.md`, "Out of scope".
  - **Phase:** 12, with idle shutdown.

- **A file that a session writes in `/tmp` early in a boot is deleted.**
  - **Seen:** Sessions do not wait for the boot, and the agent accepts them about 0.3 s into
    it. Ubuntu's `systemd-tmpfiles-setup.service` runs a little later, at 0.37 to 0.44 s in
    three cold starts, and empties `/tmp` under the rule `D /tmp 1777 root root 30d`. In each of
    the three, a file that the first session wrote in `/tmp` was gone 4 s later. A command
    run on a stopped distribution, such as `maw -- sh -c 'make > /tmp/log'`, can therefore
    lose what it writes there. `/var/tmp` and the home directory are not affected.
  - **Evidence:** Found during phase 08 pull request A, when the 1 GiB measurement's file
    disappeared in 3 of 17 runs; the test daemon's log showed its session opening as the
    machine became ready. [Decision record 0013](decisions/0013-systemd-and-the-agent.md),
    item 3, "Sessions do not wait for the boot". The forwarding tests now write to `/var/tmp`.
  - **Phase:** 12. Holding sessions until `systemd-tmpfiles-setup.service` has finished would
    resolve it at a cost to the time to a prompt that has not been measured.

## Phase 12b: Hardening

- **A link that another network manager configures can keep the NAT network's DNS server.**
  - **Seen:** maw turns off the DHCP and router-advertised DNS servers through a drop-in for
    every `.network` file of systemd-networkd. A link that NetworkManager or another manager
    configures, as in an imported archive that enables one, gives systemd-resolved its own
    server, and queries can reach it as well as the agent's. The agent writes a line to the
    console log naming every such server (`dns: systemd-resolved also has the DNS server …`),
    so it is never used without a trace, but it is not removed. The line names the servers in
    systemd-resolved's `resolv.conf`, which lists a link's servers only while the link is a
    default route; a server of a link that is not one, but has routing domains, receives the
    queries for those domains without a line.
  - **Evidence:** [Decision record 0024](decisions/0024-dns-through-the-mac.md), "What the
    platform does" and item 4; the owner chose this over a kernel rule that refuses port 53 to
    the gateway; `DNSIntegrationTests.writesAConsoleLineForAServerThatMawDoesNotConfigure`.
  - **Phase:** 12b. Removing the link's servers through systemd-resolved's D-Bus interface
    whenever they appear would close it, with a window after each change.
- **A `.network` file added while the machine runs uses the NAT network's DNS server for a
  moment.**
  - **Seen:** The drop-ins are written before systemd-networkd starts. For a file added later,
    the agent writes the drop-in when inotify reports it and runs `networkctl reload`; between
    the user's `networkctl reload` or `netplan apply` and the agent's, the link has the DHCP
    server, and a query in that window can reach it.
  - **Evidence:** `NetworkDNSWatch` in `Sources/MawAgentKit/NetworkDNS.swift`;
    `DNSIntegrationTests.keepsTheNetworksDNSOutWhateverItsFilesAreCalled` checks that no query
    reaches it afterwards. The window was not measured.
  - **Phase:** 12b.
- **A name whose only records are of a type outside the probes is answered NXDOMAIN.**
  - **Seen:** mDNSResponder reports a name without the requested type and a name that does not
    exist alike. The daemon answers NXDOMAIN only when A, AAAA, TXT, MX, SRV, NS, and SOA all
    have no record; a name whose only records are of another type, such as CAA or HTTPS, is
    answered NXDOMAIN for the seven answered types.
  - **Evidence:** [Decision record 0024](decisions/0024-dns-through-the-mac.md), item 2;
    `DNSAnswererTests`.
  - **Phase:** 12b.
- **Negative answers are not cached in the guest.**
  - **Seen:** The daemon's NXDOMAIN and NODATA answers carry no SOA record, so
    systemd-resolved does not cache them; each repeated negative lookup goes to the Mac, whose
    cache answers it.
  - **Evidence:** `DNSResponse.encode` in `Sources/MawProtocol/DNSMessage.swift`.
  - **Phase:** 12b. A synthesized SOA with the Mac's negative TTL would let the guest cache them.
- **Only seven record types are answered.**
  - **Seen:** A, AAAA, CNAME, MX, TXT, SRV, and PTR are answered; every other type, such as
    CAA, NS, SOA, SVCB, and HTTPS, is answered NOTIMP, as the phase prompt requires.
    `DNSServiceQueryRecord` would return any type.
  - **Evidence:** `DNSRecordType.answered` in `Sources/MawProtocol/DNSMessage.swift`.
  - **Phase:** 12b.
- **The Mac's search domains apply to single-label A and AAAA names only.**
  - **Seen:** `getent hosts buildhost` tries the Mac's search domains; a multi-label name such as
    `build.team` is looked up as it is, and so is a single-label name of another type. The
    search domains come from SystemConfiguration (`State:/Network/Global/DNS`); whether a file
    under `/etc/resolver/` adds to them was not measured.
  - **Evidence:** [Decision record 0024](decisions/0024-dns-through-the-mac.md), item 5.
  - **Phase:** 12b.

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
    percent of one core, only while a distributions screen is visible, and zero otherwise. The
    official run C at `1d91067` gave 0.773 ms (95th percentile 1.611 ms) and 0.364 % (95th
    percentile 0.367 %).
  - **Evidence:** [Decision record 0020](decisions/0020-distribution-figures.md), "What it
    costs": the official measurements of 2026-11-13 at `6829e27`, `694eb11`, and `1d91067`,
    after a restart and with only Terminal open, and the development measurements of 2026-11-12
    at load averages from 2.1 to 6.6.
  - **Phase:** 12b. Reusing one connection per run, about 80 to 100 lines, would remove most of
    the fixed cost; it changes the protocol and needs new guest files. In the machine's process
    the fixed cost is most of a sample in both official runs that measured it, 71 % in run A and
    79 % in run C, so a reused connection would remove most of that cost. In the guest agent,
    the split between the fixed cost of a request and the reading of the figures is not
    established. This item first stated, from run A, that the fixed cost is 39 % of a sample's
    agent time, whose larger part is the reading of the figures. Run C did not reproduce that
    split: by its medians, the fixed cost (0.869 ms per `info` request) is larger than a whole
    sample (0.773 ms), and both sets of batches are scattered, per sample 0.7 to 0.8 ms in three
    batches and 1.5 to 1.6 ms in two, and per `info` request 0.5 to 1.2 ms. How much of the
    agent's time a reused connection would save is therefore unknown. Before the protocol
    change is decided, measure the agent's split again with a method that gives stable results:
    for example, 20 batches of 1,000 requests per run instead of 5, alternating `sample` and
    `info` batches so that both meet the same conditions, with the guest's `steal` time read
    from `/proc/stat` before and after each batch.
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
    (90 columns) and the message of `installationOutcomeUnknown` (184 columns with
    `Ubuntu-24.04`).
  - **Evidence:** `Sources/maw/InstallCommand.swift:372`, `Sources/MawCore/MawError.swift:383`;
    pull request #19, "Known limitations and follow-up work". Seven messages have an 80-column
    test, wrapped by hand where needed: the cancellation, the password with a control
    character, the unconfirmed cancellation, `machineStopped` with the daemon's own reasons,
    `distributionNotInstalled`, and the suggestion of `installationOutcomeUnknown`
    (`Tests/mawTests/FailureTests.swift`), and `sessionConnectionEnded`
    (`Tests/MawCoreTests/MawErrorTests.swift:275`). Since phase 06b, the errors of
    `--unregister`, `--export`, and `--import` have one as well
    (`Tests/MawCoreTests/RemovalAndExportErrorTests.swift`,
    `Tests/MawCoreTests/ImportErrorTests.swift`).
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
- **`IntegrationTests.bootsAndPowersOff` misses the banner's timing line about once in three
  runs.**
  - **Seen:** `mawd debug-boot --cmdline maw.test=poweroff` exits before its separate task
    prints `boot: banner after <n> ms`, although the banner itself is in the output, and the
    test fails at `Tests/mawdTests/IntegrationTests.swift:52`. It failed in the full
    integration run at `7c0433e` and in 1 of 3 runs of the test alone afterwards; the full run
    before it passed.
  - **Evidence:** `DebugBoot.reportBanner` in `Sources/mawd/DebugBoot.swift:458`, unchanged
    since phase 05; pull request #35, "Verification".
  - **Phase:** 12b. Awaiting the banner task before `debug-boot` exits would resolve it.
- **`maw` stops with an exception when its standard error is closed and it writes a line
  there.**
  - **Seen:** `maw` writes its notices, the fallback line, and its error messages with
    `FileHandle.standardError.write(_:)`, which raises an Objective-C exception when the write
    fails, for example with `2>&-`. Found by the review of pull request #35; not reproduced.
  - **Evidence:** the five calls in `Sources/maw/` (`SessionRunner.swift`, `Maw.swift`,
    `UnregisterCommand.swift`); `writeAll(_:to:)` in `Sources/MawProtocol/System.swift`
    returns the error instead.
  - **Phase:** 12b. Writing every line with `writeAll` and ignoring its error would resolve it.
- **The integration tests' waits count time asleep.**
  - **Seen:** A Mac that sleeps during an integration run fails waits such as
    `waitForPrompt` at once on waking. The final runs of phase 05 used `caffeinate -dims`.
  - **Evidence:** `Tests/mawdTests/MawIntegration.swift:447`; pull request #19, "Known
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
- **Titles, working directories, and program names that programs report are shown
  unfiltered.**
  - **Seen:** A program in a pane sets the pane's title with OSC 0 or 2 and its working
    directory with OSC 7, and a guest process can set its own name with `prctl(PR_SET_NAME)`,
    which the session reports as the foreground program. The app shows the title and the
    directory as they arrive, in the window's title, the title bar, the pane grid, and the
    key-hint bar, and the program's name in the question before a tab or the app closes, so
    format characters such as U+202E take effect there and can make a name look like another.
    This is existing behavior, which this branch does not change; since phase 07, a program of
    a distribution can also write `settings.json` through `/mnt/mac`, whose `localShell` name
    the app now shows filtered.
  - **Evidence:** `WindowModel.updateWindowTitle()` (`pane.title ?? pane.displayName`) and the
    close and quit question's program names (`.program(let name)`,
    `App/MawTerminalKit/Sources/MawTerminalKit/Window/WindowModel.swift:614`), and
    `pane.workingDirectory` in `Views/TitleBarView.swift`, `Views/PaneGridView.swift`, and
    `Views/KeyHintBar.swift`; pull request #33, code review.
  - **Phase:** 12b. Filter once where titles, directories, and program names are shown, in
    those places, with the rules of `TerminalSessionError.displayable(_:)`.
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
- **The terminal app's cost with the distributions screen visible is within its limit by about
  7 %.**
  - **Seen:** In the owner's official measurement, the app's CPU over 60 seconds with the screen
    visible and one distribution running, above its cost with the screen hidden, was 0.927 % of
    one core (95th percentile 0.965 %) against the limit of 1 % that
    `prompts/11c-distribution-figures.md` sets: 1.041 % visible against 0.115 % hidden. An
    earlier official run, during which another app was opened for a short time, measured
    0.982 % (95th percentile 1.019 %); the development measurement gave 0.814 %.
  - **Evidence:** Pull request #30, "Speed targets": `AppFigureMeasurements.measuresTheAppsCost`
    in `Tests/mawdTests/AppFigureMeasurements.swift`, run by `scripts/measure-figures.sh` at
    `1d91067` on 2026-11-13. Where the time goes has not been profiled.
  - **Phase:** 12b. Profile the app with the screen visible, starting from the provider:
    `DaemonDistributions` in
    `App/MawTerminalKit/Sources/MawTerminalKit/Distributions/Distributions.swift` builds every
    row again at each snapshot and replaces the whole array when any row differs, which, with a
    distribution running, is at every sample; every window's views observe that array. Reduce
    the work where the profile shows it.

- **Three copies of an operation's step timing and cancellation.**
  - **Seen:** `timed(_:progress:_:)`, `checkCancellation(_:)`, the computation of
    milliseconds, and the pattern that runs the steps under `withTaskCancellationHandler` exist
    in `Installer`, `Exporter`, and `Importer`. A change to how steps are timed, logged, or
    mapped to a cancellation must be made three times.
  - **Evidence:** `Sources/MawDaemonKit/Installer.swift`, `Exporter.swift`, and
    `Importer.swift`; pull request #32, code review.
  - **Phase:** 12b: one helper for an operation's steps in `MawDaemonKit`.

- **`LocalShellSessionTests.aStartDirectoryThatDoesNotExistIsIgnoredAsOnMain` failed once in CI.**
  - **Seen:** In the first attempt of CI run 45353389601, at `a9305c7`, the test did not see
    the local shell exit within its 5 seconds, at
    `App/MawTerminalKit/Tests/MawTerminalKitTests/LocalShellSessionTests.swift:446`, and the
    terminal app's job failed. The rerun of the job passed, as did the CI runs before it on
    the same branch. The commit changed only documentation, and phase 08 does not change the
    test or the local shell. The cause is not known: the shell may not have run the command
    within the time, or its exit may not have been reported.
  - **Evidence:** CI run 45353389601, first attempt, job "Terminal app"; pull request #36,
    "Verification".
  - **Phase:** 12b. Repeating the test on a loaded machine with the shell's output and the
    session's state recorded at the deadline would show which of the two it is.

- **A session takes about 8 to 12 ms longer while 256 forwarded connections are held open, and
  most of that cost is not located.**
  - **Seen:** Timed from its start to its termination, `maw -- true` took a median of 50.6,
    51.0, and 52.7 ms in three development runs without forwarded connections, and 64.1,
    64.8, and 64.4 ms with 256 held open. About 7.5 ms of the difference lies inside the
    session as the daemon's log shows it, from its opening to its closing (medians of 11.5 ms
    against 19.0 ms), and about 4 ms outside it. The agent's `fork(2)` explains about 0.3 ms:
    the agent has 1,136 mappings and 515 threads with the connections held, against 20 and 5,
    and in the guest a `fork(2)` and wait took 0.66 ms with 1,537 mappings against 0.38 ms
    with 37. The rest is not located. In the owner's official reruns, the median over 80 runs
    of each side was 85.38 ms without the connections and 93.76 ms with them, 8.4 ms more,
    against about 12 ms in the development runs. The owner's rule allows 50 ms.
  - **Evidence:** [Decision record 0023](decisions/0023-localhost-forwarding.md), "The
    owner's official run"; `measuresSessionsBeside256Connections` in
    `Tests/mawdTests/ForwardingMeasurements.swift`.
  - **Phase:** 12b. Timing a session's steps in the daemon and the agent, with and without
    the held connections, would locate it.

## Phase 13: Packaging and release

- **macOS asks about `mawd` again after every development build.**
  - **Seen:** A distribution that opens `~/Desktop`, `~/Documents`, or `~/Downloads` through
    `/mnt/mac` makes macOS ask whether `mawd` may. A development build is signed ad hoc, and
    after each build whose code differs, macOS asks again for every protected folder, also for
    those allowed before.
  - **Evidence:** Part 1 of phase 07 (pull request #33): the TCC log attributed every request
    to `dev.maw.mawd`; after a rebuild with a new code hash, Desktop, which an earlier grant had
    covered, was asked again. [Decision record 0021](decisions/0021-mac-share.md).
  - **Phase:** 13, which signs the release build with a Developer ID, so that an answer lasts
    across updates.

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

- **A program in a distribution cannot listen on TCP port 53 on a wildcard address.**
  - **Seen:** The agent's DNS server holds `169.254.77.53:53`. A program that binds TCP
    `0.0.0.0:53` or `[::]:53`, such as dnsmasq or bind without `bind-interfaces`, fails with
    `EADDRINUSE`; over UDP, it binds only with `SO_REUSEADDR`, and the agent keeps the queries
    to its address. Beside systemd-resolved's stub listener the same already happens; what is
    new is that turning the stub off (`DNSStubListener=no`), as Pi-hole's instructions advise,
    no longer frees the wildcard TCP port. A program can bind the specific addresses that it
    serves instead.
  - **Evidence:** [Decision record 0024](decisions/0024-dns-through-the-mac.md), "Port 53 in the
    guest"; `DNSIntegrationTests.sharesPort53AndAnswersContainers`.
  - **Phase:** None yet.

- **Ports below 1024 are not forwarded.**
  - **Seen:** A server in a distribution on port 80, 443, or any port below 1024 is not
    reachable as `localhost` on the Mac; the distributions screen names the reason,
    `privilegedOnMac`.
  - **Evidence:** In Part 1 of phase 08, the daemon's `bind` of `127.0.0.1` and `::1` on ports
    80, 443, and 1023 failed with `EACCES` (errno 13): macOS lets a program that is not root
    bind such a port on the wildcard address only, which decision 1 of
    `prompts/08-networking.md` excludes. [Decision record 0023](decisions/0023-localhost-forwarding.md).
  - **Phase:** None yet; a privileged helper would add a privilege that maw does not have.
- **UDP is not forwarded.**
  - **Seen:** A UDP server in a distribution is not reachable from the Mac as `localhost`.
  - **Evidence:** `prompts/08-networking.md`, "The owner's decisions", item 1.
  - **Phase:** None yet.
- **Forwarded connections are slower than the NAT network.**
  - **Seen:** A forwarded 1 GiB response arrived at 383 to 388 MB/s, against 7,540 to
    7,735 MB/s from the guest's NAT address, in Part 1 of phase 08. Since the relay waits in
    `poll(2)`, the medians of 13 development runs were 303 to 364 MB/s, and the owner's
    official run measured 368 MB/s. Enough for a development server; not for bulk transfers
    at the NAT network's speed.
  - **Evidence:** [Decision record 0023](decisions/0023-localhost-forwarding.md): a vsock
    connection that the guest opens carried 608 MB/s with no maw code
    ([0017](decisions/0017-dial-back-for-sessions.md)), each side copies through user space
    once, and the nonblocking reads on the Mac's side add a system call and a `poll(2)` for
    most pieces.
  - **Phase:** None yet.
- **Binding a forwarded port can hold a distribution's forwarder for up to 500 ms.**
  - **Seen:** The forwarder binds each port that the guest reports, and probes a port in
    `TIME_WAIT`, on its own actor. The probe's connect waits up to 500 ms when a Mac program
    holds the port and its accept queue is full, so that the connection is neither accepted nor
    refused. Meanwhile that distribution's forwarder handles no other report and no new
    connection. Every other bind and probe returns at once.
  - **Evidence:** The code review of phase 08 pull request A; `LoopbackListeners.bind` in
    `Sources/MawDaemonKit/LoopbackPorts.swift` and its call in
    `Sources/MawDaemonKit/PortForwarder.swift`. The wait is bounded by
    `LoopbackListeners.probeTimeoutMilliseconds`, and the probe runs at most once each time
    the guest reports a port anew.
  - **Phase:** None yet. Binding off the actor would need the forwarder to order a port's
    bind against later reports of the same port, which this pull request does not do.
- **The terminal app's status slot for port forwarding stays empty.**
  - **Seen:** `prompts/11a-terminal-app.md` plans a status slot for port forwarding; the app
    leaves it empty, and the distributions screen's `forwarded` row shows the ports.
  - **Evidence:** `prompts/08-networking.md`, "The snapshot and the screen".
  - **Phase:** None yet.

- **The distributions screen shows the share as it was when the machine started.**
  - **Seen:** The `mounts` row comes from the agent's `info` reply at the start. A share that
    is unmounted in the guest later, with `sudo umount /mnt/mac`, still shows until the machine
    stops.
  - **Evidence:** `VirtualMachineHandle.macShare` in
    `Sources/MawDaemonKit/VirtualMachineHandle.swift`; the prompt allows a fact known at boot
    rather than a request for every snapshot.
  - **Phase:** None yet; the `sample` reply could carry it, at the cost of reading
    `/proc/self/mountinfo` at every sample.

- **A watcher does not notice a distribution removed by hand while no machine runs.**
  - **Seen:** `maw --unregister` is the supported way to remove a distribution, and the
    terminal app's distributions screen drops it at once. A distribution whose directory is
    deleted by hand instead stays in the snapshots of `watchDistributions` until the next
    snapshot: a sample of a running machine, a state change, an installation, a removal, or a
    new default.
  - **Evidence:** `FigureSampler.snapshot(after:)` reads the installed distributions only when
    the sequence number has grown (`Sources/MawDaemonKit/FigureSampler.swift`); nothing watches
    the distributions directory. `DaemonService.unregister` publishes a snapshot after each
    removal.
  - **Phase:** None yet; a watch of the distributions directory, or no change, since the
    supported removal publishes.
- **`maw --export` and `maw --import` do not keep POSIX ACLs.**
  - **Seen:** Access and default ACLs of files in a distribution are missing from its archive;
    the files keep their mode, whose group bits are the ACL's mask, and their other extended
    attributes.
  - **Evidence:** The guest's `bsdtar` is built with `--disable-acl`
    (`Guest/initramfs/build.sh:120`), and libarchive does not archive the kernel's
    `system.posix_acl_access` and `system.posix_acl_default` attributes as extended attributes
    either. `RemovalAndExportIntegrationTests.recordsWhatAnExportKeepsOfPOSIXACLs` sets both
    kinds and prints which ACL records reach the archive: none, as its run in the pull request
    records. It then imports the archive and reads both ACLs on the imported disk, with
    `os.getxattr`, since the image has no `getfacl`: neither is there, and the user attribute
    beside them is (pull request #32).
  - **Phase:** None yet. Building `bsdtar` with ACL support needs libacl in the guest build;
    the import would need the same to restore them.
- **`maw --import` reads no zstd archive and no tar archive without the ustar magic.**
  - **Seen:** An archive compressed with zstd, and an old (v7) tar archive, whose header has no
    `ustar` at offset 257, are refused with "is not a tar archive".
  - **Evidence:** The import decompresses with `/usr/bin/gzip -dcf`, which has no zstd, and
    forwards only a stream whose first block has the magic (`Sources/MawDaemonKit/ImportStream.swift`),
    because `/usr/bin/tar` would follow an mtree archive's names to files of the Mac (pull request
    #32, security review). Decompress a zstd archive first, with `zstd -dc archive.tar.zst |
    maw --import <name> -`.
  - **Phase:** None yet. A zstd decoder that reads no archive format, on the Mac or in the
    guest, would add it.
- **The network of an import without netplan is verified on Ubuntu only.**
  - **Seen:** For an archive without netplan, the import enables `systemd-networkd` and
    `systemd-resolved` with links in `multi-user.target.wants` only. It does not create what
    `systemctl enable` also creates: `systemd-networkd.socket`, which the unit names with
    `Also=`, and the `dbus-org.freedesktop.network1` and `resolve1` aliases. On Ubuntu 24.04
    without netplan, the copy got a DHCP address, its gateway answered a ping, and
    systemd-resolved had a DNS server. On a distribution whose units need the socket or the
    aliases, `networkctl` and `resolvectl` may not answer until `systemctl enable` runs.
  - **Evidence:** `ProvisioningScript.text`, the `import` mode's fallback;
    `ImportIntegrationTests.configuresTheNetworkWithoutNetplan`; pull request #32, code review.
  - **Phase:** None yet. `systemctl --root` from the imported root file system, if it has one,
    would enable the units completely.
- **An imported distribution whose systemd-networkd is masked has no network.**
  - **Seen:** An archive in which the user masked the unit, as some WSL setups do, keeps the
    mask; the import does not unmask a unit that the user masked. A masked systemd-resolved
    leaves DNS to the resolver file that the initramfs writes, since phase 08
    (`DNSIntegrationTests.answersThroughTheBootsResolverFileWithoutSystemdResolved`).
  - **Evidence:** `ProvisioningScript.text` only adds masks; pull request B of phase 06b decided
    not to handle it.
  - **Phase:** None yet. `systemctl unmask systemd-networkd` in the distribution restores it.
- **A `maw --export` killed with SIGKILL leaves its file.**
  - **Seen:** maw removes the file of a failed or cancelled export, on Ctrl-C, SIGTERM, and
    SIGHUP as well, but a SIGKILL ends it before it can. The partial file, of mode 600, stays
    at the path that was given, and the daemon ends the export when the connection closes.
  - **Evidence:** `ArchiveFile.remove()` in `Sources/maw/ExportCommand.swift:221` runs in maw's
    process; the daemon never opens the path, by design (docs/security.md, "The export's
    descriptor").
  - **Phase:** None yet. Writing to a temporary name and renaming it at the end would leave a
    differently named file instead; a file that cannot be removed this way is inherent to a
    client-side file.

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
- **Linux tabs show no working directory.**
  - **Seen:** A Linux tab's label and the key hint bar show the distribution's name without
    the working directory that a local tab shows. The app takes a Linux session's directory
    only from OSC 7, and never polls the guest; Ubuntu's bash does not send OSC 7.
  - **Evidence:** `LinuxSession.terminalReportedWorkingDirectory(_:)` and
    `refresh(isVisible:)` in
    `App/MawTerminalKit/Sources/MawTerminalKit/Session/LinuxSession.swift`;
    `prompts/11b-linux-sessions.md`, "Out of scope".
  - **Phase:** None yet. Phase 07 translates `maw`'s working directory and leaves the app
    unchanged; a Linux tab still starts in the Linux home directory, because a new tab has no
    Mac directory of its own. Having the distribution's shell send OSC 7 remains a candidate.
- **A home directory whose own name has non-ASCII letters reaches `mawpath` decomposed.**
  - **Seen:** The daemon takes the home directory's path from `URL`, which gives it in its
    decomposed form (NFD), and puts that on the kernel command line as `maw.home`. `mawpath -m`
    then prints the home directory's name in NFD, and `mawpath` given the name in NFC reports
    it as outside the home directory. Names below the home directory pass through as they are.
    `maw`'s own translation compares resolved paths and is not affected.
  - **Evidence:** `MachineConfigurationTests.putsTheHomeDirectoryOnTheCommandLineForMawpath`
    in `Tests/MawDaemonKitTests/MachineConfigurationTests.swift`; pull request #35.
  - **Phase:** None yet. Taking the path from `getpwuid` or `realpath`, which return the bytes
    that the file system stores, would resolve it.
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
    pool for about 3 to 12 seconds after the group starts. The CPU-bound ones are mainly the
    argument parser's tests in a debug build (`ValidationTests`, `DebugBootParsingTests`),
    with `ImageCacheTests`, `DistributionStoreTests` and `RootCheckScriptTests`. The blocking
    one was `PeerRequirementTests.acceptsOnlyMawsIdentifiers`, which waited for `codesign`
    with `waitUntilExit()` in seven parallel cases; it now suspends instead, but `codesign`
    itself still competes for the CPU. While the pool is full, no other task in the process
    starts or resumes, so nearly every test that started before the stall reports its length
    as its duration. Since the `fix/test-waits` branch, the unit tests' waits that failed so
    hold through a stall:
    - a wait in a task counts its sleeps instead of reading a clock, so that the stall, which
      delays the sleeps as much as the work waited for, cannot use it up;
    - every scripted peer on a thread of its own, whose clock runs on during the stall, has a
      deadline of 60 s, longer than any stall seen, in `HandshakeTests`, `GuestProcessTests`,
      `ForegroundQueryTests`, `FrameConnectionTests`, `SessionEndingTests`,
      `DistributionSessionTests`, `DialBackTests`, `ExecSessionTests`, `FuzzTests`,
      `DialBackGateTests`' fake agent, and `TestAgent`'s agent; so does every
      `GuestAgentClient` that a test makes to talk to one, in `HandshakeTests`,
      `GuestProcessTests`, `ForegroundQueryTests`, `SessionEndingTests`, `DialBackTests`,
      `DialBackGateTests`, and `TestAgent`. The exceptions are the deadlines that a test
      asserts, listed below; the peer of `GuestProcessTests.Latency`, which reads for the time
      that the test measures; and `DistributionSessionTests`' client, which the product makes
      with 10 s (below);
    - `maw --export` and `maw --import` wait for the daemon's answer to a cancellation and for
      the operation's own reply with timeouts that a test can lengthen, `cancelTimeout` and
      `replyTimeout`, which keep 5 s and 500 ms otherwise;
    - `ArchiveOutputTests.endsAtOnceWhenAbortedWhileTheReaderDoesNotRead` allows the abort
      30 s of real time instead of 2 s;
    - every test whose wait no longer ends on a clock of its own has a time limit.

    Before that branch, such waits failed in CI: `HandshakeTests.exchangesMatchingVersions()`
    until its peer moved to a thread of its own (CI runs 42512716425, 42574910845,
    42644895862, 42807002034 and 42834158953), `ExportCommandTests` in runs 44086055594 and
    44358996376 of pull request #33, `DistributionSessionTests`' three tests whose shell starts
    in 44358996376, and `LaunchctlTests.waitsUntilLaunchdNoLongerListsTheJob()` in 44372965404,
    each passing on a re-run. In 44358996376, almost no result came back from 17:31:00 until
    17:31:08.5, and 944 of the 958 results in the log reported 9.0 to 12.0 s; in 44372965404,
    873 of 886 reported 9.3 to 11.7 s.

    What still reads a running clock in the unit tests, and why it stays:
    - **Deadlines that a test asserts**, which counting would no longer measure:
      `HandshakeTests.clientTimesOutOnASilentPeer` (200 ms); `DialBackTests`' dialer timeouts
      (200 ms and 2 s); `DialBackGateTests`' own limits
      (`Tests/MawVirtualizationTests/DialBackGateTests.swift:265`,
      `Tests/MawVirtualizationTests/DialBackGateTests.swift:367`,
      `Tests/MawVirtualizationTests/DialBackGateTests.swift:409`), its latency
      test of the nonce's read timeout (2 to 3 s), and
      `endsAnExpiredWaitWhenAnotherSessionRegisters` (2 s, compared with the gate's real-time
      expiry); the 200 ms of `foregroundProgram(within:)` in
      `ForegroundQueryTests` and `DistributionSessionTests` (`noAnswer`); `SessionEndingTests`'
      50 ms of `relay.next(within:)`; `DiskImageTests`' 200 ms of `waitUntilUnlocked`;
      `InstallCancellationOutcomeTests`' 50 ms cancellation and `ImportCommandTests.Latency`'s
      200 ms;
      `SequenceReaderTests.keepsTheBytesOfLaterReads`' 10 s of `waitForLines`, which expects
      no lines; `LaunchctlTests`' tests of the timeouts of `waitUntilRemoved` and `run`;
      `StreamingProcessTests`' bound of 5 s on a program that cannot start; and
      `ArchiveOutputTests.endsAtOnceWhenAbortedWhileTheReaderDoesNotRead` (30 s). The tests of
      the latency group (`ExecSessionTests.Latency` and `InstallCancellationTests.Latency`
      among them) assert real time and run one at a time, beside no other test.
    - **Waits for something outside the pool**, which a stall does not stop:
      `Tests/MawTestSupport/Process+Exit.swift`, which waits for processes and checks again
      after its deadline, and its users with 10 s to 30 s (`RootCheckScriptTests`,
      `ShellFixtures`, `ProvisioningScriptTests`, `DiskImageTests`);
      `ForegroundSessionTests.hangsUpOnTheProcessWhenTheHostHangsUp`, which waits for a file
      that a child process writes after the test agent, which serves on threads of its own,
      hangs up, and checks again after its deadline.
    - **Waits not shown to survive a stall**, which did not fail in the runs of the
      `fix/test-waits` pull request:
      - the bounds of 10 s on `foregroundProgram(within:)` in `ForegroundQueryTests`,
        `ForegroundSessionTests` and `DistributionSessionTests`, and of 60 s in
        `ForegroundQueryTests` only (`Tests/MawProtocolTests/ForegroundQueryTests.swift:154`,
        `Tests/MawProtocolTests/ForegroundQueryTests.swift:176`);
      - `DistributionSessionTests`' 10 s for the scripted agent's replies: the session's
        client comes from `DaemonSession.agentClient()`
        (`Sources/MawClient/DaemonClient.swift:377`), which keeps `GuestAgentClient`'s default,
        and a test cannot lengthen it;
      - `SessionEndingTests`' 10 s of `relay.next(within:)`;
      - `DiskImageTests.seesALockThatAnotherProcessHolds`' 10 s of `waitUntilUnlocked`;
      - `InstallEndedBeforeTheCancellationTests`' 5 s wait for the output of an interrupted
        installation, and `InstallCancellationOutcomeTests`' cancellation of 30 s;
      - `GuestProcessTests`' 70 s of `exitStatus(of:within:)`, longer than the 60 s of its
        reading peer's read loop, though not than the peer's later steps;
      - `LaunchctlTests.waitsUntilLaunchdNoLongerListsTheJob`' 60 s on `SuspendingClock`.
    - **Holds that spin on a thread of the pool**, whose bounds a longer value would make worse:
      `FigureSamplerTests.reportsTheGuestsAnswerBeforeCancellingItsTimeout` holds the sampler's
      guest task in the test clock's cancellation, for at most 2 s, until another task
      publishes the figures, so it cannot pass while the pool has one thread
      (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`), on `main` or since the branch; it has not
      failed in CI, where the pool has a thread per core. `ImageCacheTests`'
      `stopsACancelledCheckWithinOnePiece` holds a read the same way, for at most 10 s.
    - The integration tests in `Tests/mawdTests` and `Tests/maw-integration-probe` run only
      through `scripts/integration-test.sh`, in a process of their own beside real virtual
      machines, and keep their clocks.
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
    process of its own, so a plain local `swift test` shows a much shorter stall. In that
    layout, with the strict pool and 16 `yes` processes beside it, `main` at `774f195` failed
    `DistributionSessionTests` and `LaunchctlTests` as in CI, and four more tests that wait on
    a clock; after the `fix/test-waits` branch, only `FigureSamplerTests`' test failed, in 20 of
    20 runs (its pull request has the figures).
  - **Phase:** None. The stall itself remains: run the CPU-bound and blocking synchronous
    tests off the pool or in a group of their own, as `scripts/test-groups.sh` and
    `docs/decisions/0018-test-groups.md` do for load and latency, and give
    `FigureSamplerTests.reportsTheGuestsAnswerBeforeCancellingItsTimeout` a way to see the
    order without holding a thread of the pool. A helper in `Sources/MawProtocol/Threads.swift`
    that starts a thread at once and returns its result to await later would keep the rule for
    peers in one place instead of a comment in each test; `Sources/MawProtocol` is a Guest
    workflow path.
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

- **maw's kernel carries a patch of its own.**
  `Guest/kernel/patches/0001-virtiofs-owner-options.patch` gives virtiofs `uid=` and `gid=`
  options, so that every file under `/mnt/mac` shows the default user as its owner. Every
  kernel bump must apply it with no fuzz, or refresh it.
  [Decision record 0021](decisions/0021-mac-share.md); `Guest/README.md`, "Bumping the kernel".

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
- **A forwarded connection never relies on vsock's own half-close or close.**
  Virtualization.framework drops a guest's half-close once data waits for the host, and
  discards data that the guest has sent when the guest closes after the host has
  half-closed. Forwarded connections are therefore framed byte streams with the end of each
  direction inside the stream, which costs a 5-byte header per 128 KiB and a parse of that
  header in the daemon, and the daemon closes each connection first. The agent waits for
  that close for as long as its send queue moves, and closes the connection itself after
  120 seconds without progress. Whether a Mac client that has read nothing for that long
  still receives the rest and the end was not measured: a guest's close without the host's
  half-close delivered everything while the host was reading. Whatever such a client sends
  afterwards resets the connection.
  [Decision record 0023](decisions/0023-localhost-forwarding.md), "Correction of 2026-11-28".
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
