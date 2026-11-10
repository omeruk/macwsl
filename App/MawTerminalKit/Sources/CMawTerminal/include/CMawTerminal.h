// Starts a local shell on a pseudo-terminal, as its controlling terminal.
//
// posix_spawn cannot do this on macOS: it runs its file actions before POSIX_SPAWN_SETSID, so the
// child opens the terminal before it leads a session and gets no controlling terminal, and it
// cannot call TIOCSCTTY. The child of a fork may only make async-signal-safe calls, and Swift
// allocates and takes runtime locks, so the child runs here, in C, until execve.

#ifndef CMAWTERMINAL_H
#define CMAWTERMINAL_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The step of `maw_terminal_spawn` that failed.
typedef enum maw_terminal_step {
    MAW_TERMINAL_STEP_PIPE = 1,
    MAW_TERMINAL_STEP_FORK,
    MAW_TERMINAL_STEP_SIGNALS,
    MAW_TERMINAL_STEP_SESSION,
    MAW_TERMINAL_STEP_CONTROLLING_TERMINAL,
    MAW_TERMINAL_STEP_STANDARD_DESCRIPTORS,
    MAW_TERMINAL_STEP_SIGNAL_MASK,
    MAW_TERMINAL_STEP_EXEC,
} maw_terminal_step;

/// Forks a child that resets every catchable signal to its default, starts a session, makes
/// `secondary` its controlling terminal and its standard input, output, and error, changes to
/// `directory` (staying where it is if that fails, as forkpty's callers did), closes every other
/// descriptor below `descriptor_limit`, clears its signal mask, and executes `path`.
///
/// Returns the child's process ID once `execve` has succeeded, or -1 with the failed step and
/// its errno in `failed_step` and `failed_errno`; a child that failed has been reaped.
pid_t maw_terminal_spawn(const char *path, char *const argv[], char *const envp[],
                         const char *directory, int secondary, int descriptor_limit,
                         int *failed_step, int *failed_errno);

#ifdef __cplusplus
}
#endif

#endif
