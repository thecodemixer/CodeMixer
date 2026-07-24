# Pattern selection matrix

Start with a problem. Find the row. Adopt the pattern. The library is curated, not exhaustive — if your problem isn't here, the closest pattern is usually still a useful starting shape.

## How to use this page

1. **Skim the "Problem" column** for the closest match to your situation.
2. **Read the recommended pattern** (the linked doc).
3. **Check "Frequently combines with"** — most production-grade systems compose 3–5 patterns; the library cross-references explicitly.
4. **If nothing fits**, look at "When NOT to use" sections of nearby patterns — they tell you what the boundary is.

---

## By problem

### Concurrency, state, and orchestration

| Problem | Pattern | Frequently combines with |
| --- | --- | --- |
| "One subsystem owns mutable state; many consumers observe it" | [event-sourced-typed-port-core](patterns/event-sourced-typed-port-core.md) | strict-concurrency-layout, multicast-tee-primitive, typed-errors-and-wire |
| "I need to fan one stream out to several consumers, each with its own pace" | [multicast-tee-primitive](patterns/multicast-tee-primitive.md) | event-sourced-typed-port-core |
| "Where should this type live — `actor`, `@MainActor`, or `Sendable`?" | [strict-concurrency-layout](patterns/strict-concurrency-layout.md) | (foundational) |
| "How do I make this UI updates-only when the engine is busy?" | event-sourced-typed-port-core + coherent-activity-heartbeat | dependency-injection-seams |

### Errors and observability

| Problem | Pattern | Frequently combines with |
| --- | --- | --- |
| "My catch sites are unstructured `catch let error`" | [typed-errors-and-wire](patterns/typed-errors-and-wire.md) | (any module gets a typed error enum) |
| "Errors need to cross a network boundary and arrive intact" | [typed-errors-and-wire](patterns/typed-errors-and-wire.md) → §"Codable wire errors" | wire-domain-boundary |
| "`print()` everywhere; I can't grep production logs" | [structured-logging-with-privacy](patterns/structured-logging-with-privacy.md) | (foundational) |
| "How do I show 'still working' to the user during a 30-second gap?" | [coherent-activity-heartbeat](patterns/coherent-activity-heartbeat.md) | event-sourced-typed-port-core |
| "I need to profile what part of a long operation is slow" | structured-logging-with-privacy → §"Signposts" | (use Instruments) |

### IO and processes

| Problem | Pattern | Frequently combines with |
| --- | --- | --- |
| "I need to spawn a subprocess from Swift safely" | [posix-child-lifecycle](patterns/posix-child-lifecycle.md) | typed-errors-and-wire, structured-logging-with-privacy |
| "My subprocess needs a controlling TTY (e.g. Claude interactive billing / Agent Credits avoidance)" | posix-child-lifecycle → §"PTY spawn" | dependency-injection-seams (`AgentEnvironment`) |
| "Children are leaking as zombies on crash" | posix-child-lifecycle → §"Reaper" | (foundational for any spawner) |
| "I have a helper process that needs to push events to the host" | [ipc-server-listener](patterns/ipc-server-listener.md) | typed-errors-and-wire |
| "I need to react to filesystem changes" | [filesystem-watch-with-debounce](patterns/filesystem-watch-with-debounce.md) | (consume into event-sourced-typed-port-core) |
| "I'm getting 200 events for a single editor save" | filesystem-watch-with-debounce → §"Debounce window" | (always) |

### Storage and state

| Problem | Pattern | Frequently combines with |
| --- | --- | --- |
| "Where do I put session / prefs / cache state?" | [atomic-file-persistence](patterns/atomic-file-persistence.md) | dependency-injection-seams (FileSystem) |
| "My persisted format changed; I need migrations" | atomic-file-persistence → §"Schema-versioned files" | typed-errors-and-wire |
| "Power-loss corrupted my prefs file" | atomic-file-persistence → §"Atomic write" | (foundational) |
| "I have secrets to store" | (not covered — use Keychain directly; see lan-pairing-and-auth for token storage) | lan-pairing-and-auth |

### Architecture and adapters

| Problem | Pattern | Frequently combines with |
| --- | --- | --- |
| "I need to support multiple vendors (Claude / Codex / future)" | [plugin-adapter-protocol](patterns/plugin-adapter-protocol.md) | event-sourced-typed-port-core, typed-errors-and-wire |
| "I have a tight coupling to a specific tool I want to abstract" | plugin-adapter-protocol | wire-domain-boundary |
| "How do I keep my unit tests deterministic when there's a real Clock / FS involved?" | [dependency-injection-seams](patterns/dependency-injection-seams.md) | (foundational) |
| "My engine should run in-process today and as a daemon tomorrow" | [headless-remote-duality](patterns/headless-remote-duality.md) | event-sourced-typed-port-core, wire-domain-boundary |
| "Rich Foundation types are leaking through my network boundary" | [wire-domain-boundary](patterns/wire-domain-boundary.md) | typed-errors-and-wire |

### Network and security

| Problem | Pattern | Frequently combines with |
| --- | --- | --- |
| "I need a mobile app to talk to my desktop daemon over Wi-Fi" | [headless-remote-duality](patterns/headless-remote-duality.md) + [lan-pairing-and-auth](patterns/lan-pairing-and-auth.md) | wire-domain-boundary, typed-errors-and-wire |
| "How do clients discover the daemon on the LAN?" | lan-pairing-and-auth → §"Bonjour" | (foundational) |
| "Self-signed TLS — how do I pin it?" | lan-pairing-and-auth → §"Keychain-pinned cert" | (foundational) |
| "Authentication for a local IPC socket" | ipc-server-listener → §"Authentication" | (Unix sockets use file perms) |

---

## By technology stack

### Apple platforms (macOS / iOS / iPadOS / visionOS)

Most patterns assume Apple platforms. Apple-specific touchpoints:

| Pattern | Apple-specific API used |
| --- | --- |
| structured-logging-with-privacy | `os.Logger`, `OSSignposter`, `OSLogStore` |
| atomic-file-persistence | `FileManager`, `Data.write(.atomic)`, application-support directory |
| filesystem-watch-with-debounce | `FSEventStreamCreate` |
| ipc-server-listener | `NWListener` |
| posix-child-lifecycle | `posix_spawn` (cross-platform but tested on macOS), `DispatchIO`, `DispatchSource.signal` |
| headless-remote-duality | `NWListener`, `NWBrowser` (Bonjour), `Network.framework` TLS |
| lan-pairing-and-auth | Keychain, `Network.framework` TLS |

### Cross-platform (Apple + Linux)

The following patterns generalise cleanly:

- event-sourced-typed-port-core (pure Swift concurrency)
- plugin-adapter-protocol (pure Swift protocols)
- typed-errors-and-wire (pure Swift; replace `os.Logger` with `swift-log`)
- wire-domain-boundary (pure Codable)
- multicast-tee-primitive (pure Swift concurrency)
- strict-concurrency-layout (pure Swift)
- dependency-injection-seams (pure Swift protocols)

### Need adaptation for Linux

- structured-logging-with-privacy → use `swift-log` + `LogHandler`; privacy levels are an Apple convention.
- filesystem-watch-with-debounce → use `inotify_init1` instead of `FSEventStreamCreate`.
- ipc-server-listener → use `swift-nio`'s `ServerBootstrap` instead of `NWListener`.
- atomic-file-persistence → conventions differ (`~/.config/{appname}/`); pattern is identical.

---

## By project shape

### "Solo dev, new app, 1-day MVP"

Minimum viable spine:
1. [strict-concurrency-layout](patterns/strict-concurrency-layout.md) — set the rules before writing code.
2. [typed-errors-and-wire](patterns/typed-errors-and-wire.md) — one enum per module.
3. [structured-logging-with-privacy](patterns/structured-logging-with-privacy.md) — `Loggers.swift` from minute one.
4. [event-sourced-typed-port-core](patterns/event-sourced-typed-port-core.md) — if state grows beyond a single `@Observable` class.

Skip everything else until you hit the problem it solves.

### "Native macOS app with subprocesses"

Add:
1. [posix-child-lifecycle](patterns/posix-child-lifecycle.md) — for any spawn beyond `Process`.
2. [dependency-injection-seams](patterns/dependency-injection-seams.md) — `AgentClock` + `AgentEnvironment` + `FileSystem`.
3. [filesystem-watch-with-debounce](patterns/filesystem-watch-with-debounce.md) — if you have a "live" view of disk.
4. [atomic-file-persistence](patterns/atomic-file-persistence.md) — for prefs / sessions.

### "App + daemon + remote client (mobile)"

Add:
1. [wire-domain-boundary](patterns/wire-domain-boundary.md) — before you write the first wire type.
2. [headless-remote-duality](patterns/headless-remote-duality.md) — defines the topology.
3. [lan-pairing-and-auth](patterns/lan-pairing-and-auth.md) — auth from day one, not "we'll add it later."
4. [coherent-activity-heartbeat](patterns/coherent-activity-heartbeat.md) — multi-client UX coherence.
5. [multicast-tee-primitive](patterns/multicast-tee-primitive.md) — for fan-out beyond one consumer.

### "Multi-vendor adapter system"

Add:
1. [plugin-adapter-protocol](patterns/plugin-adapter-protocol.md) — vendor isolation contract.
2. [ipc-server-listener](patterns/ipc-server-listener.md) — if vendors send structured events over a socket.

---

## What's intentionally *not* covered

Some shapes are deliberately out of scope. Knowing what's missing is as important as knowing what's covered:

- **CRDTs / collaborative editing.** Use specialised libraries (Yjs, Automerge).
- **Real-time audio / video pipelines.** AVFoundation / Metal patterns are their own domain.
- **GPU compute / Metal.** Out of scope.
- **SwiftData / Core Data.** These cover their own surface; this library is "below" persistence frameworks.
- **CloudKit / cross-device sync.** Vendor-specific; not portable.
- **Distributed actors (server-side Swift).** Use Apple's distributed actors documentation directly.
- **HTTP REST servers.** Use Vapor / Hummingbird. (The `ipc-server-listener` pattern is for IPC, not REST.)

If a problem in your project falls into any of these, the patterns here will *complement* the specialised library you reach for — they don't replace it.

---

## Combining patterns — the canonical stacks

Three stacks come up over and over. Treat them as starting kits.

### Stack A — "Solid Swift package"

Foundational; every project should pick these up early.

- strict-concurrency-layout
- typed-errors-and-wire
- structured-logging-with-privacy
- dependency-injection-seams

### Stack B — "Native app with subprocess + diff panel"

Stack A plus:

- posix-child-lifecycle
- filesystem-watch-with-debounce
- atomic-file-persistence
- event-sourced-typed-port-core
- multicast-tee-primitive

### Stack C — "Headless daemon + LAN remote client"

Stack B plus:

- wire-domain-boundary
- headless-remote-duality
- lan-pairing-and-auth
- coherent-activity-heartbeat
- ipc-server-listener
- plugin-adapter-protocol (if multi-vendor)

---

## Navigation

- [`README.md`](README.md) — library overview and index.
- [`GLOSSARY.md`](GLOSSARY.md) — terms used across patterns.
- [`ANTI_PATTERNS.md`](ANTI_PATTERNS.md) — what *not* to do, indexed for grep.
- [`patterns/`](patterns/) — the 15 architectural patterns.
- [`templates/`](templates/) — the 14 document and config templates.
