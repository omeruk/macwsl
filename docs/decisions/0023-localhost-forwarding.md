# 0023: Ports on which a distribution listens reach the Mac's loopback addresses through the agent

- Status: Accepted
- Date: 2026-11-23

## Context

Phase 08 ([prompt](../../prompts/08-networking.md)) makes a server in a distribution reachable
from the Mac as `localhost`, as WSL's `localhostForwarding` does. The owner decided four
things before the work began:

1. forwarding is automatic, TCP only, and on the Mac's `127.0.0.1` and `::1` only;
2. the Mac's ports come first: a port in use on the Mac, or forwarded for another
   distribution, is not forwarded, and no other port is chosen instead;
3. DNS goes through the Mac's resolver (pull request B, decision record 0024);
4. the network device stays NAT through `VZNATNetworkDeviceAttachment`
   ([0014](0014-network-in-phase-05.md)).

Before the plan, a throwaway build measured what the plan depends on. Unless a figure says
otherwise, it was taken on 2026-11-23 on an M1 Pro with 16 GB, macOS 27.0.1, with guest files
`217aabb` (Linux 6.18.57), on test distributions under the test daemon. The Mac was in use;
the load averages were 1.9 to 5.3.

## What the platform does

**Reaching the guest's NAT address.** The guest had `192.168.64.2` and no global IPv6 address.

- `curl` from the test process reached a guest listener on `0.0.0.0` (HTTP 200, connect
  2 ms). A listener on the guest's `127.0.0.1` was refused, as expected: the NAT path cannot
  reach it.
- The daemon's own `connect` to the same address failed with `EHOSTUNREACH` ("No route to
  host"), and macOS asked the owner a Local Network question naming `mawd`
  (`UserEventAgent: LocalNetwork: found bundle id dev.maw.mawd by PID`). After the owner
  allowed it, the daemon connected in 1.5 ms. The owner has since turned the permission off
  again, so that the acceptance checks show what a new user sees.
- With a VPN connected: not measured; the owner chose not to run it.

**Seeing the guest's listeners.** One process in the guest, on an idle machine, scanning every
listening TCP socket of both families; CPU time over 60 seconds; the delay is from `listen()`
or `close()` to the scan that saw it, median and slowest of 20.

| Method | Per scan | CPU per minute at 250 ms | at 500 ms | at 250 ms, 2,004 sockets | Delay at 250 ms | Delay at 500 ms |
|---|---|---|---|---|---|---|
| `/proc/net/tcp` and `tcp6` | 3.3 ms | 803 ms | 387 ms | 2,877 ms | 129 / 250 ms | 259 / 500 ms |
| netlink `sock_diag` | 0.13 ms | 51 ms | 28 ms | 53 ms | 102 / 227 ms | not measured |

`/proc/net/tcp` walks the kernel's whole established-socket hash table, whose size follows the
machine's memory, even when it holds two sockets; `sock_diag` asks for listening sockets only.
A close was seen in a median of 122 ms (slowest 246 ms) at 250 ms. `sock_diag` reported the
listening address of each socket, systemd-resolved's `127.0.0.53` and `127.0.0.54` included.
`CONFIG_INET_DIAG` and `CONFIG_INET_TCP_DIAG` were already set by `olddefconfig`.

**Carrying a connection.** A 1 GiB response and 100 short requests, 5 runs alternating between
a forwarded connection through a relay in the daemon and one in the guest, over guest-opened
vsock connections, and a direct connection to the NAT address, from the same server in the
guest:

| | Forwarded over vsock | Direct to the NAT address |
|---|---|---|
| 1 GiB throughput | 383 to 388 MB/s | 7,540 to 7,735 MB/s |
| Time to the first byte, median of 100 requests per run | 0.544 to 0.609 ms | 0.246 to 0.304 ms |

Every 1 GiB response arrived with the expected SHA-256 on both paths. In the daemon, the median
time from accepting the Mac's connection to the guest's dialed connection arriving was 270 µs
(slowest 2.65 ms, 511 connections). A half-close was carried (the guest saw the end of the
request and answered), and a connection to a port on which the guest did not listen reset the
Mac's connection within 1.7 ms. The forwarded path reaches 63 % of what
[0017](0017-dial-back-for-sessions.md) measured for a guest-opened vsock connection with no maw
code (608 MB/s); the rest goes on a copy through user space on each side, in 256 KiB pieces.
The NAT path never crosses vsock.

**Listening on the Mac.** The test daemon, a LaunchAgent, bound `127.0.0.1` and `::1`:

- Ports 80, 443, and 1023 failed with `EACCES` (errno 13) on both addresses. macOS lets a
  program that is not root bind a port below 1024 only on the wildcard address.
- Ports 8000 and 9500 bound in 39 to 86 µs. No firewall or privacy question appeared for the
  loopback addresses.
- Against a Mac program (Apple's `/usr/bin/python3`):

  | The Mac program holds | Daemon without `SO_REUSEADDR` | Daemon with `SO_REUSEADDR` |
  |---|---|---|
  | `127.0.0.1` | `127.0.0.1`: `EADDRINUSE`; `::1`: bound | the same |
  | `0.0.0.0` | `127.0.0.1`: `EADDRINUSE`; `::1`: bound | both bound, and `127.0.0.1` takes the program's loopback traffic |
  | `::`, dual-stack | both `EADDRINUSE` | both bound |
  | `::1` | `127.0.0.1`: bound; `::1`: `EADDRINUSE` | the same |

- The reverse, with the daemon already holding both addresses: a Mac program binding `0.0.0.0`
  or `::` without `SO_REUSEADDR`, or `127.0.0.1` or `::1` in any way, gets `EADDRINUSE`. With
  `SO_REUSEADDR`, its bind to `0.0.0.0` or `::` succeeds, but connections to `127.0.0.1` and
  `::1` still reach the daemon.

**A port that the forward held a moment ago.** Measured during the implementation, on the same
Mac, with Apple's `/usr/bin/python3` and the daemon's own sockets: `net.inet.tcp.msl` is 15000
(milliseconds), so a connection in TIME_WAIT lasts 30 seconds.

- When the listening side closes a connection first, as the daemon's side of a forwarded
  connection does when the guest's server closes first, the listening side's socket stays in
  TIME_WAIT. A later bind of the same address and port without `SO_REUSEADDR` failed with
  `EADDRINUSE` for 30.2 seconds; with `SO_REUSEADDR` it succeeded at once. When the client
  closed first, a bind without `SO_REUSEADDR` succeeded at once.
- A connection to the address and port in that state was refused (`ECONNREFUSED`), as with a
  port that no socket holds.
- A bind of `127.0.0.1` or `::1` with `SO_REUSEADDR` succeeded beside a Mac program listening
  on `0.0.0.0` or `::` (dual-stack or not), whether or not that program had set
  `SO_REUSEADDR`, and the connections to that loopback address reached the new socket.
- The kernel's table of TCP sockets, through the sysctls `net.inet.tcp.pcblist`,
  `net.inet.tcp.pcblist64`, and `net.inet.tcp.pcblist_n`, with the public structures
  `struct xinpgen` and `struct xinpcb64` (`netinet/in_pcb.h`) and `struct xtcpcb64`
  (`netinet/tcp_var.h`), returned a reply of 48 bytes, two `xinpgen` headers and no socket,
  to an ad-hoc signed program without entitlements run as the owner, while `netstat -an -p
  tcp` listed 22 listening sockets at the same time. The daemon's own reply was not measured;
  the plan does not depend on it.
- `libproc` (`proc_listpids` and `proc_pidfdinfo`) lists the sockets of the processes that the
  caller may inspect: the user's own. It does not see a listener of root's, such as a system
  service on `127.0.0.1`, or of another user, so a port that it reports free may still be a
  Mac program's.

## Decision

1. **The path is the agent over vsock.** The NAT path needs the Local Network permission for
   `mawd`, which macOS asks the user for, cannot reach a listener on the guest's `127.0.0.1`,
   and would depend on the NAT subnet being reachable while a VPN is connected. The vsock path
   needs no permission and reaches every loopback listener; its 385 MB/s is enough for a
   development server, and it adds 0.3 ms to the time to the first byte.

2. **The channel.** When a distribution's machine reaches the running state, the daemon opens
   one forwarding channel: a connection that the agent dials through the dial-back of 0017,
   with the request `forwarding` (protocol version 8, [docs/protocol.md](../protocol.md)). It is
   off the path of every session. The agent sends `listeners` with the whole set whenever it
   changes; the daemon sends `connect` for each connection that the Mac makes; the agent
   answers a failure with `connectFailed`. A channel that ends while the machine runs is opened
   again after 1 second. The channel does not take one of the agent's 64 session slots
   (`AgentProtocol.maximumConnections`), and the agent allows one channel at a time.

3. **Listeners** come from `sock_diag` every 250 ms, while the channel is open. Only listeners
   on `0.0.0.0`, `::`, `127.0.0.1`, and `::1` count; `127.0.0.53`, `127.0.0.54`, container
   bridges, and the NAT address do not, nor any socket of the agent itself (by inode). The
   cost, 51 ms of CPU per minute on an idle machine (0.085 % of one core), is about a
   sixteenth of `/proc/net/tcp`'s, and with 2,000 sockets about a fiftieth. The kernel fragment
   pins `CONFIG_INET_DIAG=y` and `CONFIG_INET_TCP_DIAG=y`, so that a kernel update that drops
   them fails the build.

4. **A forwarded connection.** For each connection accepted on the Mac, the daemon registers a
   32-byte nonce with a second `DialBackGate`, on vsock port 19801
   (`AgentProtocol.forwardingPort`), and sends `connect` with the port, the family, and the
   nonce. The agent connects to the guest's listener (`127.0.0.1` for a listener on `0.0.0.0`
   or `127.0.0.1`, `::1` otherwise), then dials 19801 from a source port below 1024, sends the
   nonce frame, and copies raw bytes. `ByteRelay` copies on both sides: the end of a stream
   becomes `shutdown(SHUT_WR)` on the other side, and an error resets both connections.

   **Why the relay waits in `poll(2)`.** `ByteRelay` first copied each direction with blocking
   `read(2)` and `write(2)`. On macOS 27 (Darwin 27.0.0), a thread blocked in `read(2)` on a
   stream socket stayed blocked although data or the end of stream was waiting there, and the
   socket polled as readable: the unit tests hung in 1 of about 16 to 250 repetitions, and 10
   of 1,280 relays in a stress test never ended. The same happened without `ByteRelay`, with
   one thread reading a socket while another wrote to it and then shut down its write side,
   for both a Unix socket pair and loopback TCP, where the reading socket held 408,620 unread
   bytes. On the Mac side of a forward, a connection would then have stayed open forever and
   held its two threads and its place among the 256. Each direction now uses nonblocking
   sockets and waits in `poll(2)` for at most one second
   (`ByteRelay.pollIntervalMilliseconds`) before it reads or writes again, so a missed wakeup
   delays a direction by at most one second. The costs are one wakeup per second for each
   direction of an idle connection, on each side, and part of the throughput (see
   "Measurements of the implementation"). In five 1 GiB transfers measured on the Mac's side,
   no wait reached the second; the longest took 18 ms.

   **Why a second gate.** The 19800 gate's 64 waiting nonces and its admission limit of waiting
   sessions plus 4 belong to sessions: a burst of a browser's connections would fail `maw`
   sessions with `sessionDialBackBusy`, and the reverse. A second instance of the same type
   keeps 0017's admission checks, with budgets of its own.

5. **Conflicts.**
   - A port below 1024 is never bound: `privilegedOnMac` (`EACCES` in Part 1).
   - A port that another running distribution forwards is not bound:
     `forwardedForAnotherDistribution`. The first distribution keeps it.
   - The daemon binds `127.0.0.1`, then `::1` with `IPV6_V6ONLY`, through one function
     (`maw_tcp_listen_loopback`), first without `SO_REUSEADDR`. It never sets `SO_REUSEPORT`.
     With either option, the bind to `127.0.0.1` would succeed beside a Mac program on
     `0.0.0.0` and take its loopback traffic.
   - **A port in TIME_WAIT.** When a bind fails with `EADDRINUSE`, the port is either a Mac
     program's or held only by connections in TIME_WAIT that an earlier forward left, for
     30 seconds; without telling the two apart, a server restarted in the distribution within
     30 seconds would stay unforwarded under the no-retry rule below. The daemon connects once
     to the same address (`127.0.0.1` for the IPv4 half, `::1` for the IPv6 half), waits at
     most 500 ms, and closes the connection at once without sending anything
     (`maw_tcp_probe_loopback`). Only `ECONNREFUSED`, nothing listening there, leads to a
     second bind of that address with `SO_REUSEADDR`. An accepted connection, a timeout, or
     any other error leaves the port to the Mac: `inUseOnMac`. The probe runs only after
     `EADDRINUSE`, so at most once per address each time the guest reports the port anew.
     The socket table was not used because macOS returns no records from it to the daemon,
     and `libproc` was not used because it misses the listeners of root and of other users
     (see "What the platform does"). Two costs are accepted:
     - a Mac program that holds the port receives one connection that ends without a byte
       when a server on that port starts in a distribution;
     - between the refused probe and the bind, a window of microseconds, a Mac program that
       starts to listen on the wildcard address of that family, with or without
       `SO_REUSEADDR`, binds first, the daemon's bind with `SO_REUSEADDR` succeeds beside it,
       and the program's loopback connections reach the distribution until the forward ends.
       A Mac program that binds the loopback address itself in that window makes the
       daemon's bind fail instead (`inUseOnMac`).
   - `EADDRINUSE` on either address, after the probe, leaves the port forwarded on neither:
     `inUseOnMac`. Forwarding the free half would send a browser's `localhost` to the
     distribution while a Mac program holds the port. A guest that listens on one family only
     is still forwarded on both Mac addresses.
   - Any other error is `bindFailed`, with the errno in `mawd.log`.
   - **No retry.** A port that was not forwarded is tried again only when the guest reports it
     anew, after its listener went away, or after a restart of the machine. A periodic retry
     would take the port in the gap while a Mac program restarts on it. The distributions
     screen's help text tells the user to restart the server in the distribution once the Mac's
     port is free.

6. **Limits.**

   | Limit | Value | Beyond it |
   |---|---|---|
   | Forwarded ports per distribution | 128 (`PortForwarding.maximumPorts`) | Not forwarded: `limit` |
   | Open forwarded connections per distribution, those waiting for the agent's dial included | 256 | The Mac's connection is accepted and reset |
   | Connections waiting for the agent's dial | 64, the gate's limit | Reset |
   | The agent's open forwarded connections | 256 (`AgentProtocol.maximumForwardedConnections`) | `connectFailed`, and the Mac's connection is reset |
   | Copy buffer | 128 KiB per direction, on each side | The reading side waits |
   | A `listeners` message | 1,024 listeners, ports 1 to 65535, no duplicates | A protocol violation closes the channel |
   | A `connectFailed` reason | 256 bytes | A protocol violation; the reason is never logged |
   | Log lines about ports | 20 per machine per 10 seconds | Counted, and the count logged |

   At the connection limit, the daemon runs two copy threads per connection, an acceptor that
   polls every listening socket, the channel's reader, and at most 68 short-lived nonce
   readers; the agent runs two copy threads per connection, the channel, and at most 64
   short-lived connect threads. With 256 forwarded connections open, the measurement below
   counted 525 threads in the daemon (10 without) and 515 in the agent (5 without). The rule
   set before the implementation: if holding 256 connections open made the median of
   `maw -- true` grow by more than 50 ms, or `maw --list` take more than 1 s, the daemon would
   use a `kqueue` loop instead of two threads per connection. The owner's official run first
   showed the median of `maw -- true` growing by 57.3 ms, an artifact of how the measurement
   timed it. Applied unchanged to the official reruns with the corrected method, the rule is
   met: over 80 runs of each side, the median grew by 8.4 ms, and `maw --list` took at most
   66.5 ms with the connections held (see "The owner's official run"). The threads stay.

7. **The snapshot** carries, for each running distribution, the forwarded ports and the ports
   that were not forwarded with the reason (interface version 9,
   [docs/daemon.md](../daemon.md)). The distributions screen shows the `forwarded` row and the
   reasons in its help text.

## Measurements of the implementation

Development figures, taken on 2026-11-24 with `scripts/measure-forwarding.sh` at commit
`b85a63e`, with the guest files of Guest run 45287694609 at the same commit, through the test
daemon, on the Mac described above, in use (one-minute load average 4.4 at the start). They are
not the owner's official run. Each figure is the median of 5 runs, with the slowest in
parentheses, unless it says otherwise. The figures of 2026-11-23, at commit `ce83bc5` with the
relay's blocking reads, follow in brackets where they differ.

| Measurement | Result |
|---|---|
| From the guest's `listen()` to `localhost` accepting on the Mac | 10.4 ms (124.4 ms) [28.5 ms (37.2 ms)] |
| Time to the first byte, median of 100 requests per run: forwarded | 1.148 ms (1.252 ms) [1.483 ms (1.565 ms)] |
| The same to the NAT address | 0.460 ms (0.681 ms) [0.549 ms (0.562 ms)] |
| Forwarding adds to the time to the first byte | 0.69 ms [0.93 ms] |
| Throughput of a 1 GiB response: forwarded | 303.4 MB/s (288.9 MB/s) [386.6 MB/s (383.9 MB/s)] |
| The same from the NAT address | 5,252.2 MB/s (4,312.9 MB/s) [5,110.6 MB/s (4,507.4 MB/s)] |
| The agent's CPU time per minute on an idle machine: with forwarding | 60 ms (80 ms) [100 ms (120 ms)] |
| The same with `mawd serve --without-forwarding`, as on `main` | 10 ms (20 ms) [10 ms (10 ms)] |
| Cold start to a prompt: with forwarding | 1,000.8 ms (1,039.8 ms) [916.1 ms (949.6 ms)] |
| The same with `mawd serve --without-forwarding` | 1,037.9 ms (1,623.1 ms) [932.8 ms (950.7 ms)] |
| `maw -- true`, median of 20, timed by the first method (see "The owner's official run"): without forwarded connections | 213.2 ms (224.3 ms) [220.0 ms (238.3 ms)] |
| The same with 256 forwarded connections open | 215.0 ms (221.9 ms) [220.6 ms (223.4 ms)] |
| `maw --list`, timed by the first method: without forwarded connections | 164.2 ms (211.7 ms) [216.3 ms (221.6 ms)] |
| The same with 256 forwarded connections open | 163.1 ms (165.6 ms) [216.1 ms (219.4 ms)] |
| Threads with 256 forwarded connections open: daemon, agent | 526, 515 (9 and 5 without) [525, 515 (10 and 5 without)] |
| 256 connections opened at once, still open after 2 s | 155 of 256 |

Timed by the first method, holding 256 connections open added 1.8 ms to the median of
`maw -- true` in this run, and `maw --list` took 163.1 ms. The cold start with and without forwarding differs
by less than the spread of either; the difference has no sign that repeats across runs.

Of 256 connections opened at once, the daemon resets those that find the 64 waiting places of
the 19801 gate taken, so the count still open varies with how fast the agent dials back: 155
and 211 on 2026-11-24, and 154, 225, and 255 in the runs of 2026-11-23.

The agent's CPU time is counted in clock ticks of 10 ms, so the figures without forwarding
are at the resolution of the measurement. Forwarding adds about 50 ms per minute, 0.08 % of
one core; the scan alone cost 51 ms per minute in the throwaway build.

**Where the throughput limit comes from.** The forwarded path crosses vsock once, and each side
copies every byte through user space: in the agent from the guest's TCP socket to the vsock
connection, in the daemon from the vsock connection to the Mac's TCP socket. A guest-opened
vsock connection with no maw code carried 608 MB/s in
[0017](0017-dial-back-for-sessions.md). The throwaway build copied in 256 KiB pieces and
measured 383 to 388 MB/s; the implementation with blocking reads copied in 128 KiB pieces and
measured 384 to 388 MB/s, so the size of the copy buffer is not the limit. Since the relay
waits in `poll(2)`, the medians of 13 runs of the throughput measurement on 2026-11-24 were
303 to 364 MB/s, the two lowest in the runs with the whole suite. The cost is on the Mac's
side: there each read from the vsock connection returns 8 KiB, and about 87,000 of the 131,073
reads of a 1 GiB transfer are followed by a read that finds nothing and a `poll(2)`. A
diagnostic build in which only the daemon's relay read with blocking calls measured a median of
375.5 MB/s in the same conditions. The prompt sets no throughput target, and the owner
accepted this cost of the waits in `poll(2)`. A copy without user space, `splice` in the guest,
was not tried: it needs a pipe between the two sockets, and the Mac's side, where `splice` does
not exist, would still copy.

## The owner's official run

Taken by the owner at commit `a9305c7`, with the guest files of Guest run 45287694609
(`b85a63e`), 8 minutes after a restart, with `caffeinate -dims scripts/measure-forwarding.sh`
under the conditions in the script; the one-minute load average was 1.49 (the 5- and
15-minute ones, 18.16 and 16.29, still counted the restart). Nothing was left behind. These
five figures are the official ones.

| Measurement | Target | Result |
|---|---|---|
| From the guest's `listen()` to `localhost` accepting on the Mac | under 1 s | 16.7 ms (147.5 ms): met |
| Time to the first byte, median of 100 requests per run: forwarded, against the NAT address | adds under 5 ms | 1.677 ms (1.883 ms) against 0.575 ms (0.587 ms), so 1.10 ms: met |
| Throughput of a 1 GiB response: forwarded, against the NAT address | report | 368.1 MB/s (363.8 MB/s) against 5,120.6 MB/s (4,603.9 MB/s) |
| The agent's CPU time per minute on an idle machine: with forwarding, against `mawd serve --without-forwarding` | report | 60 ms (80 ms) against 10 ms (10 ms), so 50 ms |
| Cold start to a prompt: with forwarding, against `mawd serve --without-forwarding` | adds under 20 ms | 879.7 ms (919.7 ms) against 871.1 ms (949.4 ms), so 9 ms: met |

The same run counted 524 threads in the daemon and 515 in the agent with 256 forwarded
connections open (11 and 5 without), and 239 of 256 connections opened at once still open
after 2 s.

**The sessions beside 256 connections, timed by the first method.** In the same run, the
median of 20 runs of `maw -- true` was 170.1 ms (232.9 ms) without held connections and
227.4 ms (234.4 ms) with them: 57.3 ms more, against the rule's 50 ms. `maw --list` took
170.1 ms, within its 1 s. The times of `maw -- true` fell into two clusters, about 166 to
175 ms and about 218 to 234 ms: 11 of 20 runs without connections were in the faster one, and
1 of 20 with them.

The clusters came from the measurement. It ran each command through the integration tests'
wait for an exit, which looks every 50 ms whether the process has exited and then sleeps
100 ms to collect the last output, and it timed the whole wait. Every time it reported was
therefore 100 ms plus one or two polling ticks of about 55 to 60 ms. Timed instead from just
before the process started to its termination, as its termination handler records it, three
development runs through the test daemon gave one cluster each: medians of 50.6, 51.0, and
52.7 ms without held connections, against 64.1, 64.8, and 64.4 ms with them, while the first
method's figures in the same runs still grew by 54.8 and 55.5 ms. `maw` itself takes about
as long as one polling tick, so most runs without the connections ended before the first
tick and most runs with them after it, and a difference of about 12 ms appeared as a whole
tick. The part of that difference that the daemon's log shows, from a session's opening to
its closing, was 11.5 ms against 19.0 ms; the agent's `fork(2)` accounts for about 0.3 ms
of it ([docs/known-limitations.md](../known-limitations.md)).

The measurement's method was changed before the reruns, not after them: the measurement now
times each `maw -- true` and `maw --list` from just before its start to its termination, with
no polling or sleep in what is timed. The rule and its threshold are unchanged, and the other
integration tests keep their wait.

**The official reruns.** The owner ran `scripts/measure-forwarding.sh
measuresSessionsBeside256Connections` at commit `5541cbc`, with the guest files of `b85a63e`,
after a restart. Of four runs back to back, only the first started under a one-minute load
average of 2 (1.67); the other three started at 3.74, 3.17, and 2.66 and were discarded. Three
more runs each waited until the load average was under 2. The four valid runs, each with the
medians of 20 runs of `maw -- true` without and with 256 forwarded connections held open:

| Run | Load at the start | `maw -- true` without | With 256 held | Difference | `maw --list` with 256 held | Still open of 256 opened at once |
|---|---|---|---|---|---|---|
| 1 | 1.67 | 66.778 ms | 61.424 ms | −5.4 ms | 43.2 ms | 255 |
| 2 | 1.80 | 87.186 ms | 94.304 ms | +7.1 ms | 64.5 ms | 255 |
| 3 | 1.91 | 86.294 ms | 94.861 ms | +8.6 ms | 66.5 ms | 194 |
| 4 | 1.83 | 86.023 ms | 95.270 ms | +9.2 ms | 64.8 ms | 255 |

Over the 80 values of each side together, as the owner computed them, the median was
85.38 ms without held connections and 93.76 ms with them: 8.4 ms more, within the rule's
50 ms, and `maw --list` stayed under its 1 s. The rule is met, and the daemon keeps two threads
per connection. Run 1's times were about 20 ms lower on both sides than those of runs 2 to 4;
the cause of that difference was not examined.

## Consequences

- No question from macOS: the daemon listens on loopback addresses only and never connects to
  the NAT network. Its probes connect to the Mac's own loopback addresses only.
- A server on a port below 1024, such as a web server on port 80, is not reachable as
  `localhost`; the screen says so ([docs/known-limitations.md](../known-limitations.md)).
- A Mac program that starts after a distribution forwards its port, and sets `SO_REUSEADDR` as
  Python's `http.server` does, binds the wildcard address but does not receive the loopback
  connections until the forward ends ([docs/security.md](../security.md)).
- The forwarded throughput, 368 MB/s in the owner's official run and 303 to 364 MB/s in 13
  development runs, is less than a tenth of the NAT path's (5,121 MB/s in the official run,
  medians of 4,192 to 5,946 MB/s in the same 13 runs, and 5,111 to 7,735 MB/s before).
- The machine's idle stop counts sessions only: a forwarded connection does not keep a machine
  running (phase 12).
- UDP is not forwarded.
