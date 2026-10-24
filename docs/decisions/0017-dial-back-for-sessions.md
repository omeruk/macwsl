# 0017: The guest agent dials each session's connection

- Status: Accepted
- Date: 2026-10-24

## Context

Until this decision, the host opened every connection to the guest agent with
`VZVirtioSocketDevice.connect(toPort:)`, sessions included. Once the host stops reading such a
connection, Virtualization.framework's vsock device stops carrying the whole machine's
traffic. While nobody read the output of one `maw -e yes`, another session of the same machine
stopped delivering output within a second, a new session could not connect within 5 s, and
Ctrl-C to the unread session was sent but did not arrive. The same happened while a `maw`
process was stopped with SIGSTOP. A sample of the machine's process showed the serial queue
`com.apple.virtualization.virtio.vsock-device:0` in `writev` for 3 s out of 3 s.

`scripts/measure-vsock-buffer.sh` measured the cause on an M1 Pro with macOS 27.0.1. The host's
descriptor is one end of a Unix stream socket pair whose other end the machine's process
holds, and the device blocks once **8,192 bytes** wait in it: the default send buffer of a
Unix stream socket (`net.local.stream.sendspace`), with a low-water mark of 2,048 bytes, so
that it may block from 6,145 bytes on. `SO_RCVBUF` on the host's descriptor is accepted but
changes nothing, in the process that opened the connection and in one that received it over
`SCM_RIGHTS` alike; the sending end is in the machine's process, beyond maw's reach. The stall
also reached the console: during host-initiated stalls, a line typed into the guest's shell
was not echoed within 2 s in 5 of 9 runs. Why the console stopped in some runs and not in
others is not established.

A third-party project, onexay/msl (a `wsl.exe`-compatible Linux environment on Apple
silicon), reported the same freeze, and reported that it occurs only on connections that the
host opens: on a connection that the guest opened to a `VZVirtioSocketListener`, the host
stopped reading for 20 to 30 s, the guest's writer blocked, and the machine stayed
responsive. That was a single report, not confirmed by Apple, so it was measured on this
setup before anything was built on it (see "Evidence").

## Alternatives considered

The first three keep host-opened connections and add a window for the output direction, as
0016 added one for input. Their costs were estimated, not measured.

1. **An output window that fits the host's buffer.** The agent sends at most 4 KiB of output
   that the host has not acknowledged: the 6,145 bytes that are guaranteed, less the control
   frames and a margin. The machine would never stall while the platform keeps its
   8,192-byte default, but a window of 4 KiB per round trip of about 95 µs allows at most
   about 43 MB/s, against about 240 MB/s at the time. Rejected for the throughput, and because
   the size depends on a default that Virtualization.framework sets and may change.
2. **A 1 MiB output window, and a host that never stops reading.** The receiving
   `GuestProcess` acknowledges output once its handler has taken it. The cost would be close to
   the input window's. The machine still stalls whenever the receiving process does not run:
   a `maw` stopped with SIGSTOP, Ctrl-Z on a `maw -e` in pipe mode, or a debugger. Rejected,
   because the stall remains for those cases, which the owner named.
3. **A relay in `mawd`.** The daemon always reads the vsock connection and forwards the bytes
   into a socket pair whose send buffer it sizes above a 1 MiB window. The machine never stalls,
   but every byte of a session passes through the daemon, which the architecture excludes
   (CLAUDE.md, "terminal bytes do not pass through the daemon"), with one more copy and one
   more thread per session. Rejected.
4. **A custom virtio device (`VZCustomVirtioDevice`).** It lets the host implement a
   device's queues itself, and so control its back-pressure. The SDK marks it
   `API_AVAILABLE(macos(27.0))`, while maw supports macOS 14 and later, and maw would have to
   implement the device itself: the virtio vsock protocol, or a protocol of its own with a
   guest driver for it. Rejected.
5. **Dial-back.** The agent opens each session's connection to a host listener. Chosen.

## Decision

1. **Every exec session runs on a connection that the agent dials**: `maw` in pipe and
   terminal mode, the installer's provisioning commands, and `mawd debug-boot --exec` and
   `--shell`. There is no fallback to a host-opened session connection. The host opens
   connections only for `info`, `shutdown`, and the `dialBack` request itself.
2. **The listener.** While a machine runs, `mawd` holds a `VZVirtioSocketListener` on the
   machine's vsock device for port **19800** (`AgentProtocol.dialBackPort`). It sets the
   listener when the machine reaches the running state, and removes it when the machine stops
   (`VirtualMachine.listenForDialBacks`, `didStop`).
3. **The request.** For each session, the host opens a connection to the agent, exchanges
   versions, and sends `dialBack` with a nonce of **32 bytes**
   (`AgentProtocol.dialBackNonceSize`) from the system's random number generator. The agent
   binds the highest free source port below 1024, counting down from 1023 and skipping ports
   in use, connects to port 19800 within **2 seconds**, queues a `dialBackNonce` frame as the
   connection's first frame, replies `dialedBack`, and serves the dialed connection like a
   new one, in the request connection's slot of its 64. If it cannot, it replies
   `dialBackFailed` with the reason. The protocol version becomes 3 (docs/protocol.md,
   "Dial-back").
4. **The nonce is the boundary.** The host gives the connection to a session only if its first
   frame carries a nonce that a session of that machine waits for. A nonce is used once, is
   valid for **5 seconds** from the request, is compared in constant time, and is never logged.
   The source port below 1024 only filters (docs/security.md).
5. **The input window of 0016 stays.** It keeps `signal` and `resize` moving while the guest
   process does not read its input; the direction of the connection does not change that. The
   output window and draining before a stop, which options 1 and 2 needed, are not built.

### The exception to "Nothing listens on the Mac for the guest"

Phase 05 set the rule that nothing on the Mac listens for the guest (also in
[0014](0014-network-in-phase-05.md)). The listener is an exception that the owner accepted,
for these reasons:

- It is not a network socket. It exists inside `mawd`'s process, on one machine's vsock
  device, and only that machine's guest can reach it. Nothing on the Mac's network stack
  listens, and neither other machines nor other hosts can connect to it.
- It exists only while its machine runs.
- It gives a guest process nothing without a nonce of a waiting session, and it reads at most
  one 37-byte frame from a connection before that check.
- The alternative leaves the stall: one session that the host does not read stops every
  session of the machine, new sessions, and possibly the console.

## Admission

`DialBackGate` (`Sources/MawVirtualization/DialBackGate.swift`) checks each connection to the
listener in two stages.

1. **Before anything is read**, on the machine's queue, it refuses a connection:
   - from a source port of 1024 or above;
   - while no session of the machine waits for a connection;
   - once as many admitted connections have not yet sent their nonce as there are waiting
     sessions plus 4 (`Limits.extraUnauthenticatedConnections`).
2. **On a thread of its own**, it reads exactly the 37 bytes of the nonce frame within
   **2 seconds** (`Limits.nonceReadTimeout`), and nothing more, so that the session's bytes stay
   in the socket for the client. It closes a connection whose frame does not arrive in time, is
   malformed, or carries a nonce that no session waits for.

At most 64 sessions of a machine wait at once (`AgentProtocol.maximumConnections`, the agent's
own limit); one more fails with `sessionDialBackBusy`. Refusals go to the machine's console
log, at most 5 in 10 seconds.

**Why waiting sessions plus 4.** Step 4a admitted at most 4 connections without a nonce, a
fixed limit. In a burst, more than 4 of the agent's own dials were admitted before their
nonces had been read, and the gate refused the rest: in two integration runs, 18 and 1 of
32 parallel `maw -e true` failed, and 7 and 1 of 32 login shells; in seven bursts started
from a shell, 4 of 320 sessions. With one place for each waiting session, each session's own
dial finds a place however many sessions open at once. The 4 further places, the former
limit, cover connections whose session stops waiting while they are read, because its nonce
expired or its client went away: such a connection keeps its place until it is read, and
would otherwise take the place of another session's dial. The limit still bounds what a guest
process can hold: with no session waiting it is zero, and every connection is refused before
anything is read. Two other limits were considered: a fixed limit of 64 would let a guest
process hold 64 of the daemon's threads for 2 s each while any session opens; counting only
connections that are slow to send their nonce would keep a tight limit, with more code to get
right.

**Why the agent does not retry.** With this rule the gate never refuses a legitimate dial for
lack of a place, so a retry would only hide a future fault. A refused dial fails its session
with `sessionDialBackFailed`, which the user sees, and the console log records the refusal.

## Evidence

All measured on one M1 Pro (8 CPUs, 16 GiB) with macOS 27.0.1.

**Guest-initiated connections do not stall the machine** (`scripts/measure-vsock-buffer.sh
--guest-initiated`, two complete runs, load average 3.0 to 4.6). A guest program wrote 16 MiB
(1 GiB in the stopped case) while the host read nothing. "Answers" means that a new connection
of that kind opened and was used, or that a line typed into the console was echoed, within
2 s.

| Variant (runs) | Host socket held | Guest writer blocked at | Host-opened answers | Guest-opened answers | Console answers | All bytes after reading |
|---|---|---|---|---|---|---|
| Host-opened, agent session (6) | 7,218 or 8,192 | 0 to 46 chunks of 8 KiB | 0 of 6 | 0 of 6 | 4 of 6 | yes |
| Host-opened, test program, raw bytes (3) | 8,192 | 262,144 bytes | 0 of 3 | 0 of 3 | 0 of 3 | yes |
| Guest-opened, opening process (6) | 8,192 | 262,144 bytes | 6 of 6 | 6 of 6 | 6 of 6 | yes |
| Guest-opened, handed over by `SCM_RIGHTS` (6) | 8,192 | 262,144 bytes | 6 of 6 | 6 of 6 | 6 of 6 | yes |
| Guest-opened, reading process stopped with SIGSTOP (6) | 8,192 | 141 to 157 MB of 1 GiB | 6 of 6 | 6 of 6 | 6 of 6 | yes |
| Guest-opened, 60 s stall (2 + 2) | 8,192 | 262,144 bytes | all | all | all | yes |

In every case the host socket was full and the machine's end had no send room. On a
guest-opened connection only its writer blocked; on a host-opened one the whole device stopped.

**The cost of a dial.** With a test program in the guest, 200 dials per run, two runs: from
the host's request to holding the dialed descriptor, a median of 82 and 100 µs (95th
percentile 140 and 179 µs), against 158 and 188 µs for `connect(toPort:)` to the agent. With
the agent itself (step 3), 50 of 50 dials were accepted, each from source port 1023: from
opening the request connection to holding the dialed descriptor, a median of 262 µs (95th
percentile 295 µs).

**The freeze tests** (`Tests/mawdTests/FreezeIntegrationTests.swift`) run `seq 1 inf` in one
session and freeze it four ways: standard output not read, terminal output not read, `maw`
stopped with SIGSTOP, and with SIGTSTP. While it is frozen, five `maw -e true` on the same
machine took medians of 35, 48, 41, and 40 ms, and an interactive prompt appeared in 83 to
133 ms; each resumed session then delivered a further million lines in order and ended with
status 130. Against a temporary build whose sessions used host-opened connections, all four
tests failed within 41 s each: every `maw -e true` failed after about 5.3 s, and no prompt
appeared within 10 s. `DaemonIntegrationTests.passesSIGINTWhileTheOutputIsNotRead`, disabled
while sessions used host-opened connections, passes: the signal reaches the guest in a median
of 14 ms.

**Bursts.** With the limit of waiting sessions plus 4, 32 parallel `maw -e true`, 64 parallel
`maw -e true`, and 32 login shells each ran 7 times with no failed session, no gate refusal,
no missing dial-back, and no `busy` reply from the agent. The bursts took 215 to 261 ms, 381
to 407 ms, and 336 to 541 ms to the last prompt. With the fixed limit of 4, the burst unit test
fails for 32 sessions (28 refusals) and 64 (60 refusals).

**The guest's side of the boundary** (`Tests/mawdTests/DialBackSecurityTests.swift`). An
unprivileged guest process cannot bind port 1000 (EACCES), and its dial from a port the kernel
chooses is refused; a root dial from port 1000 is refused while no session waits; while a
session waits, a root dial with a wrong nonce is admitted, closed after its nonce frame, and
receives nothing, and the waiting session still gets its own connection. The console log
lists the refusals and contains no nonce.

**The agent stays up.** `scripts/integration-test.sh` fails a run in which any boot started the
agent more than once, and keeps the logs and the agent's journal. A temporary test that killed
the agent made the run fail although every test passed.

**What it costs.** The host of the commit before the dial-back (`f72af20`) and the host of
`695f26f` were compared with the same guest files, one test distribution, and one test daemon
reinstalled from each build in turn, in 12 blocks in the order ABBA (load average 1.7 to 4.0):

| Measurement | Host-opened sessions | Dial-back | Difference |
|---|---|---|---|
| Cold `maw -e true`, median of 12 | 501 ms | 506 ms | +0.9 % |
| Warm `maw -e true`, median of 180 | 31 ms | 33 ms | +2 ms, +7.6 % |
| Warm prompt, median of 18 | 118 ms | 118 ms | 0 |
| 1.3 GB of output from the guest, median of 6 | 2,455 ms | 2,996 ms | +22 % |
| 1.3 GB of input to the guest, median of 6 | 4,761 ms | 4,755 ms | 0 |

- **The 2 ms of a warm session** are the `dialBack` exchange. In a build with temporary timing
  in the daemon (8 blocks of 50 sessions), opening a session took a median of 505 µs with
  host-opened sessions and 2,285 µs with the dial-back: 1,998 µs until the agent's
  `dialedBack` reply, which includes the request connection, its version exchange, and the
  agent's dial, and 82 µs more until the dialed connection was in hand. How the 1,998 µs
  divide between those steps was not measured.
- **The output cost lies in the transport.** With no maw code involved, a test program in the
  guest wrote 1.3 GB to a host process that read at once, 7 times in each direction,
  alternately: a median of 1,281 ms (1,015 MB/s) on connections that the host opened, and
  2,137 ms (608 MB/s) on connections that the guest opened. Virtualization.framework carries a
  guest-opened connection about 40 % slower; through maw the difference is 22 %. Why the
  framework is slower in this direction is not established.

## Consequences

- **One Mac, one macOS version.** The behavior that this decision relies on was measured on
  macOS 27.0.1 on one M1 Pro. macOS 14 to 26, which maw supports, are untested.
- **Undocumented behavior.** Apple documents neither the stall on host-opened connections nor
  its absence on guest-opened ones. A later macOS could change either.
- **Detecting a regression.** The freeze tests, the SIGINT test, the burst tests, and the
  security test fail if a session stalls the machine again, if the gate refuses the agent's own
  dials, or if it admits a dial it should refuse; the integration script fails a run in which
  the agent restarted. They run wherever `scripts/integration-test.sh` runs, on a Mac that is
  not itself a virtual machine; CI does not run them, and nothing detects a regression on a
  user's Mac.
- **The remaining host-opened connections are safe from the stall.** They carry `info`,
  `shutdown`, and `dialBack`. Each reply is one small control message after the 9-byte version
  frame: `agentInfo`, `shutdownAcknowledged`, `dialedBack`, or an `error`, far below the 6,145
  bytes from which the device may block. The daemon reads each reply in full on a thread of its
  own, within 10 seconds, then closes the connection, and never hands such a connection to a
  client. An agent replaced by guest root could send more on them; that would affect only its
  own machine, which guest root can stop in other ways.
- **Opening a session costs one more exchange**: a host-opened connection with its version
  exchange and the `dialBack` reply, before the dialed connection's own version exchange. A
  warm `maw -e true` takes 2 ms longer, against a target of 50 ms.
- **Output from the guest is slower**: 383 to 434 MB/s through `maw -e` in these
  measurements, against 474 to 536 MB/s with host-opened sessions, because
  Virtualization.framework carries guest-opened connections more slowly.
  Phase 05 sets no throughput target. Input and interactive latency are unchanged.
- **Guest root can make session opens fail** while a session opens, by holding the places for
  connections without a nonce or by binding every source port below 1024
  (docs/security.md). It cannot obtain a session without the nonce.
- **0014's statement** that nothing listens on the Mac for the guest holds for the network;
  this record qualifies it for vsock.
