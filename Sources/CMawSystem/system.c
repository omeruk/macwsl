#define _GNU_SOURCE
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif

#include "CMawSystem.h"

#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>

#if defined(__linux__)
#include <stdio.h>
#include <sys/mount.h>
#include <sys/syscall.h>
#include <linux/vm_sockets.h>
// musl does not wrap these system calls; their numbers are the same on every architecture.
#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434
#endif
#ifndef SYS_close_range
#define SYS_close_range 436
#endif
#ifndef CLOSE_RANGE_CLOEXEC
#define CLOSE_RANGE_CLOEXEC (1U << 2)
#endif
#endif

#if defined(__APPLE__)
#include <sys/event.h>
#endif

// MARK: Descriptors

static int set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0) {
        return errno;
    }
    return 0;
}

int maw_set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        return errno;
    }
    return 0;
}

int maw_set_blocking(int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) < 0) {
        return errno;
    }
    return 0;
}

int maw_duplicate(int fd) {
    return fcntl(fd, F_DUPFD_CLOEXEC, 0);
}

int maw_suppress_sigpipe(int fd) {
#if defined(__APPLE__)
    int on = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on) == 0) {
        return 0;
    }
    if (fcntl(fd, F_SETNOSIGPIPE, 1) == 0) {
        return 0;
    }
    int error = errno;
    // Once a socket's peer has closed, both calls fail with EINVAL, but the flag can still be
    // read: a socket that suppressed SIGPIPE before the close still does.
    if (fcntl(fd, F_GETNOSIGPIPE) == 1) {
        return 0;
    }
    return error;
#else
    (void)fd;
    return 0;
#endif
}

int maw_pipe(int fds[2]) {
#if defined(__linux__)
    return pipe2(fds, O_CLOEXEC) == 0 ? 0 : errno;
#else
    if (pipe(fds) != 0) {
        return errno;
    }
    int error = set_cloexec(fds[0]);
    if (error == 0) {
        error = set_cloexec(fds[1]);
    }
    if (error != 0) {
        close(fds[0]);
        close(fds[1]);
    }
    return error;
#endif
}

int maw_socketpair(int fds[2]) {
#if defined(__linux__)
    return socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, fds) == 0 ? 0 : errno;
#else
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) {
        return errno;
    }
    int error = 0;
    for (int i = 0; i < 2 && error == 0; i++) {
        error = set_cloexec(fds[i]);
        if (error == 0) {
            error = maw_suppress_sigpipe(fds[i]);
        }
    }
    if (error != 0) {
        close(fds[0]);
        close(fds[1]);
    }
    return error;
#endif
}

ssize_t maw_send(int fd, const void *buffer, size_t count) {
#if defined(__linux__)
    ssize_t sent = send(fd, buffer, count, MSG_NOSIGNAL);
    if (sent < 0 && errno == ENOTSOCK) {
        sent = write(fd, buffer, count);
    }
    return sent;
#else
    return write(fd, buffer, count);
#endif
}

// MARK: Terminals

int maw_open_pty(int *primary, int *secondary, uint16_t rows, uint16_t columns) {
    int p = posix_openpt(O_RDWR | O_NOCTTY);
    if (p < 0) {
        return errno;
    }
    char name[128];
    int error = set_cloexec(p);
    if (error == 0 && (grantpt(p) != 0 || unlockpt(p) != 0)) {
        error = errno;
    }
    if (error == 0) {
        error = ptsname_r(p, name, sizeof name);
        // Some C libraries return -1 and set errno rather than returning the error.
        if (error == -1) {
            error = errno;
        }
    }
    int s = -1;
    if (error == 0) {
        s = open(name, O_RDWR | O_NOCTTY | O_CLOEXEC);
        if (s < 0) {
            error = errno;
        }
    }
    if (error == 0) {
        error = maw_set_window_size(s, rows, columns);
    }
    if (error != 0) {
        if (s >= 0) {
            close(s);
        }
        close(p);
        return error;
    }
    *primary = p;
    *secondary = s;
    return 0;
}

int maw_set_window_size(int fd, uint16_t rows, uint16_t columns) {
    struct winsize size;
    memset(&size, 0, sizeof size);
    size.ws_row = rows;
    size.ws_col = columns;
    return ioctl(fd, TIOCSWINSZ, &size) == 0 ? 0 : errno;
}

int maw_get_window_size(int fd, uint16_t *rows, uint16_t *columns) {
    struct winsize size;
    if (ioctl(fd, TIOCGWINSZ, &size) != 0) {
        return errno;
    }
    *rows = size.ws_row;
    *columns = size.ws_col;
    return 0;
}

int maw_terminal_eof_character(int fd) {
    struct termios attributes;
    if (tcgetattr(fd, &attributes) != 0) {
        return -1;
    }
    return attributes.c_cc[VEOF];
}

// MARK: Spawning

struct spawn_failure {
    int stage;
    int error;
};

// The stage of a record that the child writes when it entered `fallback_directory`, after
// which it goes on. It is not a `maw_spawn_stage`, because it is not a failure.
#define SPAWN_RECORD_FELL_BACK 100

// Runs in the child between fork and execve: async-signal-safe calls only.
__attribute__((noreturn)) static void spawn_child(const maw_spawn_options *options,
                                                  int report) {
    struct spawn_failure failure = {MAW_SPAWN_STAGE_SESSION, 0};

    // The parent may ignore signals (the agent ignores SIGPIPE) or handle them; a new program
    // starts with default dispositions. SIGKILL and SIGSTOP fail harmlessly.
    struct sigaction default_action;
    memset(&default_action, 0, sizeof default_action);
    default_action.sa_handler = SIG_DFL;
    sigemptyset(&default_action.sa_mask);
    for (int signal = 1; signal < NSIG; signal++) {
        sigaction(signal, &default_action, NULL);
    }

    if (options->controlling_terminal) {
        if (setsid() < 0 || ioctl(options->stdin_fd, TIOCSCTTY, 0) < 0) {
            goto fail;
        }
    } else if (setpgid(0, 0) < 0) {
        goto fail;
    }

    failure.stage = MAW_SPAWN_STAGE_DESCRIPTORS;
    // Move the three descriptors above 2 first, so that installing one cannot overwrite
    // another that is still to be installed.
    int sources[3] = {options->stdin_fd, options->stdout_fd, options->stderr_fd};
    for (int i = 0; i < 3; i++) {
        sources[i] = fcntl(sources[i], F_DUPFD_CLOEXEC, 3);
        if (sources[i] < 0) {
            goto fail;
        }
    }
    for (int i = 0; i < 3; i++) {
        if (dup2(sources[i], i) < 0) {
            goto fail;
        }
    }
#if defined(__linux__)
    // Descriptors that another thread opened without O_CLOEXEC must not leak into the child.
    // CLOSE_RANGE_CLOEXEC keeps the report pipe open until execve succeeds.
    syscall(SYS_close_range, 3U, ~0U, CLOSE_RANGE_CLOEXEC);
#else
    for (int fd = 3; fd < 4096; fd++) {
        if (fd != report) {
            int flags = fcntl(fd, F_GETFD);
            if (flags >= 0) {
                fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
            }
        }
    }
#endif
    // The one descriptor that survives execve, as descriptor 3. The report pipe moves out of
    // its way first; dup2 clears close-on-exec on the copy.
    if (options->inherited_fd >= 0) {
        if (report == 3) {
            int moved = fcntl(report, F_DUPFD_CLOEXEC, 4);
            if (moved < 0) {
                goto fail;
            }
            report = moved;
        }
        if (options->inherited_fd == 3) {
            if (fcntl(3, F_SETFD, 0) < 0) {
                goto fail;
            }
        } else if (dup2(options->inherited_fd, 3) < 0) {
            goto fail;
        }
    }

    // Groups first, then the group, then the user: once the user ID is not root, the other
    // two can no longer be changed. The working directory is entered as the new user, so
    // that its permissions apply.
    if (options->set_credentials) {
        failure.stage = MAW_SPAWN_STAGE_CREDENTIALS;
#if defined(__linux__)
        size_t group_count = options->group_count;
#else
        // macOS takes the count as an int. A count that does not fit is refused rather than
        // truncated; the kernel refuses any count above NGROUPS_MAX with EINVAL as well.
        if (options->group_count > INT_MAX) {
            errno = EINVAL;
            goto fail;
        }
        int group_count = (int)options->group_count;
#endif
        if (setgroups(group_count, options->groups) < 0 || setgid(options->gid) < 0 ||
            setuid(options->uid) < 0) {
            goto fail;
        }
    }

    failure.stage = MAW_SPAWN_STAGE_WORKING_DIRECTORY;
    if (options->working_directory != NULL && chdir(options->working_directory) < 0) {
        if (options->fallback_directory == NULL) {
            goto fail;
        }
        struct spawn_failure fell_back = {SPAWN_RECORD_FELL_BACK, errno};
        if (chdir(options->fallback_directory) < 0) {
            goto fail;
        }
        while (write(report, &fell_back, sizeof fell_back) < 0 && errno == EINTR) {
        }
    }

    sigset_t empty;
    sigemptyset(&empty);
    sigprocmask(SIG_SETMASK, &empty, NULL);

    failure.stage = MAW_SPAWN_STAGE_EXEC;
    execve(options->path, options->argv, options->envp);

fail:
    failure.error = errno;
    while (write(report, &failure, sizeof failure) < 0 && errno == EINTR) {
    }
    _exit(127);
}

int maw_spawn(const maw_spawn_options *options, pid_t *pid, maw_spawn_stage *stage,
              int *fallback_error) {
    *stage = MAW_SPAWN_STAGE_FORK;
    *fallback_error = 0;
    int report[2];
    int error = maw_pipe(report);
    if (error != 0) {
        return error;
    }

    // Block every signal across fork, so that the child cannot run one of the parent's
    // handlers before it has reset them.
    sigset_t all, previous;
    sigfillset(&all);
    pthread_sigmask(SIG_SETMASK, &all, &previous);
    pid_t child = fork();
    if (child == 0) {
        close(report[0]);
        spawn_child(options, report[1]);
    }
    int fork_error = errno;
    pthread_sigmask(SIG_SETMASK, &previous, NULL);
    close(report[1]);
    if (child < 0) {
        close(report[0]);
        return fork_error;
    }

    // The report pipe closes on a successful execve, so reading it returns end-of-file. A
    // record of the fallback directory may come first.
    struct spawn_failure failure;
    ssize_t count;
    for (;;) {
        do {
            count = read(report[0], &failure, sizeof failure);
        } while (count < 0 && errno == EINTR);
        if (count == (ssize_t)sizeof failure && failure.stage == SPAWN_RECORD_FELL_BACK) {
            *fallback_error = failure.error != 0 ? failure.error : EIO;
            continue;
        }
        break;
    }
    close(report[0]);
    if (count == (ssize_t)sizeof failure) {
        while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {
        }
        *stage = (maw_spawn_stage)failure.stage;
        return failure.error != 0 ? failure.error : EIO;
    }
    *pid = child;
    return 0;
}

// MARK: Child exit

int maw_open_exit_watch(pid_t pid) {
#if defined(__linux__)
    return (int)syscall(SYS_pidfd_open, pid, 0);
#elif defined(__APPLE__)
    int queue = kqueue();
    if (queue < 0) {
        return -1;
    }
    struct kevent change;
    EV_SET(&change, pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    if (kevent(queue, &change, 1, NULL, 0, NULL) < 0) {
        int error = errno;
        close(queue);
        errno = error;
        return -1;
    }
    return queue;
#else
    (void)pid;
    errno = ENOSYS;
    return -1;
#endif
}

// MARK: vsock

int maw_vsock_listen(uint32_t port, int backlog) {
#if defined(__linux__)
    int fd = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        return -1;
    }
    struct sockaddr_vm address;
    memset(&address, 0, sizeof address);
    address.svm_family = AF_VSOCK;
    address.svm_port = port;
    address.svm_cid = VMADDR_CID_ANY;
    if (bind(fd, (struct sockaddr *)&address, sizeof address) < 0 || listen(fd, backlog) < 0) {
        int error = errno;
        close(fd);
        errno = error;
        return -1;
    }
    return fd;
#else
    (void)port;
    (void)backlog;
    errno = ENOSYS;
    return -1;
#endif
}

int maw_vsock_accept_host(int fd, uint32_t *peer_cid) {
#if defined(__linux__)
    struct sockaddr_vm address;
    socklen_t length = sizeof address;
    memset(&address, 0, sizeof address);
    int connection = accept4(fd, (struct sockaddr *)&address, &length, SOCK_CLOEXEC);
    if (connection < 0) {
        return -1;
    }
    *peer_cid = address.svm_cid;
    if (address.svm_family != AF_VSOCK || address.svm_cid != VMADDR_CID_HOST) {
        close(connection);
        errno = EPERM;
        return -1;
    }
    return connection;
#else
    (void)fd;
    *peer_cid = 0;
    errno = ENOSYS;
    return -1;
#endif
}

int maw_vsock_socket(void) {
#if defined(__linux__)
    return socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
#else
    errno = ENOSYS;
    return -1;
#endif
}

int maw_vsock_bind(int fd, uint32_t port) {
#if defined(__linux__)
    struct sockaddr_vm address;
    memset(&address, 0, sizeof address);
    address.svm_family = AF_VSOCK;
    address.svm_port = port;
    address.svm_cid = VMADDR_CID_ANY;
    return bind(fd, (struct sockaddr *)&address, sizeof address) == 0 ? 0 : errno;
#else
    (void)fd;
    (void)port;
    return ENOSYS;
#endif
}

int maw_vsock_connect(int fd, uint32_t cid, uint32_t port) {
#if defined(__linux__)
    struct sockaddr_vm address;
    memset(&address, 0, sizeof address);
    address.svm_family = AF_VSOCK;
    address.svm_port = port;
    address.svm_cid = cid;
    // Not retried on EINTR: a repeated connect would report EALREADY. The agent's sockets
    // are non-blocking, so connect does not wait and is not interrupted.
    return connect(fd, (struct sockaddr *)&address, sizeof address) == 0 ? 0 : errno;
#else
    (void)fd;
    (void)cid;
    (void)port;
    return ENOSYS;
#endif
}

// MARK: Loopback TCP

/// Fills `address` with the loopback address of the family and `port`; returns its length.
static socklen_t maw_loopback_address(int ipv6, uint16_t port, struct sockaddr_storage *address) {
    memset(address, 0, sizeof *address);
    if (ipv6) {
        struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)address;
#if defined(__APPLE__)
        in6->sin6_len = sizeof *in6;
#endif
        in6->sin6_family = AF_INET6;
        in6->sin6_port = htons(port);
        in6->sin6_addr = in6addr_loopback;
        return sizeof *in6;
    }
    struct sockaddr_in *in = (struct sockaddr_in *)address;
#if defined(__APPLE__)
    in->sin_len = sizeof *in;
#endif
    in->sin_family = AF_INET;
    in->sin_port = htons(port);
    in->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    return sizeof *in;
}

static int maw_close_preserving_errno(int fd, int error) {
    close(fd);
    return error;
}

int maw_tcp_listen_loopback(int ipv6, uint16_t port, int backlog, int reuse_address, int *fd) {
    *fd = -1;
    int socket_fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0);
    if (socket_fd < 0) {
        return errno;
    }
    // Close-on-exec and non-blocking, for the acceptor's poll. SO_REUSEPORT is never set, and
    // SO_REUSEADDR only when the caller found nothing listening on the port: with either,
    // macOS lets a bind to 127.0.0.1 succeed beside a Mac program on the wildcard address and
    // take its loopback traffic (decision 0023).
    if (fcntl(socket_fd, F_SETFD, FD_CLOEXEC) < 0) {
        return maw_close_preserving_errno(socket_fd, errno);
    }
    int error = maw_set_nonblocking(socket_fd);
    if (error != 0) {
        return maw_close_preserving_errno(socket_fd, error);
    }
#if defined(__APPLE__)
    int one = 1;
    if (setsockopt(socket_fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one) < 0) {
        return maw_close_preserving_errno(socket_fd, errno);
    }
#endif
    if (ipv6) {
        int only = 1;
        if (setsockopt(socket_fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, sizeof only) < 0) {
            return maw_close_preserving_errno(socket_fd, errno);
        }
    }
    if (reuse_address) {
        int reuse = 1;
        if (setsockopt(socket_fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof reuse) < 0) {
            return maw_close_preserving_errno(socket_fd, errno);
        }
    }
    struct sockaddr_storage address;
    socklen_t length = maw_loopback_address(ipv6, port, &address);
    if (bind(socket_fd, (struct sockaddr *)&address, length) < 0 || listen(socket_fd, backlog) < 0) {
        return maw_close_preserving_errno(socket_fd, errno);
    }
    *fd = socket_fd;
    return 0;
}

int maw_tcp_accept(int listener, int *fd) {
    *fd = -1;
    int connection;
    do {
        connection = accept(listener, NULL, NULL);
    } while (connection < 0 && errno == EINTR);
    if (connection < 0) {
        return errno;
    }
    if (fcntl(connection, F_SETFD, FD_CLOEXEC) < 0) {
        return maw_close_preserving_errno(connection, errno);
    }
    // Accepted sockets inherit O_NONBLOCK on macOS; the relay copies with blocking calls.
    int error = maw_set_blocking(connection);
    if (error != 0) {
        return maw_close_preserving_errno(connection, error);
    }
    int one = 1;
#if defined(__APPLE__)
    setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    setsockopt(connection, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    *fd = connection;
    return 0;
}

int maw_tcp_connect_loopback(int ipv6, uint16_t port, int timeout_milliseconds, int *fd) {
    *fd = -1;
    int socket_fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0);
    if (socket_fd < 0) {
        return errno;
    }
    if (fcntl(socket_fd, F_SETFD, FD_CLOEXEC) < 0) {
        return maw_close_preserving_errno(socket_fd, errno);
    }
    int error = maw_set_nonblocking(socket_fd);
    if (error != 0) {
        return maw_close_preserving_errno(socket_fd, error);
    }
    int one = 1;
#if defined(__APPLE__)
    setsockopt(socket_fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    struct sockaddr_storage address;
    socklen_t length = maw_loopback_address(ipv6, port, &address);
    if (connect(socket_fd, (struct sockaddr *)&address, length) < 0) {
        if (errno != EINPROGRESS) {
            return maw_close_preserving_errno(socket_fd, errno);
        }
        struct pollfd request = {.fd = socket_fd, .events = POLLOUT, .revents = 0};
        int ready;
        do {
            ready = poll(&request, 1, timeout_milliseconds);
        } while (ready < 0 && errno == EINTR);
        if (ready < 0) {
            return maw_close_preserving_errno(socket_fd, errno);
        }
        if (ready == 0) {
            return maw_close_preserving_errno(socket_fd, ETIMEDOUT);
        }
        int pending = 0;
        socklen_t pending_length = sizeof pending;
        if (getsockopt(socket_fd, SOL_SOCKET, SO_ERROR, &pending, &pending_length) < 0) {
            return maw_close_preserving_errno(socket_fd, errno);
        }
        if (pending != 0) {
            return maw_close_preserving_errno(socket_fd, pending);
        }
    }
    error = maw_set_blocking(socket_fd);
    if (error != 0) {
        return maw_close_preserving_errno(socket_fd, error);
    }
    setsockopt(socket_fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    *fd = socket_fd;
    return 0;
}

int maw_tcp_probe_loopback(int ipv6, uint16_t port, int timeout_milliseconds) {
    int fd;
    int error = maw_tcp_connect_loopback(ipv6, port, timeout_milliseconds, &fd);
    if (error == 0) {
        close(fd);
    }
    return error;
}

int maw_set_reset_on_close(int fd) {
    struct linger linger = {.l_onoff = 1, .l_linger = 0};
    return setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, sizeof linger) == 0 ? 0 : errno;
}

int maw_socket_option(int fd, int level, int name, int *value) {
    socklen_t length = sizeof *value;
    return getsockopt(fd, level, name, value, &length) == 0 ? 0 : errno;
}

// MARK: Socket diagnostics

#if defined(__linux__)
// linux/netlink.h is not in the Static Linux SDK's sysroot; these are its stable values.
#ifndef AF_NETLINK
#define AF_NETLINK 16
#endif
#define MAW_NETLINK_SOCK_DIAG 4
struct maw_sockaddr_nl {
    unsigned short nl_family;
    unsigned short nl_pad;
    uint32_t nl_pid;
    uint32_t nl_groups;
};
#endif

int maw_socket_diagnostics_open(void) {
#if defined(__linux__)
    return socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC, MAW_NETLINK_SOCK_DIAG);
#else
    errno = ENOSYS;
    return -1;
#endif
}

int maw_socket_diagnostics_send(int fd, const void *request, size_t count) {
#if defined(__linux__)
    struct maw_sockaddr_nl kernel;
    memset(&kernel, 0, sizeof kernel);
    kernel.nl_family = AF_NETLINK;
    ssize_t sent;
    do {
        sent = sendto(fd, request, count, 0, (struct sockaddr *)&kernel, sizeof kernel);
    } while (sent < 0 && errno == EINTR);
    if (sent < 0) {
        return errno;
    }
    return (size_t)sent == count ? 0 : EMSGSIZE;
#else
    (void)fd;
    (void)request;
    (void)count;
    return ENOSYS;
#endif
}

int maw_socket_error(int fd, int *error) {
    socklen_t length = sizeof *error;
    return getsockopt(fd, SOL_SOCKET, SO_ERROR, error, &length) == 0 ? 0 : errno;
}

int maw_openat(int directory, const char *path, int flags, int *fd) {
    int result;
    do {
        result = openat(directory, path, flags);
    } while (result < 0 && errno == EINTR);
    if (result < 0) {
        return errno;
    }
    *fd = result;
    return 0;
}

int maw_mount_virtiofs(const char *tag, int directory, const char *options) {
#if defined(__linux__)
    char target[64];
    int length = snprintf(target, sizeof target, "/proc/self/fd/%d", directory);
    if (length < 0 || (size_t)length >= sizeof target) {
        return EINVAL;
    }
    return mount(tag, target, "virtiofs", MS_NOSUID | MS_NODEV, options) == 0 ? 0 : errno;
#else
    (void)tag;
    (void)directory;
    (void)options;
    return ENOSYS;
#endif
}

// MARK: DNS in the guest

#if defined(__linux__)
#include <spawn.h>
#include <sys/inotify.h>

// linux/rtnetlink.h is not in the sysroot either; these are its stable values and layouts.
#define MAW_NETLINK_ROUTE 0
#define MAW_RTM_NEWADDR 20
#define MAW_NLMSG_ERROR 2
#define MAW_NLM_F_REQUEST 0x1
#define MAW_NLM_F_ACK 0x4
#define MAW_NLM_F_CREATE 0x400
#define MAW_NLM_F_EXCL 0x200
#define MAW_IFA_ADDRESS 1
#define MAW_IFA_LOCAL 2
#define MAW_RT_SCOPE_HOST 254
#define MAW_LOOPBACK_INDEX 1

struct maw_nlmsghdr {
    uint32_t nlmsg_len;
    uint16_t nlmsg_type;
    uint16_t nlmsg_flags;
    uint32_t nlmsg_seq;
    uint32_t nlmsg_pid;
};
struct maw_ifaddrmsg {
    uint8_t ifa_family;
    uint8_t ifa_prefixlen;
    uint8_t ifa_flags;
    uint8_t ifa_scope;
    uint32_t ifa_index;
};
struct maw_rtattr {
    uint16_t rta_len;
    uint16_t rta_type;
};
#endif

int maw_add_loopback_address(const uint8_t address[4]) {
#if defined(__linux__)
    struct {
        struct maw_nlmsghdr header;
        struct maw_ifaddrmsg message;
        struct maw_rtattr local;
        uint8_t local_address[4];
        struct maw_rtattr address;
        uint8_t address_address[4];
    } request;
    memset(&request, 0, sizeof request);
    request.header.nlmsg_len = sizeof request;
    request.header.nlmsg_type = MAW_RTM_NEWADDR;
    request.header.nlmsg_flags = MAW_NLM_F_REQUEST | MAW_NLM_F_ACK | MAW_NLM_F_CREATE | MAW_NLM_F_EXCL;
    request.header.nlmsg_seq = 1;
    request.message.ifa_family = AF_INET;
    request.message.ifa_prefixlen = 32;
    request.message.ifa_scope = MAW_RT_SCOPE_HOST;
    request.message.ifa_index = MAW_LOOPBACK_INDEX;
    request.local.rta_len = sizeof request.local + 4;
    request.local.rta_type = MAW_IFA_LOCAL;
    memcpy(request.local_address, address, 4);
    request.address.rta_len = sizeof request.address + 4;
    request.address.rta_type = MAW_IFA_ADDRESS;
    memcpy(request.address_address, address, 4);

    int fd = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC, MAW_NETLINK_ROUTE);
    if (fd < 0) {
        return errno;
    }
    struct maw_sockaddr_nl kernel;
    memset(&kernel, 0, sizeof kernel);
    kernel.nl_family = AF_NETLINK;
    ssize_t sent;
    do {
        sent = sendto(fd, &request, sizeof request, 0, (struct sockaddr *)&kernel, sizeof kernel);
    } while (sent < 0 && errno == EINTR);
    if (sent < 0) {
        return maw_close_preserving_errno(fd, errno);
    }
    // The acknowledgement: NLMSG_ERROR with 0, or with the negative errno value.
    union {
        struct maw_nlmsghdr header;
        uint8_t bytes[512];
    } reply;
    ssize_t received;
    do {
        received = recv(fd, &reply, sizeof reply, 0);
    } while (received < 0 && errno == EINTR);
    if (received < 0) {
        return maw_close_preserving_errno(fd, errno);
    }
    close(fd);
    if ((size_t)received < sizeof(struct maw_nlmsghdr) + sizeof(int32_t) ||
        reply.header.nlmsg_type != MAW_NLMSG_ERROR) {
        return EPROTO;
    }
    int32_t error;
    memcpy(&error, reply.bytes + sizeof(struct maw_nlmsghdr), sizeof error);
    return error == 0 || error == -EEXIST ? 0 : -error;
#else
    (void)address;
    return ENOSYS;
#endif
}

int maw_inet4_bind(int stream, const uint8_t address[4], uint16_t port, int backlog, int *fd) {
    *fd = -1;
    int socket_fd = socket(AF_INET, stream ? SOCK_STREAM : SOCK_DGRAM, 0);
    if (socket_fd < 0) {
        return errno;
    }
    if (fcntl(socket_fd, F_SETFD, FD_CLOEXEC) < 0) {
        return maw_close_preserving_errno(socket_fd, errno);
    }
    int error = maw_set_nonblocking(socket_fd);
    if (error != 0) {
        return maw_close_preserving_errno(socket_fd, error);
    }
    // SO_REUSEADDR, so that a restarted agent binds beside its earlier connections in
    // TIME_WAIT, and a program's UDP socket on the wildcard address with SO_REUSEADDR can
    // bind beside this one (docs/decisions/0024-dns-through-the-mac.md).
    int one = 1;
    if (setsockopt(socket_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one) < 0) {
        return maw_close_preserving_errno(socket_fd, errno);
    }
#if defined(__APPLE__)
    if (setsockopt(socket_fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one) < 0) {
        return maw_close_preserving_errno(socket_fd, errno);
    }
#endif
    struct sockaddr_in in;
    memset(&in, 0, sizeof in);
#if defined(__APPLE__)
    in.sin_len = sizeof in;
#endif
    in.sin_family = AF_INET;
    in.sin_port = htons(port);
    memcpy(&in.sin_addr, address, 4);
    if (bind(socket_fd, (struct sockaddr *)&in, sizeof in) < 0) {
        return maw_close_preserving_errno(socket_fd, errno);
    }
    if (stream && listen(socket_fd, backlog) < 0) {
        return maw_close_preserving_errno(socket_fd, errno);
    }
    *fd = socket_fd;
    return 0;
}

ssize_t maw_datagram_receive(int fd, void *buffer, size_t size,
                             struct sockaddr_storage *peer, socklen_t *peer_length) {
    *peer_length = sizeof *peer;
    ssize_t received;
    do {
#if defined(__linux__)
        received = recvfrom(fd, buffer, size, MSG_TRUNC, (struct sockaddr *)peer, peer_length);
#else
        received = recvfrom(fd, buffer, size, 0, (struct sockaddr *)peer, peer_length);
#endif
    } while (received < 0 && errno == EINTR);
    return received;
}

ssize_t maw_datagram_send(int fd, const void *buffer, size_t size,
                          const struct sockaddr_storage *peer, socklen_t peer_length) {
    ssize_t sent;
    do {
        sent = sendto(fd, buffer, size, 0, (const struct sockaddr *)peer, peer_length);
    } while (sent < 0 && errno == EINTR);
    return sent;
}

int maw_inotify_open(void) {
#if defined(__linux__)
    return inotify_init1(IN_CLOEXEC | IN_NONBLOCK);
#else
    errno = ENOSYS;
    return -1;
#endif
}

int maw_inotify_watch(int fd, const char *path) {
#if defined(__linux__)
    uint32_t mask = IN_CREATE | IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_DELETE;
    return inotify_add_watch(fd, path, mask) < 0 ? errno : 0;
#else
    (void)fd;
    (void)path;
    return ENOSYS;
#endif
}

int maw_run_quietly(char *const argv[], int *status) {
#if defined(__linux__)
    posix_spawn_file_actions_t actions;
    int error = posix_spawn_file_actions_init(&actions);
    if (error != 0) {
        return error;
    }
    for (int stream = 0; stream <= 2; stream++) {
        error = posix_spawn_file_actions_addopen(
            &actions, stream, "/dev/null", stream == 0 ? O_RDONLY : O_WRONLY, 0);
        if (error != 0) {
            posix_spawn_file_actions_destroy(&actions);
            return error;
        }
    }
    char *environment[] = {NULL};
    pid_t pid;
    error = posix_spawn(&pid, argv[0], &actions, NULL, argv, environment);
    posix_spawn_file_actions_destroy(&actions);
    if (error != 0) {
        return error;
    }
    pid_t waited;
    do {
        waited = waitpid(pid, status, 0);
    } while (waited < 0 && errno == EINTR);
    return waited < 0 ? errno : 0;
#else
    (void)argv;
    (void)status;
    return ENOSYS;
#endif
}
