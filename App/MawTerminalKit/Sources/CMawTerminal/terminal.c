#include "CMawTerminal.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

/// Reports `step` and errno to the parent through `report`, and ends the child. Only
/// async-signal-safe calls.
static void fail(int report, int step) {
    int failure[2] = {step, errno};
    (void)write(report, failure, sizeof failure);
    _exit(127);
}

/// The child's side, from fork to execve. Only async-signal-safe calls, and no allocation.
static void start_child(const char *path, char *const argv[], char *const envp[],
                        const char *directory, int secondary, int descriptor_limit,
                        int report) {
    // Every signal is still blocked, so that no handler of the app runs in the child.
    struct sigaction default_action = {.sa_handler = SIG_DFL, .sa_flags = 0};
    sigemptyset(&default_action.sa_mask);
    for (int number = 1; number < NSIG; number++) {
        if (number != SIGKILL && number != SIGSTOP &&
            sigaction(number, &default_action, NULL) != 0) {
            fail(report, MAW_TERMINAL_STEP_SIGNALS);
        }
    }
    if (setsid() < 0) {
        fail(report, MAW_TERMINAL_STEP_SESSION);
    }
    if (ioctl(secondary, TIOCSCTTY, 0) != 0) {
        fail(report, MAW_TERMINAL_STEP_CONTROLLING_TERMINAL);
    }
    for (int descriptor = 0; descriptor <= 2; descriptor++) {
        if (dup2(secondary, descriptor) < 0) {
            fail(report, MAW_TERMINAL_STEP_STANDARD_DESCRIPTORS);
        }
    }
    (void)chdir(directory);
    for (int descriptor = 3; descriptor < descriptor_limit; descriptor++) {
        if (descriptor != report) {
            (void)close(descriptor);
        }
    }
    sigset_t no_signals;
    sigemptyset(&no_signals);
    if (sigprocmask(SIG_SETMASK, &no_signals, NULL) != 0) {
        fail(report, MAW_TERMINAL_STEP_SIGNAL_MASK);
    }
    execve(path, argv, envp);
    fail(report, MAW_TERMINAL_STEP_EXEC);
}

pid_t maw_terminal_spawn(const char *path, char *const argv[], char *const envp[],
                         const char *directory, int secondary, int descriptor_limit,
                         int *failed_step, int *failed_errno) {
    // The child reports a failure through this pipe; execve closes it on success.
    int report[2];
    if (pipe(report) != 0) {
        *failed_step = MAW_TERMINAL_STEP_PIPE;
        *failed_errno = errno;
        return -1;
    }
    (void)fcntl(report[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(report[1], F_SETFD, FD_CLOEXEC);

    sigset_t every_signal, previous_mask;
    sigfillset(&every_signal);
    pthread_sigmask(SIG_SETMASK, &every_signal, &previous_mask);
    pid_t pid = fork();
    if (pid == 0) {
        start_child(path, argv, envp, directory, secondary, descriptor_limit, report[1]);
    }
    int fork_errno = errno;
    pthread_sigmask(SIG_SETMASK, &previous_mask, NULL);
    close(report[1]);
    if (pid < 0) {
        close(report[0]);
        *failed_step = MAW_TERMINAL_STEP_FORK;
        *failed_errno = fork_errno;
        return -1;
    }

    int failure[2];
    size_t received = 0;
    while (received < sizeof failure) {
        ssize_t count = read(report[0], (char *)failure + received, sizeof failure - received);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            break;
        }
        received += (size_t)count;
    }
    close(report[0]);
    if (received == 0) {
        return pid;
    }
    *failed_step = received == sizeof failure ? failure[0] : MAW_TERMINAL_STEP_EXEC;
    *failed_errno = received == sizeof failure ? failure[1] : EIO;
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {
    }
    return -1;
}
