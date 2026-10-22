# 0010: The daemon's interface uses libxpc's C connection API

- Status: Accepted
- Date: 2026-10-22

## Context

`mawd` owns the virtual machines, and `maw` (later also the terminal app) talks to it over XPC.
`CLAUDE.md` requires two things of that interface:

- **For interactive sessions, terminal bytes must not pass through the daemon.** The daemon
  connects to the guest agent over vsock and hands the connection's file descriptor to the
  client, which runs the guest protocol itself.
- **The daemon accepts only maw's own executables, running as the same user** (phase 04b).

maw's minimum is macOS 14. Three XPC APIs were considered, in the order the phase prompt
prefers them. Their availability was read from the macOS 27 SDK (`usr/include/xpc/*.h` and
`XPC.swiftmodule`):

| Need | Swift `XPCSession`, `XPCListener` | C `xpc_session`, `xpc_listener` | C `xpc_connection` |
|---|---|---|---|
| The API itself | macOS 14 | macOS 14 | macOS 10.7 |
| Pass a file descriptor | `XPCDictionary`'s `FileDescriptor` subscript is macOS 27. On macOS 14 only through `withUnsafeUnderlyingDictionary` and `xpc_dictionary_set_fd`. | `xpc_dictionary_set_fd` | `xpc_dictionary_set_fd` |
| Code signing requirement for peers | `XPCPeerRequirement`, `setPeerRequirement`: macOS 26 | `xpc_listener_set_peer_code_signing_requirement`: macOS 14.4 | `xpc_connection_set_peer_code_signing_requirement`: macOS 12 |
| The peer's user | no public accessor | no public accessor | `xpc_connection_get_euid` |

`NSXPCConnection` was not considered, because the C connection API meets every need.

## Decision

Use libxpc's C connection API (`xpc_connection_create_mach_service`, with
`XPC_CONNECTION_MACH_SERVICE_LISTENER` on the daemon's side), wrapped at the boundary in the
`MawXPC` module.

The Swift API can carry a descriptor on macOS 14, but it cannot validate peers before macOS
26. The C session API cannot either before macOS 14.4, and it cannot read the peer's user at
all. Only the connection API meets both requirements on every supported version.

Two spikes confirmed the choice before any code was built on it, on macOS 27.0.1:

1. A listener with the requirement `identifier "dev.maw.maw" or identifier "dev.maw.mawd"`
   accepted an ad-hoc signed client with the identifier `dev.maw.maw`. It rejected one signed
   as `dev.maw.evil` and a linker-signed build (identifier `xpc-spike-5555…`); the listener
   saw `Peer Forbidden`. The rejected client sees only `Connection interrupted`.
2. A descriptor from `VirtualMachine.connectToAgent`, that is, a duplicate of a
   `VZVirtioSocketConnection` descriptor, crossed XPC with `xpc_dictionary_set_fd` and carried
   a complete guest agent `exec` session in the client.

## How the wrapper works

- `XPCConnection` owns an `xpc_connection_t` and a private serial dispatch queue, which libxpc
  requires. Its events become an `AsyncStream`; a reply becomes the result of an `async`
  function. No other module sees a dispatch queue or an XPC handler block.
- `XPCServiceListener` checks each new peer before it activates it: `xpc_connection_get_euid`
  must equal the daemon's user, and `xpc_connection_set_peer_code_signing_requirement` is set
  on the connection. libxpc then checks the requirement on every message.
- Messages are XPC dictionaries with a fixed `interfaceVersion` key and a JSON body
  (`InterfaceCoding`); see `docs/daemon.md`.
- An anonymous listener (`xpc_connection_create(NULL, NULL)` and an endpoint) lets the unit
  tests run real XPC connections, descriptor passing, and peer rejection in one process, with
  no launchd service.

## Consequences

- The client cannot tell a rejection from a crash, because both appear as an interrupted
  connection. `DaemonClient` therefore checks its own code signing identifier before it
  connects and reports `clientSignatureRejected`, which names `scripts/sign-dev.sh`.
- `MawXPC` holds the only `xpc_*` calls. When maw's minimum reaches macOS 26, the module can
  move to `XPCSession`, `XPCListener`, and `XPCPeerRequirement` without changing the
  messages or the modules that use it.
