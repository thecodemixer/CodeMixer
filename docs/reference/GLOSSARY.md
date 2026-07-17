# Glossary

Terms used across the reference library. When the same term has both a portable meaning and a Codemixer-specific meaning, both are listed.

Alphabetical. Cross-references are linked. Codemixer-specific entries are tagged **[Codemixer]**.

---

## A

### Actor (Swift)

A reference type whose stored properties are protected from concurrent mutation by serial isolation. Reaching into actor state from outside requires `await`. Foundational to [strict-concurrency-layout](patterns/strict-concurrency-layout.md). See also [Sendable](#sendable), [MainActor](#mainactor).

### Adapter

A module that hides a specific external integration (a CLI, a service, a vendor) behind a shared protocol. Synonymous with "driver" or "plugin." See [plugin-adapter-protocol](patterns/plugin-adapter-protocol.md). **[Codemixer]** the concrete type is `AgentAdapter`.

### `AgentAdapter` **[Codemixer]**

The protocol every supported CLI agent conforms to. Quarantines vendor-specific knowledge (env vars, slash commands, hook events) so the engine doesn't know whether it's talking to Claude, Codex, or Gemini.

### `AgentCommand` **[Codemixer]**

The closed set of operations a client can send to the engine: send prompt, approve permission, stop turn, change session, etc. Single entry point for local UI, voice, and remote API. Defined in [`AgentProtocol`](#agentprotocol-codemixer).

### `AgentEngine` **[Codemixer]**

The actor that orchestrates a single agent session — owns the [PTY](#pty), the [adapter](#adapter), the [event bus](#multicasteventbus-codemixer), and the [permissions](#permission-prompt-codemixer) state. Headless-friendly (`actor`, not `@MainActor`).

### `AgentEvent` **[Codemixer]**

The closed set of structured events the engine emits: assistant text deltas, tool calls, permission prompts, activity heartbeats, errors. Consumed by every client (local UI and remote).

### `AgentProtocol` **[Codemixer]**

The Swift Package target containing wire DTOs ([`AgentCommand`](#agentcommand-codemixer), `AgentEventWire`, `ClientFrame`, `ServerFrame`, and related wire values). It stays portable and UI-free so future non-macOS clients can share the protocol. See [wire-domain-boundary](patterns/wire-domain-boundary.md).

### Atomic write

A write that is guaranteed to leave either the prior content or the new content on disk, never a torn mix. Implemented via temp-and-rename on POSIX filesystems. See [atomic-file-persistence](patterns/atomic-file-persistence.md).

### AsyncStream

Swift's primitive for producer/consumer streaming with a closure-driven continuation. The base type behind every reactive flow in the library — events, commands, IO. See `AsyncStream<Element>`.

---

## B

### Backpressure

Mechanism for slowing a producer when consumers can't keep up. In `AsyncStream`, expressed via `bufferingPolicy` (`.bufferingOldest(N)`, `.bufferingNewest(N)`, `.unbounded`). See [multicast-tee-primitive](patterns/multicast-tee-primitive.md).

### Bearer token

An opaque string presented by clients in subsequent requests to prove identity established via pairing. Stored in Keychain on both sides. See [lan-pairing-and-auth](patterns/lan-pairing-and-auth.md).

### Bonjour / DNS-SD

Zero-config local-network service discovery. Daemons advertise (`_codemixer._tcp.local.`), clients browse. See [lan-pairing-and-auth](patterns/lan-pairing-and-auth.md) §"LAN discovery."

### `bufferingPolicy`

`AsyncStream.Continuation.BufferingPolicy` — controls what happens when a consumer falls behind. The choice between `.bufferingOldest`, `.bufferingNewest`, and `.unbounded` is one of the most important per-stream decisions you make.

---

## C

### Capability **[Codemixer]**

A typed enum value attached to an `AgentAdapter` declaring what the agent supports: `streamingResponses`, `permissionPrompts`, `voiceInput`, etc. UI features key off capabilities, not adapter identity. See [plugin-adapter-protocol](patterns/plugin-adapter-protocol.md).

### CIDR

Classless Inter-Domain Routing notation (e.g. `192.168.1.0/24`). Used to express the local-network range the daemon binds to.

### Closed enum

An `enum` with a fixed, knowable set of cases. The compiler can prove `switch` is exhaustive — the property that makes typed errors and typed commands powerful. See [typed-errors-and-wire](patterns/typed-errors-and-wire.md).

### `Codable`

Swift's serialisation protocol (`Encodable & Decodable`). Required for wire types. See [wire-domain-boundary](patterns/wire-domain-boundary.md).

### `CPosixBridge` **[Codemixer]**

A pure-C SPM target containing low-level POSIX wrappers — `openpty`, `posix_spawn`, `killpg`, `TIOCSWINSZ`, `FD_CLOEXEC` helpers. Swift code is fork-unsafe; the C layer keeps fork/exec out of the Swift runtime. See [posix-child-lifecycle](patterns/posix-child-lifecycle.md).

### Connected remote clients **[Codemixer]**

The number of WebSocket peers currently attached to `RemoteControlServer` (`connectedClientCount`). Surfaced in the GUI as `EngineViewModel.connectedRemoteClients` and the toolbar `ConnectedClientsChip`. In Mode B this count **includes** the loopback Mac GUI; in Mode A with remote access on it counts **external** peers only. Distinct from the [remote client](#remote-client-codemixer) client-role. See [architecture.md §4.1](../architecture.md).

---

## D

### Debounce

Coalescing a burst of events into one delivery after a quiet window. Critical for filesystem watchers and any other "many tiny events that mean one logical change" stream. Window: 50 ms typical for interactive UI. See [filesystem-watch-with-debounce](patterns/filesystem-watch-with-debounce.md).

### Dependency-injection seam

A protocol with both a "live" implementation (production) and a deterministic fake implementation (tests). Common seams: `Clock`, `RandomSource`, `Environment`, `FileSystem`. See [dependency-injection-seams](patterns/dependency-injection-seams.md).

### DispatchIO

A high-throughput async I/O channel over a file descriptor, provided by GCD. Preferred over per-byte read loops for streaming. See [posix-child-lifecycle](patterns/posix-child-lifecycle.md).

### Domain type

An in-memory type using rich Foundation features (`Date`, `URL`, `UUID`, `Duration`) — the type the engine uses internally. Contrast with [wire type](#wire-type). See [wire-domain-boundary](patterns/wire-domain-boundary.md).

---

## E

### Engine

A long-lived actor owning subprocess state and orchestrating commands and events. **[Codemixer]** the concrete type is [`AgentEngine`](#agentengine-codemixer). See [event-sourced-typed-port-core](patterns/event-sourced-typed-port-core.md).

### Envelope

A wrapper structure around a payload, adding metadata like `id`, `version`, `type`, `timestamp`. Used for every wire frame. **[Codemixer]** wire frames are `Envelope<T>` with `v: 1`, `id: UUID`, `body: T`.

### Event sourcing (light)

A design where all state is derived from a stream of events. Consumers "fold" the stream into their own view of state. Not full CQRS/ES — no event store, no rehydration from disk — but the same shape at runtime. See [event-sourced-typed-port-core](patterns/event-sourced-typed-port-core.md).

---

## F

### FSEvents

macOS's filesystem-change notification API (`FSEventStreamCreate`). Coarse-grained but kernel-fast. Linux equivalent: `inotify`. See [filesystem-watch-with-debounce](patterns/filesystem-watch-with-debounce.md).

### Folding (event folding)

The pattern where a consumer maintains its own state by applying each event to a running accumulator. Replay-friendly because folding the same events twice yields the same state. See [event-sourced-typed-port-core](patterns/event-sourced-typed-port-core.md) §"Client-side event folding."

### Fork-safety

The property of a runtime allowing post-`fork()` code to run sanely. Swift, Java, Go, and most modern runtimes are **fork-unsafe** — only `posix_spawn` is safe. See [posix-child-lifecycle](patterns/posix-child-lifecycle.md).

---

## G

### Global concurrent isolation

The default isolation for free functions, top-level code, and structs without explicit isolation. Can run from any actor; must be `Sendable`. See [strict-concurrency-layout](patterns/strict-concurrency-layout.md).

### GlobalActor

A `@globalActor` annotated type providing a custom serialised isolation domain. `@MainActor` is one. Custom global actors are rare; usually plain `actor` suffices.

---

## H

### Headless mode

The application running without a UI, exposing all functionality over a network API. Critical that the engine doesn't carry UI assumptions (no `@MainActor` on the engine). See [headless-remote-duality](patterns/headless-remote-duality.md).

### Heartbeat

A scheduled event emitted to indicate "still working" during long-running operations. State machine ensures consistent multi-client UX. See [coherent-activity-heartbeat](patterns/coherent-activity-heartbeat.md).

### Hook

An out-of-process extension point provided by a host CLI (e.g. Claude Code Hooks) that calls back to the wrapper with structured JSON events. **[Codemixer]** ingested via the [`HookServer`](#hookserver-codemixer) Unix socket. See [ipc-server-listener](patterns/ipc-server-listener.md).

### `HookServer` **[Codemixer]**

The `actor` listening on a Unix-domain socket at `$TMPDIR/codemixer-hook-<pid>.sock`, accepting NDJSON frames from `claude` hook scripts and translating them to `AgentEvent`s. See [ipc-server-listener](patterns/ipc-server-listener.md).

---

## I

### IPC

Inter-Process Communication. In Codemixer: Unix-domain socket for the hook server; loopback TLS WSS for the remote-control API. See [ipc-server-listener](patterns/ipc-server-listener.md), [headless-remote-duality](patterns/headless-remote-duality.md).

### Idempotent

An operation that produces the same effect whether called once or many times. Critical for retried commands and replayed events. **[Codemixer]** replayed events are folded idempotently by clients; command-frame ids let remote clients correlate results, but individual `AgentCommand` cases still define their own retry semantics.

### `inotify`

Linux's filesystem-watch API (`inotify_init1`, `inotify_add_watch`). The Linux counterpart to [FSEvents](#fsevents). See [filesystem-watch-with-debounce](patterns/filesystem-watch-with-debounce.md).

### Intent reveal **[Codemixer]**

The progressive-disclosure SwiftUI modifier — secondary actions hide until cursor or focus enters the parent surface, then fade in. See [visual-style.md §11](../visual-style.md).

---

## J

### JSONL

Newline-delimited JSON. One JSON document per line, terminated by `\n`. Used by both the [Hook server](#hookserver-codemixer) (over Unix socket) and [Claude](#claude-codemixer)'s transcript files. Easy to `grep`, easy to stream.

---

## K

### Keychain

macOS's secure secret store. Used for self-signed TLS certificates and bearer tokens. **[Codemixer]** uses an access group identified by the bundle ID. See [lan-pairing-and-auth](patterns/lan-pairing-and-auth.md).

### `killpg`

`kill(2)` applied to a process group. Used to send signals to a subprocess *and all its descendants*. Essential for clean shutdown of subprocess trees. See [posix-child-lifecycle](patterns/posix-child-lifecycle.md).

---

## L

### LaunchAgent

macOS's per-user background-process manager. The daemon (`codemixerd`) runs as a LaunchAgent so it survives login. See [headless-remote-duality](patterns/headless-remote-duality.md).

### Live / Fake (seam pair)

For every dependency-injection seam, a Live implementation does the real thing (real clock, real filesystem) and a Fake implementation does a deterministic simulation (controllable clock, in-memory filesystem). Tests use Fake; production uses Live. See [dependency-injection-seams](patterns/dependency-injection-seams.md).

### Lockout

Pairing/auth defence: after N consecutive failed PIN attempts, the daemon refuses pairing for a cooldown period. **[Codemixer]** default: 5 attempts, 5-minute lockout. See [lan-pairing-and-auth](patterns/lan-pairing-and-auth.md).

### Logger (`os.Logger`)

Apple's structured logging API. Per-subsystem / per-category buckets, level-based filtering, privacy-aware interpolation, Console.app integration. See [structured-logging-with-privacy](patterns/structured-logging-with-privacy.md).

---

## M

### `MainActor`

Swift's UI-thread global actor. SwiftUI views, view models, and any code touching `AppKit`/`UIKit` runs here. Engines should *not* be `@MainActor`. See [strict-concurrency-layout](patterns/strict-concurrency-layout.md).

### Migration (schema)

A pure function transforming an older-version persisted struct into the next version. Forward-only; never lossy. See [atomic-file-persistence](patterns/atomic-file-persistence.md).

### Mode A / Mode B **[Codemixer]**

The two deployment shapes for the same `AgentEngine`. **Mode A** (default): GUI hosts the engine in-process. **Mode B**: `codemixerd` owns the engine; the GUI connects via loopback WebSocket and is a [remote client](#remote-client-codemixer) in the client-role sense. Opt-in via **Settings → Remote → Enable on login** (LaunchAgent). Full diagrams: [architecture.md §4](../architecture.md).

### Multicast

One event source distributed to N consumers. In Codemixer, replay-aware fan-out is implemented by [`MulticastEventBus`](#multicasteventbus-codemixer).

### `MulticastEventBus` **[Codemixer]**

The replay-aware event bus inside [`AgentEngine`](#agentengine-codemixer). Holds a ring buffer; new subscribers receive the buffered events plus the live stream; overflow yields a synthetic `engineRestarted` event so clients re-snapshot. See [event-sourced-typed-port-core](patterns/event-sourced-typed-port-core.md).

---

## N

### NDJSON

See [JSONL](#jsonl).

### `NWListener` / `NWConnection`

Apple's `Network.framework` types for TCP/UDP/Unix-socket servers and clients. Used for both the Hook server and the remote-control server. See [ipc-server-listener](patterns/ipc-server-listener.md).

---

## O

### `Observable`

Swift macro that turns a class into a SwiftUI-observable reference type without per-property `@Published` annotations. Replaces `ObservableObject` for new code. View-state types use it.

### `openpty(3)`

POSIX function returning a master/slave PTY pair. Wrapped by [`CPosixBridge`](#cposixbridge-codemixer). See [posix-child-lifecycle](patterns/posix-child-lifecycle.md).

---

## P

### Pairing

The first-contact handshake establishing trust between a daemon and a new client. **[Codemixer]** uses a one-shot PIN; the client receives a bearer token in return. See [lan-pairing-and-auth](patterns/lan-pairing-and-auth.md).

### Permission prompt **[Codemixer]**

A request from the agent (relayed via hooks) for user approval before running a sensitive tool. Emitted as `AgentEvent.permissionRequest`; resolved via `AgentCommand.respondToPermission`. Headless mode auto-denies after the engine's permission timeout.

### `posix_spawn`

POSIX function combining `fork` + setup + `exec` into a single atomic syscall. The only safe way for Swift code to spawn subprocesses. See [posix-child-lifecycle](patterns/posix-child-lifecycle.md).

### Privacy (logging)

`os.Logger` annotation on interpolated values: `.private` redacts in release, `.public` always shows. Every interpolation must be tagged. See [structured-logging-with-privacy](patterns/structured-logging-with-privacy.md).

### Process group (`pgid`)

A POSIX kernel concept grouping related processes. `killpg(pgid, signal)` signals all of them at once. Created via `setsid()` (which is enabled by `POSIX_SPAWN_SETSID` in [`CPosixBridge`](#cposixbridge-codemixer)).

### Progressive disclosure

UI design principle: surface only what the user needs now; reveal more on demand. **[Codemixer]** implemented via the [`IntentReveal`](#intent-reveal-codemixer) modifier.

### PTY

Pseudo-terminal. A pair of file descriptors (`master`, `slave`) where the slave is indistinguishable from a real TTY from the spawned process's perspective. Essential for spawning interactive CLIs and preserving "subscriptions are interactive" billing models.

---

## R

### Remote client **[Codemixer]**

A WebSocket peer that drives the engine through the typed wire protocol instead of holding `AgentEngine` in-process. Includes the Mac GUI in Mode B, a future iOS app, and automation scripts. **Not** the same as the [connected remote clients](#connected-remote-clients-codemixer) count — see [architecture.md §4.1](../architecture.md).

### `RemoteEngineClient` **[Codemixer]**

The client-role implementation of `AgentEngineCommandPort` over Codemixer's WebSocket protocol. Used by `Bootstrap.remoteClient` in Mode B and by any external tool that drives a daemon. Stored property name `Bootstrap.remoteClient` refers to this type — not the connected-peer count.

### Reaper

A long-running task that calls `waitpid` to clean up zombie children whenever `SIGCHLD` fires. See [posix-child-lifecycle](patterns/posix-child-lifecycle.md) §"The reaper."

### Ring buffer

A fixed-size circular buffer that overwrites the oldest entry when full. Used by [`MulticastEventBus`](#multicasteventbus-codemixer) for bounded replay history.

---

## S

### Schema version

An integer embedded in every persisted file (`schemaVersion: 2`) that the reader checks before decoding. Forward-only [migrations](#migration-schema) upgrade older files. See [atomic-file-persistence](patterns/atomic-file-persistence.md).

### Seam

See [dependency-injection seam](#dependency-injection-seam).

### `Sendable`

Swift protocol marker indicating a type is safe to share across concurrent contexts. Required for any value crossing actor boundaries. See [strict-concurrency-layout](patterns/strict-concurrency-layout.md).

### Signpost (`OSSignposter`)

Apple's mechanism for marking the start and end of work intervals so Instruments can visualise them in a System Trace timeline. See [structured-logging-with-privacy](patterns/structured-logging-with-privacy.md) §"Signposts."

### Strict concurrency

Swift compiler mode (`-strict-concurrency=complete`) that requires every value crossing isolation domains to be provably `Sendable`. The baseline for Swift 6.2+. See [strict-concurrency-layout](patterns/strict-concurrency-layout.md).

### Subsystem (logging)

In `os.Logger`, the top-level identifier (reverse-DNS bundle id) for all log calls from a process. Distinct from `category`, which scopes within the subsystem.

---

## T

### Typed command port

The single entry point for all operations on an engine, expressed as a sealed enum (`AgentCommand`). See [event-sourced-typed-port-core](patterns/event-sourced-typed-port-core.md).

### Typed error

A module-specific `enum: Error` capturing every distinct failure mode with rich associated values. See [typed-errors-and-wire](patterns/typed-errors-and-wire.md).

### Typed throws (Swift 6.2)

`func foo() throws(MyError)` — narrows the error set so callers can `catch` exhaustively. See [typed-errors-and-wire](patterns/typed-errors-and-wire.md).

---

## U

### `@unchecked Sendable`

Escape hatch declaring "I know this type is concurrent-safe even if the compiler can't prove it." Requires a `// SAFETY:` comment justifying the claim. See [strict-concurrency-layout](patterns/strict-concurrency-layout.md).

### Unix-domain socket

A POSIX socket bound to a filesystem path, restricted to same-machine processes. Default IPC transport in Codemixer. See [ipc-server-listener](patterns/ipc-server-listener.md).

---

## W

### `waitpid`

POSIX function to reap a child process's exit status. Without it, exited children become zombies. See [posix-child-lifecycle](patterns/posix-child-lifecycle.md).

### Wire type

A `Codable` type that crosses a network boundary. Uses portable primitives (strings, ints, ISO-8601 dates) only. Contrast with [domain type](#domain-type). See [wire-domain-boundary](patterns/wire-domain-boundary.md).

### `WireCodec`

The single converter between domain types and wire types. Centralising conversion in one type makes parity tests trivial. See [wire-domain-boundary](patterns/wire-domain-boundary.md).

### `WireError`

The single envelope for any error crossing the network. `(domain, code, message, details)`. See [typed-errors-and-wire](patterns/typed-errors-and-wire.md) §"The error envelope."

### WSS

WebSocket Secure — WebSocket over TLS. The transport for Codemixer's remote-control API. See [headless-remote-duality](patterns/headless-remote-duality.md).

---

## Z

### Zombie process

A POSIX process that has exited but whose parent hasn't called `waitpid` to reap it. Holds a slot in the process table indefinitely. See [posix-child-lifecycle](patterns/posix-child-lifecycle.md) §"The reaper."

---

## Cross-reference

| Term family | Primary pattern |
| --- | --- |
| actor / Sendable / MainActor / @unchecked | [strict-concurrency-layout](patterns/strict-concurrency-layout.md) |
| typed error / typed throws / WireError | [typed-errors-and-wire](patterns/typed-errors-and-wire.md) |
| Logger / signpost / privacy / fatal | [structured-logging-with-privacy](patterns/structured-logging-with-privacy.md) |
| atomic write / schema version / migration | [atomic-file-persistence](patterns/atomic-file-persistence.md) |
| posix_spawn / killpg / waitpid / PTY | [posix-child-lifecycle](patterns/posix-child-lifecycle.md) |
| FSEvents / inotify / debounce | [filesystem-watch-with-debounce](patterns/filesystem-watch-with-debounce.md) |
| NWListener / Unix socket / NDJSON | [ipc-server-listener](patterns/ipc-server-listener.md) |
| domain vs wire / Codable / WireCodec | [wire-domain-boundary](patterns/wire-domain-boundary.md) |
| engine / event / command port / fold | [event-sourced-typed-port-core](patterns/event-sourced-typed-port-core.md) |
| multicast / backpressure | [event-sourced-typed-port-core](patterns/event-sourced-typed-port-core.md) |
| adapter / capability / plugin | [plugin-adapter-protocol](patterns/plugin-adapter-protocol.md) |
| Clock / RandomSource / Environment / FileSystem | [dependency-injection-seams](patterns/dependency-injection-seams.md) |
| headless / daemon / LaunchAgent / WSS | [headless-remote-duality](patterns/headless-remote-duality.md) |
| pairing / bearer token / Keychain / Bonjour | [lan-pairing-and-auth](patterns/lan-pairing-and-auth.md) |
| heartbeat / activity / still-working | [coherent-activity-heartbeat](patterns/coherent-activity-heartbeat.md) |
