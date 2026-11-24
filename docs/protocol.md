# Host and guest agent protocol

The host (`mawd`, and the client library in `MawProtocol`) talks to the guest agent,
`maw-agent`, over vsock. This document specifies protocol version **8**. The code is in
`Sources/MawProtocol` (both sides) and `Sources/MawAgentKit` (the agent). Version 2 added the
user a session runs as, its program (a command, a shell command line, or a login shell), its
locale, and the input window, with which `signal` and `resize` overtake queued standard input
([0016](decisions/0016-input-window.md)). Version 3 adds the dial-back: the `dialBack`
request, its `dialedBack` reply, the `dialBackNonce` frame, and the `dialBackFailed` error.
Every session runs on a connection that the agent dials. Version 4 adds `foregroundQuery` and
`foregroundProgram`. Version 5 adds `sample`, its `sampled` reply, and the `sampleFailed`
error ([0020](decisions/0020-distribution-figures.md)). Version 6 adds `macShareMounted` to
`agentInfo` ([0021](decisions/0021-mac-share.md)). Version 7 adds `exec`'s `fallsBackToHome`
and `started`'s `workingDirectoryFallback`, gives `~` in `workingDirectory` its meaning, and
starts a login shell in a working directory through the agent as `runuser -l`'s shell helper
([0022](decisions/0022-working-directory-and-logind.md)). Version 8 adds the forwarding
channel: the `forwarding` request, `listeners`, `connect`, `connectFailed`, and the host's
vsock port 19801 ([0023](decisions/0023-localhost-forwarding.md), [Forwarding](#forwarding)).

## Transport

- The agent listens on vsock port **19799** (`0x4D57`, "MW" in ASCII).
  `AgentProtocol.vsockPort` defines it. It accepts connections only from the host, context ID
  2, and closes any other before reading from it (docs/security.md).
- Each request uses a connection of its own. An exec session holds its connection until the
  process ends. `info`, `sample`, `shutdown`, and `dialBack` each use a short connection that
  the agent closes after replying.
- In reply to `dialBack`, the agent connects to the host's vsock port **19800** (`0x4D58`,
  `AgentProtocol.dialBackPort`); see [Dial-back](#dial-back).
- For each forwarded connection, the agent connects to the host's vsock port **19801**
  (`0x4D59`, `AgentProtocol.forwardingPort`); see [Forwarding](#forwarding).
- The host opens connections with `VirtualMachine.connectToAgent(timeout:)`, which retries
  every 20 ms while the agent is not listening yet, until the deadline. It uses them only for
  `info`, `sample`, `shutdown`, and `dialBack`, whose replies are small. Every exec session, in `maw`,
  in provisioning, and in `mawd debug-boot`, runs on a connection that the agent dials:
  `VirtualMachine.openSessionConnection(connectTimeout:)` sends `dialBack` and returns the
  dialed connection. Either descriptor is a plain connected stream socket, independent of the
  `VirtualMachine` object.

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
   the other first. The host sends its one request, `exec`, `info`, `sample`, `shutdown`, or
   `dialBack`, right after its `version` frame, without waiting for the agent's version,
   which would cost a round trip.
2. Each side reads the first frame. It must be a `version` frame with a 4-byte payload.
3. If the versions differ, the agent sends an `error` control message with code
   `versionMismatch`, `hostVersion`, and `guestVersion`, and closes the connection without
   reading the request. The host reports `MawError.guestAgentVersionMismatch(host:guest:)`,
   whose suggested fix is to install guest files built from the same commit, with
   `scripts/fetch-guest.sh` or by rebuilding them.
4. Otherwise the agent reads the request and answers it. The host reads the reply only after
   it has checked the agent's version.

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
| `exec` | `program`: one of `{"argv": [string]}`, `{"shellCommand": string}`, `{"loginShell": {}}`, required. `user`: string, default: the distribution's default user. `locale`: string, the host's preferred locale, optional. `environment`: {string: string}, default `{}`. `workingDirectory`: string, default: the user's home directory; `~` and `~/<path>` are the home directory and a path under it. `fallsBackToHome`: bool, default `false`, written only when true: the session starts in the home directory if it cannot enter `workingDirectory`. `terminal`: `{"rows": u16, "columns": u16}`, absent for pipe mode. | `started`, then the session; or `error` |
| `info` | none | `agentInfo` |
| `sample` | none | `sampled`, or `error` (`sampleFailed`); see [Sample](#sample) |
| `shutdown` | none | `shutdownAcknowledged`, or `error` (`shutdownFailed`) |
| `dialBack` | `nonce`: 64 lowercase hexadecimal digits, the 32 bytes of the nonce | `dialedBack`, or `error` (`dialBackFailed`); see [Dial-back](#dial-back) |
| `forwarding` | none; only on a connection that the agent dialed | `listeners`, then the channel; or `error` (`busy`, `protocolViolation`); see [Forwarding](#forwarding) |

### During an exec session (host to guest)

| Message | Fields | Effect |
|---------|--------|--------|
| `stdinEOF` | none | Pipe mode: closes the process's standard input once the queued input is written. Terminal mode: writes the terminal's end-of-file character (VEOF, normally Ctrl-D), as ssh does. `stdin` frames after it are discarded, and a second `stdinEOF` has no effect. |
| `signal` | `name`: signal name without `SIG`, such as `"INT"` | Sends the signal at once. Pipe mode: to the process group. Terminal mode: to the terminal's foreground process group. |
| `resize` | `rows`, `columns`: u16 | Terminal mode: sets the window size at once, and the kernel sends SIGWINCH. Pipe mode: ignored. |
| `foregroundQuery` | `id`: u32 | Asks which program runs in the foreground of the terminal. The agent replies at once with `foregroundProgram` and the same `id`; see [Foreground program](#foreground-program). |

### On the forwarding channel (host to guest)

| Message | Fields | Effect |
|---------|--------|--------|
| `connect` | `id`: u32, `port`: u16 from 1 to 65535, `family`: `"ipv4"` or `"ipv6"`, `nonce`: 64 lowercase hexadecimal digits | Connect to the guest's listener on `port` at `127.0.0.1` or `::1`, then dial port 19801 and send `nonce` first; or answer `connectFailed` with the same `id`. |

Signals travel by name because macOS and Linux number several of them differently. The names
are `HUP INT QUIT ILL TRAP ABRT BUS FPE KILL USR1 SEGV USR2 PIPE ALRM TERM CHLD CONT STOP
TSTP TTIN TTOU URG XCPU XFSZ VTALRM PROF WINCH IO SYS`.

### Guest to host

| Message | Fields | Meaning |
|---------|--------|---------|
| `started` | `pid`: i32, optional `workingDirectoryFallback`: string | The process started; its ID in the guest. `workingDirectoryFallback` is present when the request allowed the fallback and the process started in the home directory instead: `shareNotMounted`, `notFound`, `permissionDenied`, `notADirectory`, or `other`. |
| `exited` | `code`: i32 (0 to 255), or `signal`: i32 | The process ended. Exactly one field is present. `signal` is the Linux signal number. The last message of a session. |
| `agentInfo` | `agentVersion`: string, `protocolVersion`: u32, `kernelRelease`: string, `uptimeMilliseconds`: u64, `macShareMounted`: bool | Reply to `info`. `macShareMounted` is true when the last mount at `/mnt/mac` in `/proc/self/mountinfo` is the virtiofs share `maw-mac`; reading the table looks nothing up in the share. |
| `shutdownAcknowledged` | none | The agent has asked `init` to power off. The VM stops shortly after. |
| `dialedBack` | none | Reply to `dialBack`: the agent has connected to the host and sends the nonce first on that connection. |
| `sampled` | `memoryTotalBytes`: u64, `memoryAvailableBytes`: u64, optional `ipv4Address`: string | Reply to `sample`; see [Sample](#sample). |
| `listeners` | `listeners`: at most 1,024 objects `{"address": "anyIPv4" \| "anyIPv6" \| "loopbackIPv4" \| "loopbackIPv6", "port": u16}`, ports from 1 to 65535, no two alike | On the forwarding channel: the guest's TCP listeners on `0.0.0.0`, `::`, `127.0.0.1`, and `::1`, all of them, once when the channel opens and whenever they change. |
| `connectFailed` | `id`: u32, `reason`: string of at most 256 bytes | On the forwarding channel: `connect` with `id` failed before any dial. The host does not log the reason. |
| `foregroundProgram` | `id`: u32, optional `processGroup`: i32, optional `name`: string | Reply to `foregroundQuery` with its `id`. `processGroup` is present exactly when a program other than the shell is in the foreground; `name` is its leader's command name, absent when the leader has exited. A `name` without `processGroup` is a protocol violation. |
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
| `busy` | The agent is serving its maximum of 64 connections. It sends its `version` frame and this error without acting on the request. Also the reply to `forwarding` while another forwarding channel is open, or from an agent that cannot forward. | `guestAgentFailed` |
| `userNotFound` | The requested user, or the default user that `/etc/maw.conf` names, is not in `/etc/passwd`. `user` names it. | `userNotFound` |
| `sampleFailed` | The agent could not read its memory figures for `sample`: `/proc/meminfo` cannot be read, has no `MemTotal` or no `MemAvailable`, or reports more available memory than its total. The message says which. | `guestAgentFailed` |
| `dialBackFailed` | The agent could not connect to the host for `dialBack`: no source port below 1024 was free, binding one failed, or the connection failed or did not complete within 2 seconds. The message says which. | `sessionDialBackFailed` |

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
4. The host's listener on port 19800, one per machine while it runs, refuses at once,
   before reading anything, a connection from a source port of 1024 or above, any connection
   while no session of that machine waits for one, and any connection once as many accepted
   connections have not yet sent their nonce as there are waiting sessions plus 4. Each
   waiting session's own dial therefore finds a place however many sessions open at once, and
   the agent does not retry a refused dial. It reads exactly the 37 bytes of the nonce frame
   from an accepted connection, within 2 seconds, and nothing more, so that the rest is left
   for whoever runs the session. A connection whose frame does not arrive in time, is
   malformed, or carries a nonce that no session waits for is closed (`DialBackGate`).
5. The host draws and registers a session's nonce once its connection to the agent exists,
   just before it sends `dialBack`, so that the time the connect takes does not count. It
   keeps the nonce for 5 seconds from then, and for at most 64 sessions per machine, the
   agent's connection limit. A nonce is used once, compared in constant time, and never
   logged. Refusals go to the machine's console log, at most 5 in 10 seconds.
6. If the agent replies `dialBackFailed`, or replies `dialedBack` but no connection with the
   nonce arrives within the 5 seconds, the session fails with `sessionDialBackFailed` or
   `sessionDialBackMissing`. The host never falls back to running the session on a
   connection that it opened.

## Forwarding

`forwarding` makes a connection the machine's forwarding channel, which carries `localhost`
forwarding ([decision record 0023](decisions/0023-localhost-forwarding.md)). The host sends it
as the request of a connection that the agent dialed, so that the host's reading never stalls
the machine's vsock device; on a connection that the host opened it is a protocol violation.

```
host                                            agent
 | (dialed connection) version    version  |
 | control forwarding  ------------------> |
 |  <-------------- control listeners[...] |  at once, then whenever they change
 | control connect{id,port,family,nonce} -> |  connect to the guest's listener;
 |                                          |  then dial port 19801:
 |  <---------------------- dialBackNonce   |      (new connection) nonce, then raw bytes
 |  <------------ control connectFailed{id} |  or, when connecting failed
```

1. **One channel.** The agent serves one forwarding channel at a time and answers a second with
   `error` (`busy`). The channel does not count against the agent's 64 connections: sessions
   keep all of them. The channel lasts until either side closes it. The host reads it at all
   times; the agent closes it if more than 1 MiB of its output waits.
2. **Listeners.** The agent lists the guest's listening TCP sockets with netlink `sock_diag`
   every 250 ms (`AgentProtocol.listenerScanInterval`), and sends `listeners` with all of them
   when the set differs from the last one sent. It keeps sockets on `0.0.0.0`, `::`,
   `127.0.0.1`, and `::1` only; `127.0.0.53`, `127.0.0.54`, other addresses, and the agent's own
   sockets are left out. Beyond 1,024 listeners (`AgentProtocol.maximumListeners`), it sends
   the first 1,024 in port order and logs that the rest were left out. If a scan fails, the
   agent keeps the last set, sends an empty one if it has sent none, and logs the failure once;
   once scans have failed for 1 second, it sends an empty set, so that the host releases the
   ports, and the next scan that succeeds reports them anew.
3. **Connections.** For `connect`, the agent connects to `127.0.0.1` (`ipv4`) or `::1` (`ipv6`)
   on `port`, within 2 seconds, then dials the host's port 19801 as for `dialBack` (the highest
   free source port below 1024, within 2 seconds), sends a `dialBackNonce` frame with the
   request's nonce, and copies raw bytes between the two connections from then on: no frames
   follow the nonce. The end of one side's stream is carried as `shutdown(SHUT_WR)` on the
   other; an error resets both. If either step fails, the agent closes what it opened and sends
   `connectFailed` with the request's `id`. It holds at most 256 forwarded connections
   (`AgentProtocol.maximumForwardedConnections`); a `connect` beyond them fails at once.
4. **The host's port 19801** has a gate of its own, with the same checks as port 19800
   ([Dial-back](#dial-back), item 4): a source port below 1024, a nonce that a waiting
   connection registered, valid for 5 seconds, used once, and compared in constant time.
5. **Any other message** on the channel, in either direction, is a protocol violation, and
   closes it.

## Sample

`sample` asks for the figures of the guest that only the guest knows, for the daemon's
distribution figures ([decision record 0020](decisions/0020-distribution-figures.md)). It is
sent on a connection that the host opens, as `info` is, and needs no session.

```json
host to guest:  {"sample":{}}
guest to host:  {"sampled":{"ipv4Address":"192.168.64.3","memoryAvailableBytes":1984000000,"memoryTotalBytes":2093694976}}
```

- **Memory.** `memoryTotalBytes` and `memoryAvailableBytes` are `MemTotal` and `MemAvailable`
  from `/proc/meminfo`, converted from kB (KiB) to bytes. Memory in use is their difference,
  which `free` in Ubuntu 24.04 reports as used. If either line is missing, the agent replies
  `error` with code `sampleFailed` and does not invent a value.
- **Address.** The agent reads `/proc/net/route`, takes the default route (destination and
  mask 0, flag `RTF_UP`) with the lowest metric, and replies with the first IPv4 address of its
  interface, from `getifaddrs`. Without a default route, or without an IPv4 address on its
  interface, `ipv4Address` is absent.
- The agent reads the two files and calls `getifaddrs` on the connection's thread. It starts
  no process.
- **The host decodes the reply strictly.** Both memory fields are required, the available
  memory must not exceed the total, and `ipv4Address`, if present, must be four decimal
  numbers from 0 to 255 separated by dots. Anything else is a protocol violation of that
  connection. The host shows these values only, never logs them, and treats a failed sample
  as figures that are not known (docs/daemon.md).

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
  - `loginShell`: the user's shell as a login shell. Under systemd, the agent starts it through
    `runuser -l <user>`, whose PAM stack includes `pam_systemd`, so that `systemd-logind`
    registers the session and `XDG_RUNTIME_DIR` and `systemctl --user` work. Right after boot it
    first waits up to 2 seconds for the system bus's socket. With a `workingDirectory`, runuser
    runs the agent (`/run/maw/maw-agent login-shell`) as its shell helper, which enters the
    directory as the user, reports the result to the agent on descriptor 3, closes it, and
    executes the user's shell; the agent sends `started` once the report has come, at most
    5 seconds after the start, or answers with `error` (`spawnFailed`) if the helper could not
    enter a directory without the fallback, if runuser ended before the report, or if the
    report did not come in time. Without systemd, or without `/run/maw/maw-agent`, the agent
    starts the shell itself, with `-<shell name>` as `argv[0]`.
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
- **Working directory**: the request's `workingDirectory`, with `~` expanded, or the user's
  home directory, or `/` if the home directory does not exist. The process enters it as the
  user. If it cannot, it fails with `spawnFailed`, unless `fallsBackToHome` is set: then it
  starts in the home directory, and `started` carries the reason. While the share is not
  mounted, as `/proc/self/mountinfo` shows, a directory under `/mnt/mac`, `/mnt/mac` itself
  included, falls back with `shareNotMounted` before the process starts, without being
  entered: the empty mount point would otherwise be. A mount table that cannot be read leaves
  the directory to the spawn.
- **Login shells in a working directory** start through the shell helper only when the
  directory and the account's shell are absolute; otherwise the agent starts the shell itself,
  without a logind session. A relative directory, which `maw` never sends, is resolved
  against `/`, the agent's directory, for every program.
- **Descriptors**: the process gets standard input, output, and error, and no other descriptor
  of the agent's; the shell helper's descriptor 3 is closed before the user's shell starts.
- **PATH** always includes `/usr/local/bin`, where `mawpath` is linked.
- **Signals**: the process starts with default dispositions and an empty signal mask, even
  though the agent ignores SIGPIPE.
- **End of the session**: the agent sends `exited` once the process has been reaped and its
  output has reached end-of-file, or 250 ms after the exit if a descendant keeps the output
  open. It then closes the connection. The host must read until `exited` even after a write
  fails, because the agent may already have closed its side. A write to a closed connection
  fails with EPIPE or ECONNRESET, or on macOS with ENOTCONN when it races the close; the host
  treats all three as the agent having closed its side. On macOS, a socket whose peer has
  already closed refuses `SO_NOSIGPIPE` and `F_SETNOSIGPIPE`, and unless it suppressed SIGPIPE
  before the close, a write to it raises SIGPIPE, which ends a process that does not ignore
  the signal, as the terminal app will not. A host connection made from such a socket never
  writes to it, treats it as closed in the same way, and still reads what the agent sent, such
  as its version and an error. `mawd`, the agent, and `maw` while it runs a session or an
  installation ignore SIGPIPE in any case.
- **Exit status**: as in ssh, the status is the exit code, or 128 plus the signal number if a
  signal ended the process. SIGINT gives 130.
- **Host disconnect**: if the host closes the connection before `exited`, the agent sends
  SIGHUP to the process (the foreground process group in terminal mode), as sshd does, and
  SIGKILL two seconds later if it is still running. `GuestProcess.hangUp()` closes the
  connection in this way, for a client that ends a session as closing a terminal window ends
  an ssh session.

## Foreground program

`foregroundQuery` asks which program runs in the foreground of an exec session's terminal, so
that a client can ask before it closes a session in which a program other than the shell runs.
The host sends it only when it needs the answer, so an idle session carries no extra traffic.
Either message outside an exec session is a protocol violation, and so is `foregroundProgram`
from the host or `foregroundQuery` from the agent.

```json
host to guest:  {"foregroundQuery":{"id":7}}
guest to host:  {"foregroundProgram":{"id":7}}                                    none
                {"foregroundProgram":{"id":7,"name":"sleep","processGroup":812}}  a program
                {"foregroundProgram":{"id":7,"processGroup":812}}                 its leader has exited
```

The agent answers as follows:

- **None** in pipe mode, and once the process has exited.
- Otherwise the foreground process group is `tcgetpgrp` on the pseudo-terminal's primary
  side. If there is none, the answer is none.
- **The shell is in the foreground**, and the answer is none, when the group's leader is the
  shell. That is the process the agent started, for a session that the agent starts directly,
  including a command's own program. For a login shell started through `runuser -l`, it is a
  child of the process the agent started, because the shell makes a process group of its own;
  while `runuser` itself leads the foreground group, the answer is none as well.
- **An `exec`'d shell**: for a login shell, if the shell's process has a command name other
  than the basename of the account's shell (truncated to 15 bytes), the shell has run `exec`,
  and the answer is that program, so that `exec vim` is reported. Sessions that are not login
  shells skip this check.
- **Another group** is a program. Its `name` is the leader's `/proc/<pgid>/comm`: what `ps` and
  `top` show, at most 15 bytes (`TASK_COMM_LEN`). If `/proc/<pgid>` does not exist, or the state
  in `/proc/<pgid>/stat` is `Z`, the leader has exited, as it may have in a pipeline, and the
  answer is a program without a name. `stat` is parsed from its last `)`, because a command name
  may contain spaces and parentheses.

The host (`GuestProcess.foregroundProgram(within:)`) counts `id` from 1. It ignores a reply
whose query it stopped waiting for, and treats a reply to a query that it has not sent as a
protocol violation. The name comes from the guest: before anything shows it, the host replaces
control and format characters with U+FFFD and keeps at most 64 bytes of it. Once the session
has ended, the host answers none without asking.

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
- **Order.** `stdin` frames and `stdinEOF` arrive in the order the host queued them. `signal`,
  `resize`, and `foregroundQuery` overtake the input that the host has not sent yet, and the
  agent acts on them as they arrive. A signal therefore reaches the process however much input waits for it, for
  example Ctrl-C in `yes | maw -e sleep 1000`. The host queues each signal once, as a process's
  pending signals are, only the latest window size, and at most one `foregroundQuery` that it
  has not sent yet, whose answer every caller that asked meanwhile shares.
- **Input on the host.** `GuestProcess.write` blocks its caller while 256 KiB of input is
  queued and not yet sent.
- **Output.** The agent reads the process's output only while less than 64 KiB waits to be
  sent. When the host stops reading, the process's writes block, and only they: a session
  runs on a connection that the agent dialed, and the machine's other connections, new
  sessions, and the console go on working (see the next item). The host hands output to its
  output handler on a thread of its own, and stops reading the connection while 256 KiB
  (`GuestProcess.outputLimit`) waits for the handler. The thread that sends never waits for
  the handler, so a signal or a window size is sent, and arrives, while a write to the Mac's
  standard output blocks, for example SIGINT sent to `maw -e yes` while nobody reads its
  standard output.
- **A full host-opened connection would stop the machine's vsock traffic.** This is why no
  session runs on a connection that the host opens
  ([decision record 0017](decisions/0017-dial-back-for-sessions.md)). On such a connection
  (`VZVirtioSocketDevice.connect(toPort:)`), Virtualization.framework's vsock device writes the
  guest's data to the host's socket on one serial queue, and once the host stops reading the
  connection and its socket is full, the device blocks in that write. Until the host reads
  again, no vsock connection of the machine carries data in either direction, no new
  connection opens, and the console may stop as well. A sample of the machine's process
  showed the queue `com.apple.virtualization.virtio.vsock-device:0` in `writev` for 3 s out
  of 3 s. The host's descriptor is one end of a Unix stream socket pair whose other end the
  machine's process holds, and the device blocks once 8192 bytes wait in it: the default send
  buffer of a Unix stream socket (`net.local.stream.sendspace`), with a low-water mark of 2048
  bytes, so it may block from 6145 bytes on. `SO_RCVBUF` on the host's descriptor is accepted
  but does not change this, in the daemon and in a process that the descriptor was handed to
  alike (`scripts/measure-vsock-buffer.sh`). The host's own connections therefore carry only
  `info`, `sample`, `shutdown`, and `dialBack`, whose replies are a few hundred bytes at most,
  and the host reads each reply in full at once and then closes the connection; it never hands such a
  connection to a client. On a connection that the guest opens to a `VZVirtioSocketListener`,
  the host's socket fills in the same way, but only the guest's writer blocks, after 256 KiB;
  the machine's other connections, new connections in both directions, and the console go on
  working, also through a 60-second stall and while the process holding the descriptor is
  stopped (`scripts/measure-vsock-buffer.sh --guest-initiated`). Apple documents neither
  behavior; it was measured on macOS 27.0.1.
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
- A forwarded connection carries no frames after its nonce: a malformed byte stream there is
  the application's, and neither side reads it.

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
