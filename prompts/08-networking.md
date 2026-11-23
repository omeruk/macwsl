# Phase 08: Networking

Read `CLAUDE.md`, `docs/decisions/` (0001, 0002, 0013, 0014, 0017, 0018, 0020, and 0021 above
all), `docs/daemon.md`, `docs/protocol.md`, `docs/distributions.md`, `docs/security.md`, and
`docs/known-limitations.md` first.

Since phase 05 a distribution reaches the network through Virtualization.framework's NAT
(decision record 0014). Two things that WSL users rely on are still missing. A server started in
Linux, such as `python3 -m http.server 8000`, cannot be reached from the Mac as
`localhost:8000`, the way WSL forwards `localhost`. And DNS in the guest asks the NAT's server at
`192.168.64.1`, which does not follow the Mac's VPN and split-DNS settings, and whose first
answer after a boot is lost ("The first DNS query after the DHCP lease is not answered" in
`docs/known-limitations.md`). This phase adds both.

The phase is delivered in two pull requests, in this order, each from the latest `main`:

- **A, `localhost` forwarding**, on branch `phase/08-localhost`: TCP ports that a distribution
  listens on are reachable on the Mac's loopback addresses, the snapshot reports them, and the
  distributions screen shows its `forwarded` row.
- **B, DNS**, on branch `phase/08-dns`, after A is merged: the guest's DNS queries are answered
  by the Mac's own resolver, so that they follow the Mac's VPN and split-DNS configuration.

Keep each pull request small. Anything not needed for this phase goes into a separate `fix/`
branch or into `docs/known-limitations.md`. If a plan's estimate exceeds 2,000 added lines
outside `Tests/`, say so in the plan; if the work exceeds 3,000 added lines outside `Tests/` in
one pull request, stop and ask before going on.

## The owner's decisions

These are decided. Do not reopen them in the plan; if a measurement shows that one cannot hold,
stop and report it with the numbers.

1. **Automatic, TCP only, the Mac's loopback only.** When a process in a running distribution
   listens on a TCP port on a wildcard address (`0.0.0.0`, `::`) or a loopback address
   (`127.0.0.1`, `::1`), the same port is reachable on the Mac at `127.0.0.1` and `::1`, with no
   command and no setting, as WSL's `localhostForwarding` does. maw never listens on the Mac's
   other interfaces, so other machines on the owner's network cannot reach a distribution.
   UDP is not forwarded.
2. **The Mac's ports come first.** If the port is already in use on the Mac, or another
   distribution already forwards it, maw does not forward it for this distribution, does not
   pick another port, and records why (see "The snapshot and the screen"). The forwarding ends
   when the guest stops listening or the machine stops.
3. **DNS through the Mac's resolver, for every distribution, with no switch in this phase.**
   The guest's queries are answered by the Mac's system resolver, which applies the Mac's VPN
   and split-DNS configuration (WSL's `dnsTunneling`). A setting to turn it off belongs to
   phase 12's `.mawconfig`; record it in `docs/known-limitations.md` under phase 12.
4. **The network device stays as it is.** NAT through `VZNATNetworkDeviceAttachment`, as
   decision record 0014 set it, stays the guest's path for outbound connections. No bridged or
   mirrored networking in this phase.

## Part 1 (pull request A, before the plan): what the platform does

Before you write the plan, measure on the owner's Mac what the plan depends on, with a
throwaway build on a branch of its own (`spike/08-network`, never pushed, deleted afterwards).
Run it as temporary `.integration` tests through `scripts/integration-test.sh --filter <suite>`,
which installs the test daemon under its own label, on a test distribution that the run
installs from the cached image and removes afterwards; never commit those tests.
`scripts/integration-test.sh` builds the working tree, so the binaries under `.build` are the
spike's while it runs: when Part 1 is reported, switch back to `main`, build, and run
`./scripts/sign-dev.sh`, so that the owner's daemon finds `main`'s binaries again, and say so in
the report.

Find out and report, with the commands and their output:

- **Reaching the guest today.** Whether the Mac can connect to a guest listener on the guest's
  NAT address (`192.168.64.x`) on `0.0.0.0` and on `127.0.0.1`, and whether that still works
  while a VPN is connected, if the owner has one (ask; never connect or configure a VPN
  yourself).
- **Seeing listeners in the guest.** How the agent can learn, within a second, which TCP ports
  are listening and on which address: polling `/proc/net/tcp` and `/proc/net/tcp6`, netlink
  `sock_diag`, or another way. Measure the cost of each on an idle machine (the agent's CPU time
  per minute) and the delay from `listen()` to the agent seeing it, median and slowest of 20.
- **Carrying a connection.** The throughput and the time to the first byte of a forwarded
  connection over vsock (through the agent) against a direct connection to the NAT address:
  `curl` of a 1 GiB response from a guest server, and 100 short requests, median and slowest of
  5 runs. Report whether vsock's throughput is enough for a development server.
- **Listening on the Mac.** Whether the daemon, as the owner's LaunchAgent, can listen on
  `127.0.0.1` and `::1` on ports below 1024 and above, whether macOS asks the owner anything
  (a firewall or privacy question) when it does, and what `bind` reports for a port that a Mac
  program already uses. The owner must be at the Mac for this run: tell the owner before it
  starts, and ask afterwards what appeared. Never answer such a question on the owner's behalf.
- **DNS today.** The time of a lookup in the guest through `192.168.64.1`, cold and warm, and
  whether a name that only the Mac's split DNS knows resolves in the guest. To make such a name
  without a VPN, the owner can add a scoped resolver file under `/etc/resolver/` on the Mac,
  which needs `sudo`: give the owner the exact commands to add it and to remove it afterwards,
  and never run `sudo` yourself.
- **DNS through the Mac.** Which macOS API answers a query with the Mac's full resolver
  configuration, scoped resolvers and VPNs included (`DNSServiceQueryRecord` from `dns_sd.h`,
  `res_query`, `getaddrinfo`, or another), for the record types A, AAAA, CNAME, MX, TXT, SRV,
  and PTR, and for a name that does not exist (NXDOMAIN). Measure a lookup through it from the
  daemon, cold and warm.

Put the results in the plan and, in short, in decision record 0023 (see "Docs"). If a result
makes one of the owner's decisions impossible or unsafe, stop and report before planning.

## Product requirements

### `localhost` forwarding (A)

- **What is forwarded.** Every TCP port that a process in a running distribution listens on,
  on a wildcard or a loopback address, IPv4 or IPv6, while the distribution's machine runs.
  A listener on another guest address (such as a Docker bridge) is not forwarded, nor one on
  another loopback address such as systemd-resolved's `127.0.0.53` and `127.0.0.54`, nor a
  listener of maw's own agent, B's resolver included.
- **Where.** The daemon listens on the Mac's `127.0.0.1` and `::1` for each forwarded port, and
  carries each accepted connection to the guest's listener. The plan chooses the path (through
  the agent over vsock, or to the NAT address) from Part 1's results, and says why; a listener
  on the guest's `127.0.0.1` must be reachable, as WSL makes it, and the path must not depend on
  the NAT subnet being routable while a VPN is connected.
- **How fast.** A port becomes reachable on the Mac within 1 second of the guest's `listen()`,
  and stops being forwarded within 1 second of the guest's `close()` (see "Speed targets").
- **Conflicts.** A port in use on the Mac, or forwarded for another distribution, is not
  forwarded for this one (decision 2). A later free port is never chosen instead. The plan says
  what happens when the port is free on one of `127.0.0.1` and `::1` but not on the other.
- **Connections in flight** end when the machine stops, when the guest's side closes, or when
  the Mac's side closes, and each side sees the other's end of the stream. Half-close
  (`shutdown(SHUT_WR)`) is carried. A guest that refuses the connection makes the Mac's side
  close at once.
- **Resources.** The daemon caps the open forwarded connections per distribution and the bytes
  it buffers per connection; the plan names the limits and what a client sees beyond them.
  Nothing a guest sends can make the daemon listen anywhere but the Mac's loopback addresses.

### The snapshot and the screen (A)

- The daemon's snapshot reports, per running distribution, the forwarded ports, and the ports
  that were not forwarded with the reason (in use on the Mac, forwarded for another
  distribution). This changes the daemon interface: increment `DaemonInterface.version`, update
  `docs/daemon.md`.
- The distributions screen's details box gets its `forwarded` row, as
  `docs/design/terminal/Distributions.dc.html` shows it (`localhost:8000 → 8000`), for a running
  distribution with at least one forwarded port. With several ports the row lists them in port
  order and stays on one line, ending in `+N` when they do not fit. Without a forwarded port, or
  for a stopped distribution, the row is left out. This resolves "The distributions screen's
  details box has no `forwarded` row".
- A port that was not forwarded is shown in the row's help text with its reason.
- The terminal app's status slot for port forwarding (`prompts/11a-terminal-app.md`) stays
  empty; record it in `docs/known-limitations.md` if you find it worth filling later.

### DNS (B)

- **The guest's resolver.** In every distribution, without reinstalling it and without writing
  its `/etc`, systemd-resolved sends its queries to a resolver that the agent provides, and the
  agent carries them to the daemon, which answers them with the Mac's system resolver. The plan
  says where the agent listens, how systemd-resolved is pointed at it at every boot (for example
  a runtime drop-in under `/run`, as `/init` already writes one for systemd-timesyncd), and how
  the DHCP-provided server at `192.168.64.1` stops being used.
- **What is answered.** A, AAAA, CNAME, MX, TXT, SRV, and PTR, with the Mac's answers and TTLs,
  and NXDOMAIN for a name that does not exist. Other types get an answer that tells the guest's
  resolver that the type is not supported, never a silent drop. DNSSEC validation is out of
  scope.
- **Search domains and single-label names.** The plan says how a name without a dot and the
  Mac's search domains behave in the guest, and why.
- **VPNs and split DNS.** A name that only the Mac's VPN or a scoped resolver knows resolves in
  the guest, and stops resolving when the VPN disconnects, without restarting the machine.
- **The first query after a boot** is answered. This resolves "The first DNS query after the
  DHCP lease is not answered"; if B's path still loses it, stop and report.
- **Failure.** If the daemon cannot be reached, a query fails within the resolver's normal
  timeout with SERVFAIL, and the next query tries again. maw never falls back to
  `192.168.64.1` silently; the plan says whether a fallback is offered and how the console log
  records it.
- **Limits.** The daemon caps a query's size, the queries in flight per distribution, and the
  rate, and says what the guest gets beyond them. A query from the guest never changes the Mac's
  resolver configuration or cache beyond an ordinary lookup.

## Speed targets

Measure through the test daemon on test distributions that the measurement installs from the
cached image and removes afterwards. Record the median and the slowest of 5 runs in each pull
request, with the date, the commit, and the load average, as development measurements. The
owner then runs the same measurements under the owner's rule: a restarted Mac on AC power, the
lid open, Low Power Mode off, `caffeinate -dims`, only Terminal open, and a one-minute load
average under 2 before the start. Provide one command for that run, a script under `scripts/`
that runs the measurements through `scripts/integration-test.sh` as `scripts/measure-paths.sh`
does, and tag the measurements so that the integration tests can run without them. If a target
is missed, report the number, where the time goes, and what would close the gap.

| Measurement | Target | PR |
|-------------|--------|----|
| From the guest's `listen()` to `localhost:<port>` accepting on the Mac | under 1 s | A |
| Time to the first byte of a forwarded HTTP request, warm | adds under 5 ms to a direct connection to the NAT address | A |
| Throughput of a forwarded 1 GiB response | report MB/s, against the NAT address | A |
| The agent's CPU time per minute on an idle machine, with forwarding on | report, against `main` | A |
| Cold start to a prompt, against `main` | adds under 20 ms to the median | A, B |
| A DNS lookup in the guest, warm | under 10 ms | B |
| The first DNS lookup after a cold start | under 1 s | B |

## Architecture

- **The guest's listeners** are found by the agent, in the way Part 1 chooses, and reported to
  the daemon. The plan says how the report reaches the daemon (a request the daemon makes, or a
  message the agent sends), and keeps it off the path of every session.
- **The forwarder** lives in the daemon, in `MawDaemonKit`, with one owner per distribution's
  machine, and ends with it. It uses `async`/`await` and actors; a blocking socket API is
  wrapped at the boundary, as `CLAUDE.md` requires.
- **The DNS client** in the daemon is its own type behind a protocol, so that unit tests answer
  queries without the network.
- **The DNS message encoding** that both sides need is a pure type in `MawCore` or
  `MawProtocol`, which compile on Linux, with unit tests for every record type and malformed
  input.
- A change of the guest protocol increments `ProtocolVersion` and updates `docs/protocol.md`;
  a change of the daemon interface increments `DaemonInterface.version` and updates
  `docs/daemon.md`.
- **No new third-party dependency.** Approved ones only (`CLAUDE.md`).
- The plan says which parts change the guest files, the guest protocol, and the daemon
  interface, in each pull request.

## Security

Record in `docs/security.md`:

- **What forwarding gives.** Any program on the Mac, including other users' programs, can
  connect to a forwarded port on the loopback addresses, as with WSL. Nothing listens on the
  Mac's other interfaces. A distribution can make the daemon listen on any port that is free on
  the Mac's loopback addresses while the distribution runs, which can delay a Mac program that
  later wants that port; say so, and that `maw --terminate` ends it. Update the network section,
  which says that forwarding arrives in phase 08.
- **What DNS through the Mac gives.** The guest can ask the Mac's resolver for any name, as any
  program on the Mac can; with a VPN connected, that includes the VPN's internal names. A query
  never changes the Mac's configuration.
- **Where a guest's input reaches the Mac.** Port numbers, connection bytes, and DNS queries
  come from the guest. The plan shows how each is bounded and validated, and that nothing from
  the guest chooses an address the daemon listens on or a server the daemon asks.

## Guest files

Both pull requests probably change the guest files (A: the agent's listener reports; B: the
resolver and its configuration at boot). Follow `README.md`, "After a change of the guest
protocol or the daemon interface", and the rules for the shared working tree in
`prompts/11c-distribution-figures.md`, "Installing the builds": open each pull request as a
draft as soon as Guest workflow paths have changed, so that the Guest workflow builds the guest
files, tell the owner before the first build that changes the protocol or the interface, and
give the owner the exact procedure to install the branch's build, with `scripts/fetch-guest.sh`,
and to return to `main`. The owner installs the branch's build; never run
`scripts/fetch-guest.sh` or `mawd install` yourself.

## Tests

Follow decision record 0018 for the test groups.

**Unit tests, run in CI:**
- Reading listeners from the guest's tables: wildcard, loopback, other addresses, IPv4 and
  IPv6, and malformed lines.
- The forwarder: a port forwarded and released, a port in use on the Mac, a port forwarded for
  another distribution, half-close, a refused guest connection, the connection and buffer
  limits, and the end of every connection when the machine stops.
- The snapshot's new field through `InterfaceCoding`, and the interface version.
- The app: the `forwarded` row's presence, absence, order, and `+N`, and the help text of a port
  that was not forwarded.
- The DNS message encoding for every record type, NXDOMAIN, an unsupported type, truncation,
  and malformed or oversized queries; the daemon's limits; SERVFAIL when the daemon cannot be
  reached.

**Integration tests** (`.integration`, through `scripts/integration-test.sh`), on test
distributions from the cached image:
- A: a server in the guest on `0.0.0.0` and one on `127.0.0.1` answer on the Mac's `localhost`;
  a server on `::` answers on `::1`; a port in use on the Mac is not forwarded and is reported;
  a port is released after the server stops and after `maw --terminate`; two distributions
  listening on the same port; a 1 GiB transfer arrives intact (checksum).
- B: a lookup of a public name; NXDOMAIN; an MX and a TXT record; the first lookup after a cold
  start; and a name from a scoped resolver on the Mac, if the owner adds one for the run (give
  the owner the commands, and never run `sudo` yourself).
- The measurements under "Speed targets", tagged as described there.

## Docs

- `docs/decisions/0023-localhost-forwarding.md` (A): Part 1's results, the listener detection,
  the path chosen, the conflicts rule, and the limits.
- `docs/decisions/0024-dns-through-the-mac.md` (B): the API chosen, how the guest is pointed at
  it, the failure behavior, and the limits. Update 0014's item 4 to point to 0023 and 0024.
- `docs/daemon.md`: the forwarder, the DNS client, the snapshot field, the interface version.
- `docs/protocol.md`: any new message, the protocol version.
- `docs/distributions.md`: what a distribution sees for `localhost` and DNS, and that nothing is
  written to its disk for either, or what is.
- `docs/security.md`: as described under "Security".
- `README.md`: reaching a Linux server from the Mac as `localhost`, and DNS under VPNs.
- `docs/known-limitations.md`: remove what each pull request resolves (the two phase 08 items),
  add what it defers (the switch to turn DNS through the Mac off, under phase 12; UDP; anything
  Part 1 found that is not fixed).
- `docs/ROADMAP.md`: 08 stays "Planned" after A and is marked done in B, with the two pull
  requests named as for 07.
- Add this file to `prompts/` in pull request A.

## Out of scope

- Forwarding UDP, or forwarding to the Mac's other interfaces or to other machines.
- Forwarding from the guest to the Mac (the guest reaching a Mac server as `localhost`).
- Bridged or mirrored networking, a static address, or IPv6 changes to the NAT network.
- A switch to turn forwarding or DNS through the Mac off (phase 12).
- Filling the terminal app's port-forwarding status slot.
- Idle shutdown and its interplay with open forwarded connections (phase 12).

## Acceptance criteria

For each pull request:

- The root package: `swift build -Xswiftc -warnings-as-errors`; `swift build --build-tests
  -Xswiftc -warnings-as-errors`, then `scripts/test-groups.sh all .build/test-results`;
  `swift format lint --strict --recursive Sources Tests Package.swift`.
- `App/MawTerminalKit` builds and its tests pass, as CI's "Terminal app" job runs them.
- After every build or test command, `./scripts/sign-dev.sh`, so that the installed daemon stays
  signed.
- CI and the Guest workflow are green.
- `scripts/integration-test.sh` passes, and the pull request records the development
  measurements and the owner's official run under "Speed targets".

The owner confirms, with the branch's build and guest files installed, using the signed `maw`
by its full path (it is not on the owner's `PATH`). The session gives every command.

After A:
- in a shell in `Ubuntu-24.04`, `python3 -m http.server 8000` runs, and on the Mac
  `curl -s localhost:8000 | head -3` prints the directory listing's first lines, and Safari opens
  `http://localhost:8000`;
- the distributions screen shows `forwarded  localhost:8000 → 8000` for `Ubuntu-24.04` while
  the server runs, and no row after it stops;
- `python3 -m http.server 8001 --bind 127.0.0.1` is reachable as `localhost:8001` on the Mac;
- with a Mac program listening on a port (the session gives one), a guest server on that port
  is not forwarded, the Mac program keeps it, and the screen shows the reason;
- no macOS question appeared, or the owner reports what appeared;
- `Ubuntu-24.04` is otherwise unchanged.

After B:
- `maw -- getent hosts github.com` prints an address, and `maw -- resolvectl status` shows the
  agent's resolver as the DNS server;
- right after `maw --terminate Ubuntu-24.04`, `maw -- getent hosts github.com` answers within
  1 second;
- if the owner has a VPN: with it connected, a name that only the VPN knows resolves in Linux,
  and after disconnecting it does not; otherwise the same with a scoped resolver file that the
  session gives the commands for;
- in a shell in `Ubuntu-24.04`, `sudo apt update` works;
- `Ubuntu-24.04` is otherwise unchanged.

## How to work

1. Run Part 1 and report its results. Wait for the owner to read them.
2. Present a short plan for A. It must cover: Part 1's results and what follows from each; the
   listener detection and its cost; the forwarding path and why; the conflicts rule; the
   limits; the snapshot field and the interface version; the `forwarded` row; the guest files
   and the procedure to install and return; and an estimate of the added lines outside
   `Tests/`. Wait for approval.
3. Push A early as a draft pull request, as "Guest files" requires; ask the owner to install
   its build and to run A's checks and the official measurements; finish A as described in the
   Workflow section of `CLAUDE.md`. Wait for the owner to merge it.
4. Present a short plan for B from the latest `main`. It must cover: the macOS API and why;
   where the agent listens and how systemd-resolved is pointed at it at every boot; the
   failure behavior and any fallback; the limits; the protocol change, if any; and an estimate
   of the added lines outside `Tests/`. Wait for approval.
5. Push B early as a draft pull request, ask the owner to install its build and to run B's
   checks and the official measurements, and finish B as for A.
