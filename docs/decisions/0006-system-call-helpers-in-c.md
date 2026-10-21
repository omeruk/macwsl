# 0006: System calls that Swift cannot make go through a small C target

- Status: Accepted
- Date: 2026-10-21

## Context

The guest agent starts processes on pseudo-terminals, waits for them, and listens on vsock.
The host client and the unit tests use the same code on macOS. Several of the system calls
involved cannot be made from Swift, or not safely:

- **Variadic C functions are not imported into Swift.** `ioctl` (`TIOCSCTTY`, `TIOCSWINSZ`,
  `TIOCGWINSZ`), `fcntl` (`O_NONBLOCK`, `F_SETNOSIGPIPE`, `F_DUPFD_CLOEXEC`), and `syscall`
  are variadic. Darwin's overlay wraps some of them, glibc's fewer, and musl's none.
- **The child side of `fork` may only make async-signal-safe calls** until it executes a new
  program. The agent is multithreaded, and Swift code may allocate or take runtime locks,
  which can deadlock in the child. Foundation's `Process` and swift-subprocess solve this the
  same way, in C.
- **`posix_spawn` cannot set a controlling terminal.** It can start a new session, but has no
  step for `ioctl(TIOCSCTTY)`, and relying on the implicit acquisition at `open` differs
  between Linux and Darwin.
- **Linux-only interfaces** need kernel headers and system call numbers: `AF_VSOCK` with
  `struct sockaddr_vm`, and `pidfd_open` and `close_range`, which musl does not wrap.

## Decision

A C target, `CMacWSLSystem`, holds these calls behind a small, documented interface
(`Sources/CMacWSLSystem/include/CMacWSLSystem.h`). Every function returns 0 or an errno value.
It is MacWSL's own code, not a third-party dependency.

- `macwsl_spawn` forks with every signal blocked. The child resets every signal disposition
  to the default and clears the signal mask, starts a new session and sets the controlling
  terminal (terminal mode) or starts a new process group (pipe mode), installs the standard
  descriptors, marks every other descriptor close-on-exec (`close_range` on Linux), changes
  the working directory, and calls `execve`. A failure at any step is written to a
  close-on-exec pipe with the step and errno, so the parent can report "command not found" or
  a missing working directory precisely. The parent searches PATH before forking.
- `macwsl_open_pty` uses `posix_openpt`, `grantpt`, `unlockpt`, and `ptsname_r`, which musl
  and Darwin both provide, instead of `openpty`, which needs `libutil` on some systems.
- `macwsl_open_exit_watch` returns a descriptor that becomes readable when a child exits: a
  pidfd from `syscall(SYS_pidfd_open, pid, 0)` on Linux, and a kqueue with `EVFILT_PROC` on
  Darwin, where the unit tests run. Each exec session polls its own child's descriptor, so the
  agent never calls `waitpid(-1)` and never collects a process that is not its own; inside
  `swift test` that would take other tests' children.
- `macwsl_vsock_listen`, `macwsl_accept`, `macwsl_send` (with `MSG_NOSIGNAL`), and the
  descriptor helpers cover the rest.

Platform differences stay inside the C file. The Swift code above it, in `MacWSLProtocol` and
`MacWSLAgentKit`, is the same on Linux and macOS, which is what lets the unit tests run the
agent's session code on macOS over socket pairs.

## Consequences

- The package has one C target. It builds with the Static Linux SDK's clang and with Xcode's.
- The child-side code is short and must stay async-signal-safe. Changes to it need the same
  care as a signal handler.
