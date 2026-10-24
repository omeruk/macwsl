// System calls that Swift cannot make directly, or cannot make safely.
//
// - Variadic C functions (`ioctl`, `fcntl`, `syscall`) are not imported into Swift.
// - The child side of `fork` may only make async-signal-safe calls. Swift code allocates and
//   takes runtime locks, so the child runs here, in C, until `execve`.
// - Linux-only interfaces (vsock, `pidfd_open`) need kernel headers and syscall numbers.
//
// docs/decisions/0006-system-call-helpers-in-c.md records the design. Every function returns
// 0 on success or an errno value on failure, unless stated otherwise.

#ifndef CMAWSYSTEM_H
#define CMAWSYSTEM_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// What `maw_spawn` does in the child before `execve`.
typedef struct maw_spawn_options {
    /// The executable's path. The caller has already searched PATH.
    const char *path;
    /// NULL-terminated argument vector.
    char *const *argv;
    /// NULL-terminated environment, `NAME=value` strings.
    char *const *envp;
    /// The working directory, or NULL to inherit the parent's.
    const char *working_directory;
    /// Descriptors that become the child's standard input, output, and error.
    int stdin_fd;
    int stdout_fd;
    int stderr_fd;
    /// Nonzero: start a new session and make `stdin_fd`, a terminal, its controlling terminal.
    /// Zero: start a new process group, so that signals can be sent to the whole group.
    int controlling_terminal;
    /// Nonzero: set the supplementary groups to `groups`, then the group ID to `gid`, then the
    /// user ID to `uid`, before changing the working directory.
    int set_credentials;
    uid_t uid;
    gid_t gid;
    const gid_t *groups;
    size_t group_count;
} maw_spawn_options;

/// The step at which a failed `maw_spawn` stopped.
typedef enum maw_spawn_stage {
    MAW_SPAWN_STAGE_FORK = 0,
    MAW_SPAWN_STAGE_SESSION = 1,
    MAW_SPAWN_STAGE_DESCRIPTORS = 2,
    MAW_SPAWN_STAGE_WORKING_DIRECTORY = 3,
    MAW_SPAWN_STAGE_EXEC = 4,
    MAW_SPAWN_STAGE_CREDENTIALS = 5,
} maw_spawn_stage;

/// Starts a child process. In the child, every signal disposition is reset to its default and
/// the signal mask is cleared, then the session or process group is set up, the standard
/// descriptors are installed, every other descriptor is closed on exec, the working directory
/// is changed, and `path` is executed.
///
/// Returns once the child has executed `path`, or has failed to. On failure, the child has
/// already been reaped, and `*stage` names the step that failed.
int maw_spawn(const maw_spawn_options *options, pid_t *pid, maw_spawn_stage *stage);

/// Opens a pseudo-terminal pair with the given window size. Both descriptors are close-on-exec,
/// and neither becomes the caller's controlling terminal.
int maw_open_pty(int *primary, int *secondary, uint16_t rows, uint16_t columns);

/// Sets a terminal's window size, which sends SIGWINCH to its foreground process group.
int maw_set_window_size(int fd, uint16_t rows, uint16_t columns);

/// Reads a terminal's window size.
int maw_get_window_size(int fd, uint16_t *rows, uint16_t *columns);

/// The terminal's end-of-file character (VEOF), or -1 with errno set.
int maw_terminal_eof_character(int fd);

/// Makes a descriptor non-blocking.
int maw_set_nonblocking(int fd);

/// Stops writes to a socket or pipe whose reader has gone from raising SIGPIPE, where the
/// platform allows that per descriptor (Darwin). Elsewhere, use `maw_send` for sockets.
int maw_suppress_sigpipe(int fd);

/// Creates a pipe whose two descriptors are close-on-exec.
int maw_pipe(int fds[2]);

/// Creates a connected pair of stream sockets, both close-on-exec and without SIGPIPE.
int maw_socketpair(int fds[2]);

/// `send` without SIGPIPE. Returns the number of bytes sent, or -1 with errno set. Falls back
/// to `write` for descriptors that are not sockets.
ssize_t maw_send(int fd, const void *buffer, size_t count);

/// Opens a descriptor that becomes readable when the child `pid` exits: a pidfd on Linux, a
/// kqueue on Darwin. Returns the descriptor, or -1 with errno set.
int maw_open_exit_watch(pid_t pid);

/// Opens a listening vsock stream socket on `port` for any context ID. Returns the descriptor,
/// or -1 with errno set (ENOSYS outside Linux).
int maw_vsock_listen(uint32_t port, int backlog);

/// Accepts a vsock connection only if it comes from the host (context ID 2). A connection from
/// any other context, such as a process inside the guest through the loopback transport, is
/// closed: it returns -1 with errno set to EPERM and the peer's context ID in `peer_cid`.
/// The new descriptor is close-on-exec. ENOSYS outside Linux.
int maw_vsock_accept_host(int fd, uint32_t *peer_cid);

/// Opens a non-blocking, close-on-exec vsock stream socket. Returns the descriptor, or -1 with
/// errno set (ENOSYS outside Linux).
int maw_vsock_socket(void);

/// Binds a vsock socket to `port` for any context ID. Ports up to 1023 need
/// CAP_NET_BIND_SERVICE in the initial user namespace; without it the result is EACCES.
int maw_vsock_bind(int fd, uint32_t port);

/// Connects a vsock socket to `port` of context `cid`. On a non-blocking socket the result is
/// EINPROGRESS while the connection is being made; `maw_socket_error` then gives its outcome
/// once the socket is writable.
int maw_vsock_connect(int fd, uint32_t cid, uint32_t port);

/// The socket's pending error (SO_ERROR), which it also clears: 0 after a successful
/// non-blocking connect. Returns 0 and sets `*error`, or returns an errno value.
int maw_socket_error(int fd, int *error);

#ifdef __cplusplus
}
#endif

#endif
