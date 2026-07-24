#include "include/CPosixBridge.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <util.h>            // openpty(3)
#include <sys/ioctl.h>

int cpx_openpty(int *master_fd, int *slave_fd) {
    if (master_fd == NULL || slave_fd == NULL) {
        errno = EINVAL;
        return -1;
    }
    int m = -1, s = -1;
    if (openpty(&m, &s, NULL, NULL, NULL) != 0) {
        return -1;
    }
    // Master must not leak into spawned children.
    int flags = fcntl(m, F_GETFD);
    if (flags != -1) {
        (void)fcntl(m, F_SETFD, flags | FD_CLOEXEC);
    }
    *master_fd = m;
    *slave_fd = s;
    return 0;
}

int cpx_set_winsize(int fd, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return ioctl(fd, TIOCSWINSZ, &ws);
}

int cpx_killpg(pid_t pid, int sig) {
    // killpg takes a process *group*, which is the positive pid of the leader.
    return killpg(pid, sig);
}

int cpx_spawn_under_pty(const char *executable,
                        char *const argv[],
                        char *const envp[],
                        const char *cwd,
                        int slave_fd,
                        pid_t *out_pid) {
    if (executable == NULL || argv == NULL || out_pid == NULL || slave_fd < 0) {
        return EINVAL;
    }

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attrs;

    int rc = posix_spawn_file_actions_init(&actions);
    if (rc != 0) { return rc; }

    rc = posix_spawnattr_init(&attrs);
    if (rc != 0) {
        posix_spawn_file_actions_destroy(&actions);
        return rc;
    }

    // 1. Optional working directory (10.15+).
    if (cwd != NULL) {
        rc = posix_spawn_file_actions_addchdir_np(&actions, cwd);
        if (rc != 0) { goto cleanup; }
    }

    // 2. Wire slave fd to stdin/stdout/stderr.
    rc = posix_spawn_file_actions_adddup2(&actions, slave_fd, STDIN_FILENO);
    if (rc != 0) { goto cleanup; }
    rc = posix_spawn_file_actions_adddup2(&actions, slave_fd, STDOUT_FILENO);
    if (rc != 0) { goto cleanup; }
    rc = posix_spawn_file_actions_adddup2(&actions, slave_fd, STDERR_FILENO);
    if (rc != 0) { goto cleanup; }

    // 3. Close the original slave once duped.
    rc = posix_spawn_file_actions_addclose(&actions, slave_fd);
    if (rc != 0) { goto cleanup; }

    // 4. New session + reset signal defaults. SETSID makes the child its own
    //    session leader, which implicitly also makes it its own pgrp leader,
    //    so we don't need POSIX_SPAWN_SETPGROUP on top.
    //
    //    We deliberately don't pass POSIX_SPAWN_CLOEXEC_DEFAULT because it
    //    requires the platform to support it cleanly with our dup2 plan, and
    //    failed under sandbox-disabled but unentitled processes (EPERM).
    //    Instead we rely on FD_CLOEXEC being set on the master in
    //    `cpx_openpty`, which is the only fd we care about not leaking.
    short flags = POSIX_SPAWN_SETSIGDEF |
                  POSIX_SPAWN_SETSIGMASK |
                  POSIX_SPAWN_SETSID;
    rc = posix_spawnattr_setflags(&attrs, flags);
    if (rc != 0) { goto cleanup; }

    sigset_t empty;
    sigemptyset(&empty);
    rc = posix_spawnattr_setsigmask(&attrs, &empty);
    if (rc != 0) { goto cleanup; }

    sigset_t all_defaults;
    sigfillset(&all_defaults);
    rc = posix_spawnattr_setsigdefault(&attrs, &all_defaults);
    if (rc != 0) { goto cleanup; }

    // 5. Launch.
    pid_t pid = -1;
    rc = posix_spawn(&pid, executable, &actions, &attrs, argv, envp);
    if (rc == 0) {
        *out_pid = pid;
        // 6. Promote the new pgrp to the foreground on this tty. If the call
        //    races with a quick exit, ignore EPERM/ENOTTY/ESRCH — the child
        //    is already gone or has reparented its tty.
        (void)tcsetpgrp(slave_fd, pid);
    }

cleanup:
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attrs);
    return rc;
}
