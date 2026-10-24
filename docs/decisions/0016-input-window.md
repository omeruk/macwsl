# 0016: Control messages overtake standard input, within an input window

- Status: Accepted
- Date: 2026-10-23

## Context

An exec session carries the process's standard input and the host's control messages
(`stdinEOF`, `signal`, `resize`) on one connection, in one ordered stream. Until this decision,
the host queued control messages behind its unsent input, and the agent stopped reading the
connection while 256 KiB of input waited for the process. A process that does not read its
input therefore never received a signal or a window size sent after the input: Ctrl-C did
nothing in `yes | maw -e sleep 1000`, and a resize waited behind a large paste.

Reordering on the host alone does not solve this. Once input is in the socket, a control
message sent after it can only arrive after it, and the agent stopped reading at its limit.
The agent must therefore be able to read the connection at all times, without its memory
growing with the input that the process leaves unread.

Protocol version 2 has not been released, so it can change without a new version number.

## Decision

1. **An input window.** The host has at most `AgentProtocol.inputWindow` (1 MiB) of `stdin`
   payload outstanding: sent, and not yet returned. The agent returns input it has written to
   the process, or discarded, in a `stdinConsumed` frame (type `0x03`, a 4-byte byte count) once
   256 KiB has accumulated. The input waiting in the agent is therefore never more than the
   window, so the agent reads the connection at all times and acts on each control message as
   it arrives. Input beyond the window is a protocol violation, and the agent closes the
   connection.
2. **Control messages first.** The host keeps `signal` and `resize` in a queue of their own and
   sends it before its queued input. Each signal is queued once, as a process's pending signals
   are, and only the latest size, so that the queue stays small.
3. **`stdinEOF` stays in order** behind the input before it, in the input's queue. It ends the
   input once; input that follows it, and a second `stdinEOF`, have no effect.
4. One connection per session, as before.
5. **The host's I/O thread never waits for the output handler.** It queues the process's output
   for a thread of its own, which hands it to the handler, and stops reading the connection
   while 256 KiB (`GuestProcess.outputLimit`) waits there. A signal or a resize is therefore
   sent while a write to the Mac's standard output blocks. Before, the I/O thread called the
   handler itself, and a `maw -e` whose standard output nobody read never sent Ctrl-C. (Added
   on 2026-10-24.)

## The window's size and the report's form

The returns cost throughput over vsock: each is a packet from the guest and a wake-up of the
host's I/O thread. Streaming 1.3 GB from `/dev/zero` into `cat > /dev/null` through `maw -e`,
with each variant interleaved with the build before this decision (M1 Pro; the Mac's load
average was between 2 and 8 during these runs, so only the differences within one run are
meaningful):

| Window, return threshold, form | Stream, median of 9 | Previous build, same run |
|--------------------------------|---------------------|--------------------------|
| 256 KiB, 64 KiB, a JSON control message | 5142 ms (+4.2 %) | 4933 ms |
| 256 KiB, 64 KiB, a binary frame | 5057 ms (+2.8 %) | 4921 ms |
| 1 MiB, 256 KiB, a binary frame | 4685 ms (+1.7 %) | 4605 ms |
| 2 MiB, 512 KiB, a binary frame | 4685 ms (+1.7 %) | 4605 ms |
| 4 MiB, 1 MiB, a binary frame | 4658 ms (+1.2 %) | 4605 ms |

Over a socket pair, without vsock, 1 GiB through the agent's session code took 2608 to
2636 ms with the 1 MiB window and with the previous code alike, with the same CPU time: the
remaining difference lies in the transport, not in the code.

The binary frame removes the cost of JSON, which grew with the number of returns. A larger
window returns input less often, but lets the agent hold more: 1 MiB per session at most,
against 256 KiB before this decision. Beyond 1 MiB the gain was within the noise of these
runs, so the window is 1 MiB.

The remaining cost of 1.7 % over vsock is accepted. It was measured while the Mac's load
average was between 2 and 8, and will be measured again on an idle Mac before phase 05 is
complete.

## Alternatives considered

- **A second connection per session for control messages.** This would separate the two
  streams without a window, but needs a way to pair the connections (a session token in the
  `exec` request, and a second handshake), doubles the connections that count against the
  agent's limit of 64, and loses the ordering between `stdinEOF` and the input, which would
  then need the same accounting as a window. Rejected.
- **Reordering on the host only.** Necessary, but not sufficient: input already in the socket
  still blocks a control message behind it while the agent's backlog is full.
- **An agent that reads without a limit.** Signals would arrive at once, but the agent's memory
  would grow with the input that the process does not read, which the stall fix in #18
  bounded. Rejected.
- **Urgent data (`MSG_OOB`).** vsock does not support out-of-band data, and the socket pairs
  that the tests use would behave differently from the real transport. Rejected.
- **A window sized in frames instead of bytes.** Frames carry from 0 to 32 KiB, so a frame
  count bounds the agent's memory only through the largest frame. Bytes bound it exactly.
- **`stdinConsumed` as a JSON control message.** The first implementation; it cost 4.2 % of
  the throughput with a 256 KiB window, against 2.8 % for the binary frame (see above).

## Consequences

- Ctrl-C and resizes reach the guest process however much input is queued for it. While
  the host's standard output is not read, the host still sends them, but over vsock they do
  not arrive: Virtualization.framework's vsock device stops carrying the machine's traffic
  once one connection's host side is full (docs/protocol.md, Flow control and ordering).
  [0017](0017-dial-back-for-sessions.md) resolves this for the output direction: sessions run
  on connections that the agent dials, which do not stop the device.
- The host runs a second thread per session, for the output. It holds less than 1 MiB of
  output per session: up to 256 KiB plus one read waiting for the handler, and as much again
  in the batch that the handler is writing.
- Memory stays bounded on both sides: the host queues at most 256 KiB of input beyond the
  window, and the agent holds at most the window, 1 MiB, plus the terminal's end-of-file
  character. Before this decision the agent held at most 256 KiB, and the guest kernel's vsock
  buffer held more input in front of it.
- A host and an agent built before this decision both speak version 2 but do not understand
  each other's input accounting: a new host waits for `stdinConsumed` from an old agent after
  1 MiB of input. The guest files must be built from the same commit as the host, which
  `scripts/fetch-guest.sh` ensures for builds from the Guest workflow.
- In terminal mode, Ctrl-C typed on the Mac is a byte of input, as in ssh: the guest's terminal
  turns it into SIGINT when it reads it, behind the input before it. Only signals that maw
  receives from elsewhere, and window sizes, overtake the input.
