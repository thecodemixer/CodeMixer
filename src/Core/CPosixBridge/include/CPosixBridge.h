// CPosixBridge — POSIX primitives Swift cannot reach cleanly.
//
// Everything here is a thin wrapper over a libc/Darwin call. No allocation,
// no logging, no policy. Headers exist so Swift can see the function
// prototypes; bodies live in the matching `.c` files.

#ifndef CPOSIX_BRIDGE_H
#define CPOSIX_BRIDGE_H

#include <sys/types.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Allocate a pseudo-terminal pair.
///
/// On success writes the master and slave file descriptors to `master_fd` /
/// `slave_fd` and returns 0. On failure returns -1 and sets `errno`. Both
/// descriptors are opened `O_RDWR | O_NOCTTY` and have `FD_CLOEXEC` set on
/// the master.
int cpx_openpty(int *master_fd, int *slave_fd);

/// Apply a window size to a pty file descriptor (TIOCSWINSZ).
/// Returns 0 on success, -1 on failure (sets `errno`).
int cpx_set_winsize(int fd, unsigned short rows, unsigned short cols);

/// Spawn a child process under a controlling terminal.
///
/// The slave fd is duped to stdin/stdout/stderr, `setsid()` is called, the
/// slave is made the controlling terminal, and the child's process group is
/// made the foreground group of the pty. All performed with an
/// async-signal-safe sequence inside `posix_spawn_file_actions`.
///
/// On success writes the child pid to `out_pid` and returns 0. On failure
/// returns the `errno` value (positive) — does NOT set `errno`.
///
/// Caller owns `argv` / `envp`; both must be NULL-terminated. `cwd` may be
/// NULL (inherit). `slave_fd` is closed in the child only; the parent must
/// close its own copy.
int cpx_spawn_under_pty(const char *executable,
                        char *const argv[],
                        char *const envp[],
                        const char *cwd,
                        int slave_fd,
                        pid_t *out_pid);

/// Send a signal to a process group (negates `pid` and forwards to `kill(2)`).
int cpx_killpg(pid_t pid, int sig);

/// Set FD_CLOEXEC on a file descriptor. Returns 0 on success, -1 on failure.
int cpx_set_cloexec(int fd);

/// Make a file descriptor non-blocking. Returns 0 on success, -1 on failure.
int cpx_set_nonblock(int fd);

#ifdef __cplusplus
}
#endif

#endif /* CPOSIX_BRIDGE_H */
