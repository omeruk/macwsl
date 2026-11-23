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

   **Why a second gate.** The 19800 gate's 64 waiting nonces and its admission limit of waiting
   sessions plus 4 belong to sessions: a burst of a browser's connections would fail `maw`
   sessions with `sessionDialBackBusy`, and the reverse. A second instance of the same type
   keeps 0017's admission checks, with budgets of its own.

5. **Conflicts.**
   - A port below 1024 is never bound: `privilegedOnMac` (`EACCES` in Part 1).
   - A port that another running distribution forwards is not bound:
     `forwardedForAnotherDistribution`. The first distribution keeps it.
   - The daemon binds `127.0.0.1`, then `::1` with `IPV6_V6ONLY`, through one function
     (`maw_tcp_listen_loopback`), which never sets `SO_REUSEADDR` or `SO_REUSEPORT`. With
     either, the bind to `127.0.0.1` would succeed beside a Mac program on `0.0.0.0` and take
     its loopback traffic.
   - `EADDRINUSE` on either address leaves the port forwarded on neither: `inUseOnMac`.
     Forwarding the free half would send a browser's `localhost` to the distribution while a
     Mac program holds the port. A guest that listens on one family only is still forwarded on
     both Mac addresses.
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

   At the connection limit, the daemon runs about 582 threads for that distribution (512 copy
   threads, an acceptor that polls every listening socket, the channel's reader, and at most 68
   short-lived nonce readers), and the agent about 578 (512 copy threads, the channel, and at
   most 64 short-lived connect threads). The measurements hold 256 connections open: if the
   median of `maw -- true` grows by more than 50 ms, or `maw --list` takes more than 1 s, the
   daemon uses a `kqueue` loop instead of two threads per connection.

7. **The snapshot** carries, for each running distribution, the forwarded ports and the ports
   that were not forwarded with the reason (interface version 9,
   [docs/daemon.md](../daemon.md)). The distributions screen shows the `forwarded` row and the
   reasons in its help text.

## Consequences

- No question from macOS: the daemon listens on loopback addresses only and never connects to
  the NAT network.
- A server on a port below 1024, such as a web server on port 80, is not reachable as
  `localhost`; the screen says so ([docs/known-limitations.md](../known-limitations.md)).
- A Mac program that starts after a distribution forwards its port, and sets `SO_REUSEADDR` as
  Python's `http.server` does, binds the wildcard address but does not receive the loopback
  connections until the forward ends ([docs/security.md](../security.md)).
- The forwarded throughput is about a twentieth of the NAT path's.
- The machine's idle stop counts sessions only: a forwarded connection does not keep a machine
  running (phase 12).
- UDP is not forwarded.
