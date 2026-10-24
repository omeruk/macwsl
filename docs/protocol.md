# Host and guest agent protocol

The host (`mawd`, and the client library in `MawProtocol`) talks to the guest agent,
`maw-agent`, over vsock. This document specifies protocol version **3**. The code is in
`Sources/MawProtocol` (both sides) and `Sources/MawAgentKit` (the agent). Version 2 added the
user a session runs as, its program (a command, a shell command line, or a login shell), its
locale, and the input window, with which `signal` and `resize` overtake queued standard input
([0016](decisions/0016-input-window.md)). Version 3 adds the dial-back: the `dialBack`
request, its `dialedBack` reply, the `dialBackNonce` frame, and the `dialBackFailed` error.
The agent implements it; the host does not send `dialBack` yet.

## Transport

- The agent listens on vsock port **19799** (`0x4D57`, "MW" in ASCII).
  `AgentProtocol.vsockPort` defines it. It accepts connections only from the host, context ID
  2, and closes any other before reading from it (docs/security.md).
- Each request uses a connection of its own. An exec session holds its connection until the
  process ends. `info` and `shutdown` each use a short connection that the agent closes after
  replying.
- In reply to `dialBack`, the agent connects to the host's vsock port **19800** (`0x4D58`,
  `AgentProtocol.dialBackPort`); see [Dial-back](#dial-back).
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
| `0x03` | `stdinConsumed` | guest to host | standard input the agent has written to the process, or discarded, since its last `stdinConsumed` frame: a byte count, 4 bytes, big-endian |
| `0x04` | `dialBackNonce` | guest to host | the nonce of a `dialBack` request, exactly 32 bytes; the first frame on a connection the agent dials. A header that declares any other size is a protocol error as soon as it arrives. |
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
   install guest files built from the same commit, with `scripts/fetch-guest.sh` or by
   rebuilding them.
4. Otherwise the host sends one request: `exec`, `info`, `shutdown`, or `dialBack`.

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
| `exec` | `program`: one of `{"argv": [string]}`, `{"shellCommand": string}`, `{"loginShell": {}}`, required. `user`: string, default: the distribution's default user. `locale`: string, the host's preferred locale, optional. `environment`: {string: string}, default `{}`. `workingDirectory`: string, default: the user's home directory. `terminal`: `{"rows": u16, "columns": u16}`, absent for pipe mode. | `started`, then the session; or `error` |
| `info` | none | `agentInfo` |
| `shutdown` | none | `shutdownAcknowledged`, or `error` (`shutdownFailed`) |
| `dialBack` | `nonce`: 64 lowercase hexadecimal digits, the 32 bytes of the nonce | `dialedBack`, or `error` (`dialBackFailed`); see [Dial-back](#dial-back) |

### During an exec session (host to guest)

| Message | Fields | Effect |
|---------|--------|--------|
| `stdinEOF` | none | Pipe mode: closes the process's standard input once the queued input is written. Terminal mode: writes the terminal's end-of-file character (VEOF, normally Ctrl-D), as ssh does. `stdin` frames after it are discarded, and a second `stdinEOF` has no effect. |
| `signal` | `name`: signal name without `SIG`, such as `"INT"` | Sends the signal at once. Pipe mode: to the process group. Terminal mode: to the terminal's foreground process group. |
| `resize` | `rows`, `columns`: u16 | Terminal mode: sets the window size at once, and the kernel sends SIGWINCH. Pipe mode: ignored. |

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
| `dialedBack` | none | Reply to `dialBack`: the agent has connected to the host and sends the nonce first on that connection. |
| `error` | `code`: string, `message`: string, optional `hostVersion`, `guestVersion`: u32, optional `user`: string | A request failed, or the agent is closing the connection because of a protocol error. |

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
| `userNotFound` | The requested user, or the default user that `/etc/maw.conf` names, is not in `/etc/passwd`. `user` names it. | `userNotFound` |
| `dialBackFailed` | The agent could not connect to the host for `dialBack`: no source port below 1024 was free, binding one failed, or the connection failed or did not complete within 2 seconds. The message says which. | `guestAgentFailed` |

## Dial-back

`dialBack` asks the agent to open a connection to the host. The design keeps a session's
traffic off connections that the host opens, which stop the machine's vsock traffic while
the host does not read them (see [Flow control and ordering](#flow-control-and-ordering)).

```
host                                    agent
 | version                     version  |          request connection
 | control dialBack{nonce}  ----------> |  bind a source port, connect to 19800
 |  <---------------- control dialedBack|  then closes the request connection
 |
 |  <------------------- dialBackNonce  |          dialed connection
 | version                     version  |
 | control exec/info/shutdown --------> |  as on any new connection
```

1. The agent accepts `dialBack` only as the request of a connection that the host opened:
   the agent's listener closes connections from any other context ID before reading
   (docs/security.md). On a connection that the agent dialed, `dialBack` is a protocol
   violation, and so it is during an exec session.
2. The agent binds the highest free source port below 1024, counting down from 1023 and
   skipping ports in use, and connects to the host's port 19800 with a timeout of 2 seconds.
   If no port is free, binding fails for another reason, or the connection fails or times out,
   it replies `error` with code `dialBackFailed` and closes the request connection.
3. Otherwise it queues a `dialBackNonce` frame with the request's nonce as the first frame of
   the dialed connection, replies `dialedBack`, and closes the request connection. It then
   serves the dialed connection like a new one, in the same connection slot: the version
   exchange, then one request.
4. The host is to read exactly the 37 bytes of the nonce frame from the dialed connection,
   and nothing more, so that the rest is left for whoever runs the session. The host side is
   not implemented yet.

## Exec sessions

```
host                                   agent
 | version                    version  |
 | control exec  ------------------->  |  spawn
 |  <-----------------  control started|
 | stdin, control stdinEOF/signal/      |
 |   resize  ------------------------> |
 |  <---------------------- stdout,     |
 |                stderr, stdinConsumed |
 |  <------------------ control exited |  then closes
```

- **Pipe mode** (`terminal` absent): the process gets three pipes and leads a new process
  group.
- **Terminal mode** (`terminal` present): the agent opens a pseudo-terminal with the given
  size. The process leads a new session whose controlling terminal it is (`setsid`,
  `TIOCSCTTY`). Standard input, output, and error are the terminal, so all output arrives in
  `stdout` frames.
- **User**: the request's `user`, or `[user] default` in the guest's `/etc/maw.conf`, or root.
  The agent reads the account from `/etc/passwd` and its supplementary groups from
  `/etc/group`. Unless the account is the agent's own (root), the child process sets the
  groups, the group ID, and the user ID, in that order, before it changes to the working
  directory and executes the program.
- **Program**:
  - `argv`: run as given. An `argv[0]` without `/` is searched for in the session's PATH, in
    order, as `execvp` does.
  - `shellCommand`: run by the user's shell from `/etc/passwd` (`/bin/sh` if it names none),
    as `<shell> -c <command>`.
  - `loginShell`: the user's shell as a login shell. Under systemd, with no `workingDirectory`,
    the agent starts it through `runuser -l <user>`, whose PAM stack includes `pam_systemd`, so
    that `systemd-logind` registers the session and `XDG_RUNTIME_DIR` and `systemctl --user`
    work. Right after boot it first waits up to 2 seconds for the system bus's socket. Otherwise
    the agent starts the shell itself, with `-<shell name>` as `argv[0]`.
- **Environment**: the process does not inherit the agent's environment. It gets a login
  environment, as ssh builds one, with the request's `environment` applied on top:

  | Variable | Value |
  |----------|-------|
  | `HOME`, `SHELL` | from `/etc/passwd` |
  | `USER`, `LOGNAME` | the user's name |
  | `PATH` | `ENV_SUPATH` for root and `ENV_PATH` for other users, from `/etc/login.defs`, as `su -l` and `runuser -l` use them |
  | `LANG` | the request's `locale` if the guest has it (in `/usr/lib/locale`), and `C.UTF-8` otherwise |
  | `XDG_RUNTIME_DIR` | `/run/user/<uid>`, if it exists |

  `maw` adds `TERM` from the host, or `xterm-256color` in terminal mode.
- **Working directory**: the request's `workingDirectory`, or the user's home directory, or `/`
  if the home directory does not exist.
- **Signals**: the process starts with default dispositions and an empty signal mask, even
  though the agent ignores SIGPIPE.
- **End of the session**: the agent sends `exited` once the process has been reaped and its
  output has reached end-of-file, or 250 ms after the exit if a descendant keeps the output
  open. It then closes the connection. The host must read until `exited` even after a write
  fails, because the agent may already have closed its side. A write to a closed connection
  fails with EPIPE or ECONNRESET, or on macOS with ENOTCONN when it races the close; the host
  treats all three as the agent having closed its side.
- **Exit status**: as in ssh, the status is the exit code, or 128 plus the signal number if a
  signal ended the process. SIGINT gives 130.
- **Host disconnect**: if the host closes the connection before `exited`, the agent sends
  SIGHUP to the process (the foreground process group in terminal mode), as sshd does, and
  SIGKILL two seconds later if it is still running.

## Flow control and ordering

Neither side buffers without bound, and a control message never waits behind input that the
process does not read. [Decision record 0016](decisions/0016-input-window.md) explains the
design and the alternatives.

- **The input window.** The host never has more than **1 MiB** (`AgentProtocol.inputWindow`)
  of `stdin` payload outstanding: sent, and not yet returned by a `stdinConsumed` frame. The
  agent sends one once it has written to the process, or discarded, at least 256 KiB since the
  last (input that arrives after `stdinEOF`, or after the process has closed its standard
  input, is discarded). The input waiting in the agent is therefore never more than the
  window, plus the terminal's end-of-file character, and the agent reads the connection at all
  times. Input beyond the window is a protocol violation, and so is a `stdinConsumed` frame
  that returns more than is outstanding.
- **Order.** `stdin` frames and `stdinEOF` arrive in the order the host queued them. `signal`
  and `resize` overtake the input that the host has not sent yet, and the agent acts on them as
  they arrive. A signal therefore reaches the process however much input waits for it, for
  example Ctrl-C in `yes | maw -e sleep 1000`. The host queues each signal once, as a process's
  pending signals are, and only the latest window size.
- **Input on the host.** `GuestProcess.write` blocks its caller while 256 KiB of input is
  queued and not yet sent.
- **Output.** The agent reads the process's output only while less than 64 KiB waits to be
  sent. When the host stops reading, the process's writes block. The host hands output to its
  output handler on a thread of its own, and stops reading the connection while 256 KiB
  (`GuestProcess.outputLimit`) waits for the handler. The thread that sends never waits for
  the handler, so a signal or a window size is sent while a write to the Mac's standard
  output blocks, for example SIGINT sent to `maw -e yes` while nobody reads its standard
  output.
- **A full connection stops the machine's vsock traffic.** Over vsock, the signal in that
  example is sent but does not arrive. Virtualization.framework's vsock device writes the
  guest's data to the host's socket on one serial queue, and once the host stops reading a
  connection and its socket is full, the device blocks in that write. Until the host reads
  again, no vsock connection of the machine carries data in either direction, and no new
  connection opens. A sample of the machine's process showed the queue
  `com.apple.virtualization.virtio.vsock-device:0` in `writev` for 3 s out of 3 s. The
  host's descriptor is one end of a Unix stream socket pair whose other end the machine's
  process holds, and the device blocks once 8192 bytes wait in it: the default send buffer of
  a Unix stream socket (`net.local.stream.sendspace`), with a low-water mark of 2048 bytes, so
  it may block from 6145 bytes on. `SO_RCVBUF` on the host's descriptor is accepted but does
  not change this, in the daemon and in a process that the descriptor was handed to alike
  (`scripts/measure-vsock-buffer.sh`). This applies to connections that the host opens
  (`VZVirtioSocketDevice.connect(toPort:)`). On a connection that the guest opens to a
  `VZVirtioSocketListener`, the host's socket fills in the same way, but only the guest's
  writer blocks, after 256 KiB; the machine's other connections, new connections in both
  directions, and the console go on working, also through a 60-second stall and while the
  process holding the descriptor is stopped (`scripts/measure-vsock-buffer.sh
  --guest-initiated`). The host therefore must not
  stop reading a connection that it opened for long; this is not yet the case (see the pull
  request for phase 05).
- A receiver holds at most one maximal frame plus one read in its buffer.

In terminal mode, Ctrl-C typed on the Mac is a byte of input, as in ssh: the guest's terminal
turns it into SIGINT when it reads it, after the input queued before it.

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
