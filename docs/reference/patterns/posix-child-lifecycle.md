# Pattern: POSIX child-process lifecycle

**Scope.** Spawning a child process safely from Swift / actor-concurrent code via `posix_spawn` (never `fork+exec` from a Swift runtime), wiring up I/O via `DispatchIO`, reaping zombies via a `SIGCHLD` dispatch source, and shutting the child down gracefully via `killpg(SIGTERM) → grace → SIGKILL`. The result: no fork-safety bugs, no zombie children, no orphaned subprocess trees.

**When to use.** Any code that spawns subprocesses and needs to interact with them beyond fire-and-forget: PTYs, language servers, build tools, IDE plug-ins, helper utilities. Especially: anywhere `fork()` would be unsafe (Swift, Java, Go — most modern runtimes).

**When not to use.** Apple's `Process` (`NSTask`) suffices for stdout-capture + waitpid scenarios on macOS and is more ergonomic. Reach for `posix_spawn` when you need:

- A controlling TTY (PTY scenarios).
- File descriptor inheritance control (`POSIX_SPAWN_CLOEXEC_DEFAULT`).
- Specific session / process-group semantics (`POSIX_SPAWN_SETSID`).
- To run on Linux too (`Process` is macOS).

---

## The "no Swift between fork-equivalent and exec" rule

The Swift runtime (like the JVM, Go runtime, etc.) is *fork-unsafe*: after `fork()`, only one thread continues in the child, but the runtime's locks, allocator, and GC state are in the half-state of the moment of fork. Any subsequent Swift call (allocator, ARC retain, dictionary lookup) can deadlock or corrupt.

Two consequences:

1. **Never call `fork()` from Swift.** Period.
2. **Use `posix_spawn`** — it's a single syscall that combines fork + setup + exec atomically. The kernel handles all of it without re-entering user code.

`Process` (`NSTask`) on macOS *also* uses `posix_spawn` internally — that's why it's safe. But it doesn't expose enough control for PTY/session scenarios, so we wrap `posix_spawn` ourselves.

---

## The C shim

Pure-C code, in its own SPM target, never compiled as Swift:

```c
// Core/CPosixBridge/include/CPosixBridge.h
#pragma once

#include <sys/types.h>
#include <stdint.h>

typedef struct {
    int    master_fd;     // OUT: PTY master
    int    slave_fd;      // OUT: PTY slave (closed in parent after spawn)
    pid_t  pid;           // OUT: child pid
    int    errno_value;   // OUT: errno on failure, 0 on success
} cpx_spawn_result;

/// Opens a PTY pair with FD_CLOEXEC set on the master.
/// Returns 0 on success, -1 with errno set on failure.
int cpx_openpty(int *master_out, int *slave_out);

/// Sets the window size on a PTY master via TIOCSWINSZ.
int cpx_set_winsize(int master_fd, unsigned short rows, unsigned short cols);

/// Spawns `executable` with `argv` (NULL-terminated) and `envp` (NULL-terminated)
/// under the given PTY slave as controlling TTY. SETSID + CLOEXEC_DEFAULT.
/// `cwd` is `chdir`'d into before exec (NULL for no chdir).
/// Result struct populated regardless of success/failure (check `errno_value`).
void cpx_spawn_under_pty(
    int                 slave_fd,
    const char        * executable,
    const char *const * argv,
    const char *const * envp,
    const char        * cwd,
    cpx_spawn_result  * out
);

/// Kills the process group `pgid` with `signal`.
int cpx_killpg(pid_t pgid, int signal);

/// Sets / clears FD_CLOEXEC on `fd`.
int cpx_set_cloexec(int fd, int on);

/// Sets / clears O_NONBLOCK on `fd`.
int cpx_set_nonblock(int fd, int on);
```

```c
// Core/CPosixBridge/CPosixBridge.c
#include "include/CPosixBridge.h"
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>
#include <errno.h>

extern char **environ;

int cpx_openpty(int *master_out, int *slave_out) {
    int m = -1, s = -1;
    if (openpty(&m, &s, NULL, NULL, NULL) == -1) return -1;
    fcntl(m, F_SETFD, fcntl(m, F_GETFD, 0) | FD_CLOEXEC);
    *master_out = m;
    *slave_out = s;
    return 0;
}

int cpx_set_winsize(int fd, unsigned short rows, unsigned short cols) {
    struct winsize ws = {0};
    ws.ws_row = rows;
    ws.ws_col = cols;
    return ioctl(fd, TIOCSWINSZ, &ws);
}

void cpx_spawn_under_pty(
    int slave_fd,
    const char *executable,
    const char *const *argv,
    const char *const *envp,
    const char *cwd,
    cpx_spawn_result *out
) {
    out->master_fd = -1;
    out->slave_fd = slave_fd;
    out->pid = -1;
    out->errno_value = 0;

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attrs;
    posix_spawn_file_actions_init(&actions);
    posix_spawnattr_init(&attrs);

    // Child becomes new session leader → kernel grants slave_fd as controlling TTY.
    short flags = POSIX_SPAWN_SETSID;
    #ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;   // macOS extension
    #endif
    posix_spawnattr_setflags(&attrs, flags);

    // chdir before exec (file action — runs in child after spawn, before exec).
    if (cwd != NULL) {
        posix_spawn_file_actions_addchdir_np(&actions, cwd);
    }

    // Redirect stdin/stdout/stderr to the slave.
    posix_spawn_file_actions_adddup2(&actions, slave_fd, STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, slave_fd, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, slave_fd, STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, slave_fd);

    pid_t pid = -1;
    int rc = posix_spawnp(&pid, executable, &actions, &attrs,
                          (char *const *)argv,
                          (char *const *)(envp != NULL ? envp : environ));
    out->errno_value = (rc == 0) ? 0 : rc;
    out->pid = (rc == 0) ? pid : -1;

    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attrs);
}

int cpx_killpg(pid_t pgid, int signal) { return killpg(pgid, signal); }

int cpx_set_cloexec(int fd, int on) {
    int flags = fcntl(fd, F_GETFD, 0);
    if (flags == -1) return -1;
    flags = on ? (flags | FD_CLOEXEC) : (flags & ~FD_CLOEXEC);
    return fcntl(fd, F_SETFD, flags);
}

int cpx_set_nonblock(int fd, int on) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags == -1) return -1;
    flags = on ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK);
    return fcntl(fd, F_SETFL, flags);
}
```

**Properties:**

- C, not Swift. No allocator hand-off, no GC, no ARC across the spawn boundary.
- File actions and attrs are stack-allocated, destroyed in the same function.
- `chdir` happens *inside* `posix_spawn` (via the addchdir file action), so the parent's CWD is never modified.
- All errors return errno; the Swift wrapper translates to a typed error.

---

## The Swift wrapper actor

```swift
import CPosixBridge
import OSLog

public actor PTYHost {

    public struct ChildSpec: Sendable {
        public let executable: URL
        public let arguments: [String]
        public let environment: ResolvedEnvironment
        public let workingDirectory: URL
    }

    public let outboundBytes: AsyncStream<Data>
    private let log = Logger(subsystem: "com.codecave.Codemixer", category: "PTY")

    private let masterFD: Int32
    private let pid: pid_t
    private let pgid: pid_t
    private let readChannel: DispatchIO
    private let writeQueue: DispatchQueue
    private let outboundContinuation: AsyncStream<Data>.Continuation

    public init(spec: ChildSpec) throws(PTYError) {
        var master: Int32 = -1
        var slave: Int32 = -1
        if cpx_openpty(&master, &slave) != 0 {
            throw .openpty(errno: errno)
        }

        // Build argv/envp arrays in the parent — strdup the strings.
        let cArgv = spec.arguments.cArgv(executable: spec.executable.path)
        let cEnvp = spec.environment.snapshot().cEnvp()
        defer {
            cArgv.deallocate()
            cEnvp.deallocate()
        }

        var result = cpx_spawn_result()
        cpx_spawn_under_pty(slave,
                            spec.executable.path,
                            cArgv.pointer, cEnvp.pointer,
                            spec.workingDirectory.path,
                            &result)
        close(slave)
        if result.errno_value != 0 {
            close(master)
            throw .spawn(errno: result.errno_value, executable: spec.executable)
        }

        self.masterFD = master
        self.pid = result.pid
        self.pgid = result.pid   // SETSID makes the child its own pgrp

        _ = cpx_set_nonblock(master, 1)

        var continuation: AsyncStream<Data>.Continuation!
        self.outboundBytes = AsyncStream(bufferingPolicy: .bufferingOldest(256)) { c in
            continuation = c
        }
        self.outboundContinuation = continuation

        // DispatchIO read channel — efficient for streaming.
        self.writeQueue = DispatchQueue(label: "com.codecave.Codemixer.PTY.write.\(result.pid)")
        let readQueue = DispatchQueue(label: "com.codecave.Codemixer.PTY.read.\(result.pid)",
                                      qos: .userInitiated)
        let channel = DispatchIO(type: .stream,
                                  fileDescriptor: master,
                                  queue: readQueue) { _ in /* fd close handler */ }
        channel.setLimit(lowWater: 1)
        channel.setLimit(highWater: 64 * 1024)
        self.readChannel = channel

        startReadLoop()
        log.notice("pty spawned pid=\(self.pid, privacy: .public) executable=\(spec.executable.path, privacy: .private)")
    }

    public func write(_ data: Data) async throws(PTYError) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writeQueue.async { [masterFD] in
                let n = data.withUnsafeBytes { buf -> Int in
                    Darwin.write(masterFD, buf.baseAddress, buf.count)
                }
                if n == data.count { continuation.resume() }
                else { continuation.resume(throwing: PTYError.write(errno: errno, bytes: data.count)) }
            }
        }
    }

    public func resize(rows: Int, cols: Int) throws(PTYError) {
        guard cpx_set_winsize(masterFD, UInt16(rows), UInt16(cols)) == 0 else {
            throw .write(errno: errno, bytes: 0)
        }
    }

    public func interrupt() {
        _ = cpx_killpg(pgid, SIGINT)
    }

    public func close() async {
        log.notice("pty closing pid=\(self.pid, privacy: .public)")
        await gracefulShutdown()
        outboundContinuation.finish()
        readChannel.close(flags: [.stop])
        Darwin.close(masterFD)
    }

    private func gracefulShutdown() async {
        _ = cpx_killpg(pgid, SIGTERM)

        // 2-second grace, then SIGKILL.
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) > 0 {
                return  // exited within grace
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        _ = cpx_killpg(pgid, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)  // reap
    }

    private nonisolated func startReadLoop() {
        readChannel.read(offset: 0, length: .max, queue: .main) { [weak self] done, data, _ in
            guard let self else { return }
            if let data, !data.isEmpty {
                let copy = Data(data)
                Task { await self.deliver(copy) }
            }
            if done { Task { await self.outboundContinuation.finish() } }
        }
    }

    private func deliver(_ data: Data) async {
        outboundContinuation.yield(data)
    }
}
```

**Properties:**

- Single `actor` owning the FD, PID, PGID, read channel, write queue.
- `DispatchIO` for reads — far more efficient than a `DispatchSource.read` loop for streaming data.
- Writes go through a serial dispatch queue; one `write(2)` per call; the actor await ensures sequencing.
- `gracefulShutdown` is `SIGTERM` → 2s grace (polling `waitpid(WNOHANG)`) → `SIGKILL` → final `waitpid` to reap.
- `killpg` — kills the whole process group, so any subprocess `claude` spawned dies with it.

---

## The reaper

Even with the explicit `waitpid` in `gracefulShutdown`, child processes can die for unexpected reasons (panic, SIGSEGV). We need a global reaper:

```swift
public actor ChildReaper {

    public typealias OnExit = @Sendable (pid_t, Int32) async -> Void

    private static var shared: ChildReaper?
    private var subscribers: [OnExit] = []
    private var signalSource: DispatchSourceSignal?

    public static func install(onExit: @escaping OnExit) async {
        if shared == nil {
            shared = ChildReaper()
            await shared!.start()
        }
        await shared!.subscribe(onExit)
    }

    private func start() async {
        // Ignore SIGCHLD globally so the dispatch source can intercept it.
        signal(SIGCHLD, SIG_IGN)

        let source = DispatchSource.makeSignalSource(signal: SIGCHLD, queue: .global())
        source.setEventHandler { [weak self] in
            Task { await self?.reapAll() }
        }
        source.resume()
        self.signalSource = source
    }

    private func reapAll() async {
        while true {
            var status: Int32 = 0
            let pid = waitpid(-1, &status, WNOHANG)
            if pid <= 0 { break }  // 0 = no more children to reap; -1 = ECHILD
            for subscriber in subscribers {
                await subscriber(pid, status)
            }
        }
    }

    private func subscribe(_ onExit: @escaping OnExit) {
        subscribers.append(onExit)
    }
}
```

**Properties:**

- Installed once globally at app startup.
- `signal(SIGCHLD, SIG_IGN)` *before* installing the dispatch source — without this, zombies accumulate even with the source running.
- `waitpid(-1, ..., WNOHANG)` in a loop because multiple children may have died between SIGCHLD deliveries.
- Subscribers receive `(pid, status)` and translate the status to a typed exit reason.

---

## Argv / env marshalling

```swift
public extension Array where Element == String {
    /// Returns a NULL-terminated C string array suitable for `posix_spawn`.
    /// The caller must `.deallocate()` when done.
    func cArgv(executable: String) -> CArgvBuffer {
        var pointers: [UnsafeMutablePointer<CChar>?] = [strdup(executable)]
        for arg in self {
            pointers.append(strdup(arg))
        }
        pointers.append(nil)
        return CArgvBuffer(pointers: pointers)
    }
}

public final class CArgvBuffer {
    private var pointers: [UnsafeMutablePointer<CChar>?]
    public var pointer: UnsafePointer<UnsafePointer<CChar>?> {
        return pointers.withUnsafeBufferPointer { UnsafePointer($0.baseAddress!) }
    }
    public init(pointers: [UnsafeMutablePointer<CChar>?]) { self.pointers = pointers }
    public func deallocate() {
        for p in pointers { if let p { free(p) } }
    }
}
```

**Rules:**

- `strdup` in the parent (allocates with `malloc`, owns the lifetime).
- NULL-terminate.
- Free after `posix_spawn` returns — the child has already copied the array.
- Don't use `Array.withCString` per element — the pointers aren't valid outside the closure.

---

## Environment variable hygiene

Spawning under PTY for billing-sensitive interactive tools demands explicit env control:

```swift
public extension Dictionary where Key == String, Value == String {
    /// Removes variables that would mark the child as non-interactive (and thus mis-billed).
    func withoutBillingMarkers() -> [String: String] {
        var copy = self
        copy.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        copy.removeValue(forKey: "ANTHROPIC_API_KEY")  // ensure interactive subscription, not API key
        return copy
    }

    /// Ensures the child sees a TTY-like environment.
    func withTTYDefaults() -> [String: String] {
        var copy = self
        copy["TERM"] = copy["TERM"] ?? "xterm-256color"
        copy["COLORTERM"] = copy["COLORTERM"] ?? "truecolor"
        return copy
    }
}
```

---

## Anti-patterns

| Anti-pattern | Why it's bad | Fix |
| --- | --- | --- |
| `fork()` directly from Swift | Half-broken runtime in child; deadlocks. | `posix_spawn` only. |
| `Process` for PTY scenarios | Can't allocate the PTY or set SETSID. | Custom `posix_spawn` wrapper. |
| Forgetting `signal(SIGCHLD, SIG_IGN)` before installing the dispatch source | Zombies accumulate. | Always install both. |
| Single `waitpid` per SIGCHLD | Coalesced signals; multiple children pile up. | `while waitpid(-1, ..., WNOHANG) > 0` loop. |
| Killing the child PID only, not the group | Grand-children orphan to PID 1 (or systemd). | `killpg` — kill the whole group. |
| `SIGKILL` first | No chance for graceful cleanup; loses any final output. | `SIGTERM` → grace → `SIGKILL`. |
| Holding the slave FD open in the parent after spawn | Parent's `close(slave)` race; potentially blocks until child closes. | Close immediately after `posix_spawn` returns. |
| Allocating Swift arrays for argv mid-spawn | Defeats the no-Swift-between-spawn-and-exec rule. | Build C arrays in advance. |
| Pre-creating PTY then `chdir` in parent before spawn | Mutates parent state | `addchdir_np` in file actions. |
| Reading the PTY master with `Pipe()` / `FileHandle` | Inefficient; loses backpressure | `DispatchIO` stream channel. |

---

## Codemixer instance

- `CPosixBridge` ↔ `src/Core/CPosixBridge/`.
- `PTYHost` ↔ `Core/AgentCore/PTY/PTYHost.swift`.
- `ChildReaper` ↔ `Core/AgentCore/PTY/ChildReaper.swift`.
- Default PTY size ↔ 120 × 40, fixed across UI resizes for TUI-parser stability.
- Graceful shutdown ↔ `SIGTERM → 2s → SIGKILL` (per [docs/architecture.md §9](../../architecture.md)).

---

## Minimum viable adoption

1. Add a `CPosixBridge` C target with `cpx_openpty`, `cpx_spawn_under_pty`, `cpx_killpg`, FD utility helpers.
2. Build the Swift `PTYHost` actor wrapping the bridge.
3. Install the global `ChildReaper` at app startup.
4. Add typed `PTYError` per [typed-errors-and-wire](typed-errors-and-wire.md).
5. Test:
   - Spawn `/bin/sleep 100`; `close()` it; verify `waitpid` returns within 2s.
   - Spawn `/bin/sleep 100`; SIGSTOP it; `close()`; verify SIGKILL path takes ≤ 2.05 s.
   - Spawn `/usr/bin/yes` (high-rate output); read 1 MB; verify no drops, no leaks.

The result: subprocess management that doesn't surprise you on shutdown and doesn't leak children when things go wrong.
