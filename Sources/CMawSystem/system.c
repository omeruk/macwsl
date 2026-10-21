#define _GNU_SOURCE
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif

#include "CMawSystem.h"

#include <errno.h>
#include <fcntl.h>
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

#if defined(__linux__)
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

int maw_suppress_sigpipe(int fd) {
#if defined(__APPLE__)
    int on = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on) == 0) {
        return 0;
    }
    if (fcntl(fd, F_SETNOSIGPIPE, 1) == 0) {
        return 0;
    }
    return errno;
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

    failure.stage = MAW_SPAWN_STAGE_WORKING_DIRECTORY;
    if (options->working_directory != NULL && chdir(options->working_directory) < 0) {
        goto fail;
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

int maw_spawn(const maw_spawn_options *options, pid_t *pid, maw_spawn_stage *stage) {
    *stage = MAW_SPAWN_STAGE_FORK;
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

    // The report pipe closes on a successful execve, so reading it returns end-of-file.
    struct spawn_failure failure;
    ssize_t count;
    do {
        count = read(report[0], &failure, sizeof failure);
    } while (count < 0 && errno == EINTR);
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

int maw_accept(int fd) {
#if defined(__linux__)
    return accept4(fd, NULL, NULL, SOCK_CLOEXEC);
#else
    int connection = accept(fd, NULL, NULL);
    if (connection >= 0) {
        set_cloexec(connection);
        maw_suppress_sigpipe(connection);
    }
    return connection;
#endif
}
