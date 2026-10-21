# Host and guest agent protocol

The host (`mawd`, and the client library in `MawProtocol`) talks to the guest agent,
`maw-agent`, over vsock. This document specifies protocol version **1**. The code is in
`Sources/MawProtocol` (both sides) and `Sources/MawAgentKit` (the agent).

## Transport

- The agent listens on vsock port **19799** (`0x4D57`, "MW" in ASCII) for any context ID.
  `AgentProtocol.vsockPort` defines it.
- Each request uses a connection of its own. An exec session holds its connection until the
  process ends. `info` and `shutdown` each use a short connection that the agent closes after
  replying.
- The host connects with `VirtualMachine.connectToAgent(timeout:)`, which retries every 20 ms
  while the agent is not listening yet, until the deadline. The descriptor it returns is a
  plain connected stream socket, independent of the `VirtualMachine` object.

## Framing

Every frame has this layout:

```
+----------------+--------+------------------------+
| length: u32 BE | type:  | payload: length bytes  |
|                | u8     |                        |
+----------------+--------+------------------------+
```

`length` counts the payload only, not the type byte. The largest payload either side accepts
is **1 MiB** (`AgentProtocol.maximumPayloadSize`). A receiver checks the length and the type
as soon as the five header bytes have arrived, before reading the payload.

| Type | Name | Direction | Payload |
|------|------|-----------|---------|
| `0x01` | `version` | both | the sender's protocol version, 4 bytes, big-endian |
| `0x02` | `control` | both | a control message, JSON, UTF-8 |
| `0x10` | `stdin` | host to guest | raw bytes for the process's standard input |
| `0x11` | `stdout` | guest to host | raw bytes from standard output, or from the terminal |
| `0x12` | `stderr` | guest to host | raw bytes from standard error (pipe mode only) |

Senders split data into frames of at most **32 KiB** (`AgentProtocol.maximumDataChunkSize`).
An empty data frame is valid and has no effect.

## Handshake

1. As soon as the connection is open, each side sends a `version` frame. Neither waits for
   the other first.
2. Each side reads the first frame. It must be a `version` frame with a 4-byte payload.
3. If the versions differ, the agent sends an `error` control message with code
   `versionMismatch`, `hostVersion`, and `guestVersion`, and closes the connection. The host
   reports `MawError.guestAgentVersionMismatch(host:guest:)`, whose suggested fix is to
   update the guest files with `scripts/fetch-guest.sh`.
4. Otherwise the host sends one request: `exec`, `info`, or `shutdown`.

The agent closes a connection that has not completed the handshake and sent its request
within 10 seconds.

## Control messages

A control message is a JSON object with exactly one key, the message name. Its value is an
object with the message's fields; messages without fields have an empty object. Unknown
names, missing required fields, and wrong types are protocol errors.

```json
{"signal":{"name":"INT"}}
{"exited":{"code":3}}
{"info":{}}
```

### Requests (host to guest, first message after the handshake)

| Message | Fields | Reply |
|---------|--------|-------|
| `exec` | `argv`: [string], required, not empty. `environment`: {string: string}, default `{}`. `workingDirectory`: string, default `"/"`. `terminal`: `{"rows": u16, "columns": u16}`, absent for pipe mode. | `started`, then the session; or `error` |
| `info` | none | `agentInfo` |
| `shutdown` | none | `shutdownAcknowledged`, or `error` (`shutdownFailed`) |

### During an exec session (host to guest)

| Message | Fields | Effect |
|---------|--------|--------|
| `stdinEOF` | none | Pipe mode: closes the process's standard input once the queued input is written. Terminal mode: writes the terminal's end-of-file character (VEOF, normally Ctrl-D), as ssh does. |
| `signal` | `name`: signal name without `SIG`, such as `"INT"` | Sends the signal. Pipe mode: to the process group. Terminal mode: to the terminal's foreground process group. |
| `resize` | `rows`, `columns`: u16 | Terminal mode: sets the window size, and the kernel sends SIGWINCH. Pipe mode: ignored. |

Signals travel by name because macOS and Linux number several of them differently. The names
are `HUP INT QUIT ILL TRAP ABRT BUS FPE KILL USR1 SEGV USR2 PIPE ALRM TERM CHLD CONT STOP
TSTP TTIN TTOU URG XCPU XFSZ VTALRM PROF WINCH IO SYS`.

### Guest to host

| Message | Fields | Meaning |
|---------|--------|---------|
| `started` | `pid`: i32 | The process started; its ID in the guest. |
| `exited` | `code`: i32 (0 to 255), or `signal`: i32 | The process ended. Exactly one field is present. `signal` is the Linux signal number. The last message of a session. |
| `agentInfo` | `agentVersion`: string, `protocolVersion`: u32, `kernelRelease`: string, `uptimeMilliseconds`: u64 | Reply to `info`. |
| `shutdownAcknowledged` | none | The agent has asked `init` to power off. The VM stops shortly after. |
| `error` | `code`: string, `message`: string, optional `hostVersion`, `guestVersion`: u32 | A request failed, or the agent is closing the connection because of a protocol error. |

Error codes:

| Code | Meaning | Host error |
|------|---------|------------|
| `versionMismatch` | The protocol versions differ. | `guestAgentVersionMismatch` |
| `protocolViolation` | A frame was malformed, oversized, truncated, of an unknown type, or not valid at that point. | `guestAgentFailed` |
| `commandNotFound` | The program is not in PATH, or its path does not exist. | `guestCommandNotFound` (exit status 127 in `debug-boot`) |
| `permissionDenied` | The program cannot be executed. | `guestCommandNotStarted` (126) |
| `spawnFailed` | Another failure to start, such as a missing working directory. | `guestCommandNotStarted` (126) |
| `shutdownFailed` | The agent could not signal `init`. | `guestAgentFailed` |
| `busy` | The agent is serving its maximum of 64 connections. It sends its `version` frame and this error without acting on the request. | `guestAgentFailed` |

## Exec sessions

```
host                                   agent
 | version                    version  |
 | control exec  ------------------->  |  spawn
 |  <-----------------  control started|
 | stdin, control stdinEOF/signal/      |
 |   resize  ------------------------> |
 |  <---------------------- stdout,     |
 |                          stderr     |
 |  <------------------ control exited |  then closes
```

- **Pipe mode** (`terminal` absent): the process gets three pipes and leads a new process
  group.
- **Terminal mode** (`terminal` present): the agent opens a pseudo-terminal with the given
  size. The process leads a new session whose controlling terminal it is (`setsid`,
  `TIOCSCTTY`). Standard input, output, and error are the terminal, so all output arrives in
  `stdout` frames.
- **Program lookup**: an `argv[0]` without `/` is searched for in the session's PATH, in
  order, as `execvp` does.
- **Environment**: the process does not inherit the agent's environment. It gets these
  defaults, with the request's `environment` applied on top:

  ```
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  HOME=/root
  SHELL=/bin/sh
  ```

  `debug-boot` adds `LANG` from the host, and `TERM` in terminal mode. Commands run as root
  until phase 05.
- **Signals**: the process starts with default dispositions and an empty signal mask, even
  though the agent ignores SIGPIPE.
- **End of the session**: the agent sends `exited` once the process has been reaped and its
  output has reached end-of-file, or 250 ms after the exit if a descendant keeps the output
  open. It then closes the connection. The host must read until `exited` even after a write
  fails, because the agent may already have closed its side.
- **Exit status**: as in ssh, the status is the exit code, or 128 plus the signal number if a
  signal ended the process. SIGINT gives 130.
- **Host disconnect**: if the host closes the connection before `exited`, the agent sends
  SIGHUP to the process (the foreground process group in terminal mode), as sshd does, and
  SIGKILL two seconds later if it is still running.

## Back-pressure and limits

Neither side buffers without bound:

- The agent reads frames from the connection only while less than 256 KiB of input waits to
  be written to the process. When the process stops reading, the agent stops reading the
  socket, and the host's writes block.
- The agent reads the process's output only while less than 64 KiB waits to be sent. When
  the host stops reading, the process's writes block.
- The host client blocks callers of `GuestProcess.write` while 256 KiB of input is queued,
  and reads from the connection only as fast as its output handler accepts data.
- A receiver holds at most one maximal frame plus one read in its buffer.

A consequence: a control message queued behind a large amount of unwritten input is delayed
with it. In terminal mode this does not arise in practice, because typed input is small.

## Robustness

- A malformed, truncated, or oversized frame, an unknown type, a message out of place, or a
  silent peer closes that connection only. The agent sends an `error` with code
  `protocolViolation` when the connection can still carry it, kills the session's process
  group, and reaps the process. Other connections are unaffected.
- The agent's unit tests send 10,000 random frames over about 950 connections and check that
  each connection is closed and that the agent still serves new ones.

## Readiness

When the agent is listening, it writes `maw-agent ready <version>` to the console (`hvc0`).
Hosts do not depend on that line: `mawd` retries the connection until the agent answers
`info`, and reports `boot: agent ready after <n> ms`.

## Shutdown

The host's `VirtualMachine.stop(timeout:)` tries, in order:

1. the agent's `shutdown` request, then waits up to `timeout` for the VM to stop;
2. Virtualization.framework's `requestStop()`, and waits again;
3. a forced stop.

The console log records the result: `shutdown: clean after <n> ms via the guest agent`,
`via a stop request` (with the reason the agent was not used), or `shutdown: forced after
<n> ms` with the reasons. In the guest, `shutdown` makes the agent send SIGUSR2 to `init`
(see `docs/decisions/0005-init-supervises-the-agent.md`).

## Versioning

- `ProtocolVersion.current` is the version both sides send. Any change to the control
  messages, their fields, their meaning, or the frame types increments it, including
  additions. Both sides of a connection always come from builds of the same version, so there
  is no negotiation and no compatibility code.
- The `version` frame (type `0x01`, a 4-byte big-endian payload) and the frame header never
  change, so that any two versions can detect a mismatch and report it.
- The guest files record the agent's sha256 in `manifest.json` (`initramfs.agent.sha256`).
