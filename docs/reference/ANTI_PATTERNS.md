# Anti-pattern catalog

A consolidated, searchable index of "do not do this" across the pattern library. Skim it during code review; grep it before merging.

Each entry follows the same shape:

- **Symptom.** What it looks like in code or in PRs.
- **Why it bites.** The specific failure mode it produces.
- **Fix.** Where to look in the library for the right shape.

Entries are grouped by domain. Many anti-patterns appear in multiple patterns; this index links to the authoritative source.

---

## Concurrency and Sendability

### `@MainActor` on engine / IO / network code

- **Symptom.** A subprocess wrapper or network handler annotated `@MainActor` "to make the UI binding easier."
- **Why it bites.** The engine can no longer run in a headless daemon; the UI thread carries IO work; cancellation semantics get weird.
- **Fix.** Engine code is a plain `actor`. The UI sits at the boundary and reads via `await`. See [strict-concurrency-layout](patterns/strict-concurrency-layout.md) and [headless-remote-duality](patterns/headless-remote-duality.md).

### Bare `@unchecked Sendable` with no justification

- **Symptom.** A type marked `@unchecked Sendable` with no surrounding comment explaining why it's safe.
- **Why it bites.** The reader has to reverse-engineer the safety argument; future maintainers add mutation without realising they're breaking the invariant.
- **Fix.** Require a `// SAFETY:` comment on every `@unchecked Sendable`. Lint-enforced. See [strict-concurrency-layout](patterns/strict-concurrency-layout.md).

### Locks instead of actors

- **Symptom.** `NSLock`, `os_unfair_lock`, `DispatchSemaphore` for serialising mutation in new code.
- **Why it bites.** Re-entrancy bugs; impossible to reason about deadlock; bypasses Swift's concurrency model.
- **Fix.** Use an `actor`. The whole point. See [strict-concurrency-layout](patterns/strict-concurrency-layout.md).

### Capturing `self` in unstructured tasks

- **Symptom.** `Task { self.doThing() }` inside an actor without `[weak self]`.
- **Why it bites.** Long-lived tasks pin the actor in memory even after its owner releases it. With cancellation cooperation missing, the task can outlive everything.
- **Fix.** `Task { [weak self] in await self?.doThing() }` for long-lived work; verify cancellation in `deinit`.

### Sync barriers from async code (`DispatchSemaphore.wait()` inside `Task`)

- **Symptom.** Bridging async results back to sync code with semaphores.
- **Why it bites.** Burns a thread; deadlocks under cooperative-thread starvation; bypasses task cancellation.
- **Fix.** Stay async all the way up; use `await`. If a sync entry point is unavoidable, use a `CheckedContinuation`-based bridge documented as such.

---

## Errors

### `NSError` / `Error.localizedDescription` for new errors

- **Symptom.** `throw NSError(domain:..., code:..., userInfo:[NSLocalizedDescriptionKey: "..."])`.
- **Why it bites.** Loses type information; `catch` becomes string-matching; non-localised; not `Codable`.
- **Fix.** Define a typed enum per module. See [typed-errors-and-wire](patterns/typed-errors-and-wire.md).

### `case other(String)` as a catch-all

- **Symptom.** A typed error enum with a final `case other(String)` for "everything else."
- **Why it bites.** Defeats the closed-set property; every new failure tends to land here; exhaustive `switch` becomes meaningless.
- **Fix.** Define real cases. Add new ones when you're surprised.

### Pre-formatted strings in associated values

- **Symptom.** `case fileError(message: String)` instead of `case fileError(path: URL, errno: Int32)`.
- **Why it bites.** The wire can't decompose; localisation can't reformat; UI can't surface a useful action.
- **Fix.** Associated values carry the *facts*, not formatted prose.

### `try?` for routine errors

- **Symptom.** `let result = try? doSomething()` for an operation that meaningfully fails.
- **Why it bites.** Silences the error; nothing logged; user sees a generic "didn't work."
- **Fix.** `catch` and decide. Either log and recover, or propagate.

### Naked `fatalError(...)` in production paths

- **Symptom.** `fatalError("this should never happen")`.
- **Why it bites.** Crashes are forever; no audit log; no chance for cleanup.
- **Fix.** Use `Logger.fatal` (logs first, then exits). Reserve `fatalError` for genuinely unreachable code. See [structured-logging-with-privacy](patterns/structured-logging-with-privacy.md).

### Catching `any Error` everywhere

- **Symptom.** Every `do/catch` ends with `catch { /* swallow */ }`.
- **Why it bites.** Real bugs disappear; the program limps on with corrupted state.
- **Fix.** Catch specific types; let unknown errors propagate.

---

## Logging

### `print(...)` for logging

- **Symptom.** `print("user clicked button")`.
- **Why it bites.** Goes to stderr in debug, nowhere in release. Not searchable. Floods Xcode console.
- **Fix.** `Logger` per module. See [structured-logging-with-privacy](patterns/structured-logging-with-privacy.md). Lint-enforced.

### Missing `privacy:` interpolation

- **Symptom.** `log.notice("user \(name) did \(action)")`.
- **Why it bites.** Defaults to `.private` (good — but easy to over-redact and lose diagnostic value); explicit tagging makes the privacy story auditable.
- **Fix.** Every interpolation: `log.notice("user \(name, privacy: .private) did \(action, privacy: .public)")`. Lint-enforced.

### One ad-hoc `Logger` per call site

- **Symptom.** `Logger(subsystem: ..., category: ...).info(...)` inline.
- **Why it bites.** Categories proliferate; nothing groups cleanly in Console.
- **Fix.** Declare loggers in `Loggers.swift`; reference via `private let log = Loggers.engine`.

### Logging payloads "for debug"

- **Symptom.** `log.info("response: \(fullPayload, privacy: .public)")` left in after a debugging session.
- **Why it bites.** PII leaks to Console / Apple sysdiagnose / log aggregators.
- **Fix.** Code-review for it. CI rejects `.public` on values typed as `Data`, `String?` where the source is user input.

### `notice` for per-byte / per-event hot loops

- **Symptom.** Logging every byte read from a PTY, every keystroke.
- **Why it bites.** Saturates Console; persistent log storage fills.
- **Fix.** `debug` for high-frequency; `notice` for state changes.

---

## Storage

### `Data.write(to:)` without `.atomic`

- **Symptom.** `try data.write(to: url)` for important state.
- **Why it bites.** Power loss leaves a torn file; next read crashes or yields nonsense.
- **Fix.** Always `.atomic`. Or use the explicit temp+rename pattern. See [atomic-file-persistence](patterns/atomic-file-persistence.md).

### No `schemaVersion` field

- **Symptom.** `struct Prefs: Codable { let theme: String; let voice: Bool }`.
- **Why it bites.** Adding any field that needs migration becomes a one-way trip; older binaries can't tell new files from corrupt files.
- **Fix.** First property is `schemaVersion: Int`. See [atomic-file-persistence](patterns/atomic-file-persistence.md).

### Decode-then-check version

- **Symptom.** Decoding the whole struct, then reading `.schemaVersion`.
- **Why it bites.** If the payload shape changed, the decoder throws before the check.
- **Fix.** Probe version first with a tiny `VersionProbe: Codable`; then dispatch to the right decoder.

### Multi-process writers without coordination

- **Symptom.** GUI and daemon both writing prefs.
- **Why it bites.** Last-write wins; data loss.
- **Fix.** Designate one writer (typically the daemon); other processes send commands. Or use a real database.

### Storing secrets in prefs / on-disk files

- **Symptom.** API tokens, bearer tokens, PINs in `prefs.json`.
- **Why it bites.** Filesystem-readable. Backups, sync services, accidental commits.
- **Fix.** Keychain only. See [lan-pairing-and-auth](patterns/lan-pairing-and-auth.md).

---

## Processes and IO

### `fork()` directly from Swift

- **Symptom.** Calling `Darwin.fork()` or `Glibc.fork()` and continuing in Swift.
- **Why it bites.** The Swift runtime is fork-unsafe; child deadlocks or corrupts.
- **Fix.** `posix_spawn`. See [posix-child-lifecycle](patterns/posix-child-lifecycle.md).

### `Process` (`NSTask`) for PTY scenarios

- **Symptom.** `let task = Process(); task.standardOutput = pipe; ...` to wrap an interactive CLI.
- **Why it bites.** Can't allocate a PTY; can't `setsid`; the spawned CLI thinks it's non-interactive (billing implications).
- **Fix.** `posix_spawn` + `openpty` via [`CPosixBridge`](patterns/posix-child-lifecycle.md).

### Forgetting `signal(SIGCHLD, SIG_IGN)` before installing the reaper

- **Symptom.** Long-running daemon accumulates zombie children.
- **Why it bites.** Eventually exhausts the process table.
- **Fix.** Install both: `signal(SIGCHLD, SIG_IGN)` *then* the dispatch source. See [posix-child-lifecycle](patterns/posix-child-lifecycle.md).

### Single `waitpid` per `SIGCHLD`

- **Symptom.** The reaper calls `waitpid` once on each signal delivery.
- **Why it bites.** Multiple child exits can collapse into one signal; some get missed.
- **Fix.** Loop until `waitpid(-1, ..., WNOHANG)` returns 0.

### `SIGKILL` first

- **Symptom.** `cpx_killpg(pgid, SIGKILL)` straight away on shutdown.
- **Why it bites.** Loses the chance for graceful shutdown; loses final output; corrupts state the child might've flushed.
- **Fix.** `SIGTERM` → grace window → `SIGKILL`. See [posix-child-lifecycle](patterns/posix-child-lifecycle.md).

### Killing the child PID only, not the process group

- **Symptom.** `kill(pid, SIGTERM)` for a child that may have spawned grandchildren.
- **Why it bites.** Grand-children orphan to PID 1; the resource tree leaks.
- **Fix.** `killpg(pgid, ...)`. The whole group dies together.

### `Pipe()` / `FileHandle` for high-throughput PTY reads

- **Symptom.** A read loop on `pipe.fileHandleForReading.availableData`.
- **Why it bites.** Per-byte overhead; loses backpressure; awkward concurrency.
- **Fix.** `DispatchIO.stream` channel. Far more efficient.

---

## Filesystem watching

### No debounce on FSEvents / inotify

- **Symptom.** Every kernel event triggers a recompute.
- **Why it bites.** Editor saves fire 4× (temp + rename); git checkout fires hundreds.
- **Fix.** 50 ms debounce minimum. See [filesystem-watch-with-debounce](patterns/filesystem-watch-with-debounce.md).

### `git check-ignore` per event

- **Symptom.** Subprocess per file change.
- **Why it bites.** CPU-bound under any load.
- **Fix.** Cheap path-based rules first; cache; batch slow checks per debounce window.

### Forgetting to stop the stream on actor deinit

- **Symptom.** Watcher actor goes out of scope; no `stop()` called; FSEventStream keeps firing.
- **Why it bites.** Use-after-free; crash on next event.
- **Fix.** Explicit `stop()` before drop; defensive nil-check in callbacks.

---

## IPC and networking

### Single connection actor for all clients

- **Symptom.** One actor handles every connection's I/O sequentially.
- **Why it bites.** One slow client stalls everyone.
- **Fix.** One actor per client; the listener spawns and forgets. See [ipc-server-listener](patterns/ipc-server-listener.md).

### Trusting peer identity on loopback TCP without auth

- **Symptom.** Daemon binds to `127.0.0.1:8080` and accepts any local connection.
- **Why it bites.** Any local process can impersonate.
- **Fix.** Bearer-token auth or Unix-domain socket with `0o600` perms. See [lan-pairing-and-auth](patterns/lan-pairing-and-auth.md).

### Stale socket files surviving crash

- **Symptom.** EADDRINUSE on every restart after a crashed shutdown.
- **Why it bites.** Daemon won't start.
- **Fix.** `unlink` the socket path on startup; retry once.

### No shutdown timeout on the listener

- **Symptom.** `await client.close()` for every client during shutdown.
- **Why it bites.** A stuck client hangs the daemon forever.
- **Fix.** Bound the grace window: `withTimeout(.seconds(2)) { await waitForClients() }` then force-close.

### Sending without awaiting completion

- **Symptom.** `connection.send(content: data, completion: .contentProcessed { _ in })`, no await.
- **Why it bites.** Reply order races with command order.
- **Fix.** Use a `CheckedContinuation` to await completion.

---

## Adapters and protocols

### Engine knowing the adapter type

- **Symptom.** `if adapter is ClaudeAdapter { ... }`.
- **Why it bites.** Adding a second adapter requires touching the engine.
- **Fix.** Capabilities, not type checks. See [plugin-adapter-protocol](patterns/plugin-adapter-protocol.md).

### Adapter leaking vendor types into the engine

- **Symptom.** `AgentEvent.claudeHook(ClaudeHookEvent)` in the shared event enum.
- **Why it bites.** The engine and other adapters can't ignore Claude-specific shapes.
- **Fix.** The adapter translates vendor events to neutral `AgentEvent` cases.

### Capability flags by string

- **Symptom.** `adapter.capabilities.contains("voice_input")`.
- **Why it bites.** Typos compile; no IDE autocomplete; no exhaustive `switch`.
- **Fix.** `enum Capability: String, Sendable`.

---

## Wire boundary

### Rich Foundation types crossing the wire

- **Symptom.** `AgentEventWire` contains `Date`, `URL`, `UUID` as native types.
- **Why it bites.** Format depends on encoder configuration; cross-platform clients (TypeScript, Kotlin) decode incorrectly.
- **Fix.** Wire types use strings: ISO-8601 dates, URL strings, UUID strings. See [wire-domain-boundary](patterns/wire-domain-boundary.md).

### Adding a wire field without bumping `v:`

- **Symptom.** Adding a non-optional field to a `Codable` wire DTO.
- **Why it bites.** Old clients can't decode; new server breaks them silently.
- **Fix.** Additive changes are *optional*; breaking changes bump `v:` and ship both decoders.

### Spreading domain↔wire conversion across files

- **Symptom.** Each module converts its own types ad hoc.
- **Why it bites.** Conversions drift; parity tests are hard.
- **Fix.** One `WireCodec` per module pair; one round-trip parity test.

---

## UI / visual

### Hardcoded colours / fonts

- **Symptom.** `Color(red: 0.2, green: 0.4, blue: 0.6)` in a view.
- **Why it bites.** Bypasses theming; dark-mode parity breaks; design tokens become unenforceable.
- **Fix.** `Color.themeAccent` (or whatever the project's `Theme` exposes). See `docs/visual-style.md`.

### Logic in `body`

- **Symptom.** Complex `if/else` branches in a view's `body`.
- **Why it bites.** Re-renders on every state change; hard to test.
- **Fix.** View model exposes a typed enum; `body` switches over it.

### Magic numbers for spacing

- **Symptom.** `.padding(.horizontal, 17)` because "it looked right."
- **Why it bites.** Inconsistency across the app; design changes require grep.
- **Fix.** `Theme.Spacing.md` (or equivalent). See `docs/visual-style.md`.

---

## Testing

### Mocks of seams that are protocols

- **Symptom.** A mocking framework generates a mock of `Clock`.
- **Why it bites.** Mock semantics rarely match real semantics; tests become tautological.
- **Fix.** Hand-rolled `FakeClock` that you can reason about. See [dependency-injection-seams](patterns/dependency-injection-seams.md).

### Real `Date()` / `UUID()` / `FileManager` in tests

- **Symptom.** Test asserts `event.timestamp == Date()`.
- **Why it bites.** Flaky; non-deterministic; debugging requires re-reading the test multiple times.
- **Fix.** Inject `Clock`, `RandomSource`, `FileSystem` via seams.

### Single mega-test class

- **Symptom.** `EverythingTests.swift` with 200 test methods.
- **Why it bites.** Long compile times; impossible to navigate; concurrency interference across tests.
- **Fix.** One test file per source file. Swift Testing's `@Suite` for grouping.

### `Task.sleep` in tests for synchronisation

- **Symptom.** `await Task.sleep(for: .milliseconds(200))` then assert.
- **Why it bites.** Flaky; slow.
- **Fix.** Inject a `FakeClock` you can advance deterministically. Or `await` a specific event.

---

## Performance

### Loading every file on startup

- **Symptom.** App reads every cache file at launch to "warm up."
- **Why it bites.** Cold-launch time degrades linearly with cache size.
- **Fix.** Lazy load; only the prefs and recent-projects file at startup.

### Synchronous I/O on the main actor

- **Symptom.** `FileManager.contentsOfDirectory(...)` from a view.
- **Why it bites.** UI hangs.
- **Fix.** Move to an `actor`; expose async query; SwiftUI loads via `.task`.

---

## Documentation

### Comments narrating code

- **Symptom.** `// Increment the counter` above `counter += 1`.
- **Why it bites.** Adds noise; goes stale; reviewers learn to ignore comments.
- **Fix.** Comments explain *why*. Code says *what*. See `docs/code-style.md`.

### "TODO" with no owner / date

- **Symptom.** `// TODO: fix this`.
- **Why it bites.** Lives forever.
- **Fix.** Open an issue; reference it: `// TODO(#142): handle empty workspace`.

### Out-of-tree documentation drifting from code

- **Symptom.** A wiki page describing how the engine works that's 6 months stale.
- **Why it bites.** Worse than no docs.
- **Fix.** Docs in-repo. Code review includes doc updates. See `docs/architecture.md`.

---

## Process

### Skipping `make fmt lint test` before push

- **Symptom.** CI catches it; PR cycle adds an extra round-trip.
- **Why it bites.** Reviewer's time wasted.
- **Fix.** Pre-commit hook. See [pre-commit.template.md](templates/pre-commit.template.md).

### `git commit --no-verify` as habit

- **Symptom.** Bypassing pre-commit hooks routinely.
- **Why it bites.** Defeats the whole point.
- **Fix.** If the hook is the wrong shape, fix the hook. Reserve `--no-verify` for genuine emergencies.

### One mega-PR

- **Symptom.** 4000 lines across 80 files in one PR.
- **Why it bites.** Unreviewable; reviewers rubber-stamp.
- **Fix.** Split into logical commits, then logical PRs. Each PR is one thing.

### "Will add tests in a follow-up"

- **Symptom.** PR with the comment "tests TBD."
- **Why it bites.** Follow-up never happens.
- **Fix.** Tests ship with the change. PR template requires confirmation.

---

## Where to file new anti-patterns

When a code-review surfaces a new common mistake:

1. Decide which pattern owns it (or whether it's cross-cutting and lives here).
2. Add it under the right group with the standard tri-fold (symptom / why / fix).
3. Cross-reference back to the originating pattern.
4. If the rule is mechanically detectable, propose a SwiftLint custom rule in [swiftlint.template.md](templates/swiftlint.template.md).

This catalog grows with the codebase. It should be the first thing a new contributor reads after `code-style.md`.
