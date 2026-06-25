# Pattern: Event-sourced typed-port core

**Scope.** A single actor — the "engine" — owns the system's running state. It accepts a typed `Command` input alphabet through one port and emits a typed `Event` output alphabet through a multicast bus. Every consumer (local UI, remote clients, voice TTS, scripts) derives state from the same event fold. There is no second source of truth.

**When to use.** Anywhere you have one stateful piece of logic that multiple consumers must observe consistently — desktop app + mobile remote, multi-window UI, scriptable headless modes, or any "what's happening now" UI that needs to survive reconnects.

**When not to use.** Pure request/response services (use REST/RPC). Single-consumer in-process flows (use a callback). Stateless transforms (use functions).

---

## The four pieces

```
        ┌───────────────────────────────────────────────────────────┐
        │                       Engine (actor)                      │
        │                                                           │
        │   ┌────────────────────────┐    ┌──────────────────────┐  │
        │   │  CommandPort           │    │  Subsystems          │  │
        │   │  send(Command)         │──▶ │  (PTY, IO, network…) │  │
        │   └────────────────────────┘    └──────────┬───────────┘  │
        │                                            │              │
        │                                            ▼              │
        │                                ┌──────────────────────┐   │
        │                                │  ingest(Event)        │   │
        │                                └──────────┬───────────┘   │
        │                                           ▼               │
        │                              ┌─────────────────────────┐  │
        │                              │  MulticastEventBus      │  │
        │                              │  (actor)                │  │
        │                              └──────┬──────────────────┘  │
        └─────────────────────────────────────┼─────────────────────┘
                                              │
                  ┌───────────────────────────┼───────────────────────────┐
                  ▼                           ▼                           ▼
            ┌──────────┐                ┌──────────┐                ┌──────────┐
            │ Consumer │                │ Consumer │                │ Consumer │
            │   GUI    │                │  Mobile  │                │  Script  │
            └──────────┘                └──────────┘                └──────────┘
```

1. **`Command`** — the typed input alphabet. A `Codable, Sendable` enum.
2. **`Event`** — the typed output alphabet. Two flavours: a domain type with rich Foundation references, and a `Codable, Sendable` wire DTO mirror. See [wire-domain-boundary](wire-domain-boundary.md).
3. **`Engine`** — a plain `actor`. Owns subsystems, sequences operations, ingests events, publishes them.
4. **`MulticastEventBus`** — an `actor` that fans events to N subscribers, each with bounded back-pressure and a per-consumer drop-oldest policy. A small ring buffer (≤ ~1k events) supports reconnect-with-replay.

---

## `Command` — the input alphabet

```swift
public enum Command: Codable, Sendable {
    case beginTask(input: String)
    case cancelCurrentTask
    case editAndResubmit(targetID: UUID, input: String)
    case respondToPermission(id: UUID, decision: PermissionDecision)
    case selectMode(Mode)
    case updatePref(key: PrefKey, value: PrefValue)
}
```

**Three categories** of command — group them mentally even if you don't reflect them in the type:

| Category | Examples | Engine response |
| --- | --- | --- |
| Subsystem input | `beginTask`, `cancelCurrentTask` | Translated to bytes, syscalls, RPCs. |
| Engine state | `selectMode` | Mutates engine fields; emits a corresponding state event. |
| Out-of-band | `updatePref`, `requestSnapshot` | Routed to a service alongside the engine; engine acks. |

The discipline: **every state change in the system corresponds to one inbound `Command`.** No "GUI fast path." No "but this is internal." If the engine reaches into itself for a button-click action that the network can't reproduce, you've lost the parity property and your multi-client coherence breaks silently.

---

## `Event` — the output alphabet

```swift
public enum Event: Sendable {
    case taskStarted(id: UUID, input: String)
    case taskOutput(taskID: UUID, delta: String)
    case taskEnded(id: UUID, success: Bool, summary: String)
    case progress(taskID: UUID, fraction: Double)
    case permissionRequest(prompt: PermissionPrompt)
    case permissionStale(id: UUID, reason: String)
    case statusChanged(StatusPhrase)
    case noEventGap(taskID: UUID, elapsed: Duration)
    case error(EngineError)
    case stopped(reason: StopReason)
}
```

Two flavours co-exist:

- **`Event`** — domain type, lives next to the engine. Uses Foundation types (`URL`, `Date`, `Duration`).
- **`EventWire`** — `Codable` DTO, lives in a pure-Foundation portable module. Uses string-encoded URLs, ISO-8601 dates, integer-millisecond durations.

A single `WireCodec` converts between them at the network boundary. See [wire-domain-boundary](wire-domain-boundary.md). The engine only emits domain `Event`; the network server only emits `EventWire`. The seam is one file.

**Categorical sanity.** Group cases mentally into 4–6 categories — *lifecycle, work, progress, permissions, activity, ambient* — so new events have an obvious place. If a new event sits between two categories awkwardly, it's a smell: usually the event is doing two jobs.

---

## `Engine` — the orchestrator actor

```swift
public actor Engine: CommandPort {

    public enum State: Sendable, Equatable {
        case stopped, starting, running(id: UUID?), stopping
    }

    public let bus: MulticastEventBus
    private let seams: Seams         // see dependency-injection-seams.md
    private var state: State = .stopped
    private var subsystems: SubsystemSet?
    private var pendingPermissions: [UUID: PermissionPrompt] = [:]
    private var lastInputID: UUID?

    public init(seams: Seams = .live) {
        self.seams = seams
        self.bus = MulticastEventBus()
    }

    public func start(...) async throws { /* boot subsystems, wire event stream */ }
    public func shutdown(reason: StopReason = .userCancel) async { /* idempotent */ }

    public func send(_ command: Command) async throws {
        switch command {
        case .beginTask(let input):
            let id = seams.random.uuid()
            lastInputID = id
            try await subsystems?.runner.dispatch(input)
            await bus.publish(.taskStarted(id: id, input: input))
        case .cancelCurrentTask:
            try await subsystems?.runner.cancel()
        // …other cases…
        }
    }

    private func ingest(_ event: Event) async {
        // bookkeeping side-effects only — never re-publish a different event
        switch event {
        case .permissionRequest(let p): pendingPermissions[p.id] = p
        case .stopped: Task { await self.shutdown(reason: .naturalExit) }
        default: break
        }
        await bus.publish(event)
    }
}
```

**Invariants:**

1. **`actor`, not `@MainActor`.** The engine must run identically inside a daemon binary with no UI. If it inherits `@MainActor` you've lost the headless property and inherited a layer-violation. See [strict-concurrency-layout](strict-concurrency-layout.md).
2. **`send` is the only inbound method.** No public mutators outside the port. UI bindings construct a `Command`; tests construct a `Command`; the network server constructs a `Command`. Same path.
3. **`ingest` is the only event-side branch site.** All event-driven bookkeeping happens here. No subsystem mutates engine state directly; it emits events and lets the engine react.
4. **`shutdown` is idempotent.** Called from multiple places (user quit, child exit, error). Calling twice is a no-op.
5. **`Sendable` everywhere.** `Command`, `Event`, `State`, `PermissionPrompt`, every payload type is `Sendable`. If a Foundation type isn't (`UIImage`, `NSImage`), wrap it in a value-type adapter.

---

## `MulticastEventBus` — fan-out + replay

```swift
public actor MulticastEventBus {

    public struct Subscription: Sendable {
        public let id: UUID
        public let stream: AsyncStream<Event>
    }

    private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var ring: Deque<(id: UUID, event: Event)> = []
    private let ringCapacity = 500

    public func subscribe() -> Subscription {
        let id = UUID()
        var continuation: AsyncStream<Event>.Continuation!
        let stream = AsyncStream<Event>(bufferingPolicy: .bufferingOldest(1024)) { c in
            continuation = c
        }
        subscribers[id] = continuation
        return Subscription(id: id, stream: stream)
    }

    public func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.finish()
    }

    public func publish(_ event: Event) {
        let id = UUID()
        ring.append((id, event))
        if ring.count > ringCapacity { ring.removeFirst() }
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    public func replay(since lastSeenEventID: UUID?) -> [Event] {
        guard let last = lastSeenEventID else { return ring.map(\.event) }
        guard let idx = ring.firstIndex(where: { $0.id == last }) else { return [] }
        return ring[(idx + 1)...].map(\.event)
    }
}
```

**Bus properties to preserve:**

- **Per-subscriber bounded queue.** Each `AsyncStream` is `.bufferingOldest(N)` — overflow drops the oldest events for *that subscriber only*. A slow consumer can't backpressure others.
- **Drop-oldest tagged.** When the queue overflows, emit a synthetic `eventDropped(count:)` so the consumer knows to resubscribe with a snapshot request.
- **Ring buffer keyed by UUID.** `replay(since:)` returns events strictly after the last-seen UUID, so reconnecting clients don't miss anything and don't double-apply (because their state is a fold, see below).
- **No reordering.** Events are delivered in publish order to each subscriber.
- **No batching by default.** Latency over throughput. Optionally aggregate when Reduce-Motion / low-power is on, but keep it explicit.

---

## Consumers fold the stream

Every consumer derives its state by folding `Event`s through a pure reducer. There is no shared mutable structure between consumers, no "ground truth" they query.

```swift
public struct ConversationState: Sendable, Equatable {
    public var bubbles: [Bubble] = []
    public var pendingPermissions: [PermissionPrompt] = []
    public var status: StatusPhrase = .idle
}

public func reduce(_ state: ConversationState, _ event: Event) -> ConversationState {
    var s = state
    switch event {
    case .taskStarted(let id, let input):
        s.bubbles.append(.user(id: id, text: input))
    case .taskOutput(let id, let delta):
        s.bubbles.appendOrUpdateAssistantDelta(taskID: id, delta: delta)
    case .permissionRequest(let p):
        s.pendingPermissions.append(p)
    // …
    }
    return s
}
```

**The fold is idempotent at the consumer.** On reconnect-with-replay, the same events arrive again; the consumer applies them again; the result is unchanged because reducers are functions. This is the property that makes replay safe.

UI bindings observe `state` (e.g. via `@Observable` view models on the `@MainActor`); they never observe the bus directly.

---

## Reconnect-with-replay

```swift
public struct SubscribeFrame: Codable, Sendable {
    public let lastSeenEventID: UUID?
}

// Server-side handler:
func handle(frame: SubscribeFrame, client: ClientConnection) async {
    let missed = await bus.replay(since: frame.lastSeenEventID)
    for event in missed {
        await client.send(WireCodec.encode(event))
    }
    let sub = await bus.subscribe()
    Task {
        for await event in sub.stream {
            await client.send(WireCodec.encode(event))
        }
    }
}
```

When a client drops and reconnects within the ring window, it gets exactly the missed events. Outside the window, the server sends a synthetic `engineRestarted` event so the client knows to ask for a full snapshot.

---

## Commands & permissions: first-responder wins

Multiple connected clients may see the same prompt. The discipline:

- Engine tracks a `pendingPermissions: [UUID: PermissionPrompt]`.
- First valid `respondToPermission(id:, decision:)` wins; the map entry is removed.
- Later responses for the same prompt id are no-ops because the pending entry is gone.
- If the implementation has timeout or stale-card cleanup events, publish those explicitly; do not assume every successful response needs a second "resolved by device" event.

This pattern generalises beyond permissions: any "the system must do exactly one thing in response to many possible inputs" can use the same map-and-first-wins pattern.

---

## Common pitfalls

| Pitfall | Symptom | Fix |
| --- | --- | --- |
| Adding a "UI-only" shortcut around the command port | Mobile remote doesn't see a state change, but local UI does | Always route through `send(_:)`. There is no fast path. |
| Letting subsystems mutate engine state directly | Race conditions, "phantom" events | Subsystems emit events; engine reacts in `ingest`. |
| Single per-consumer queue, no backpressure | One slow client stalls everyone | Per-subscriber bounded queue with drop-oldest. |
| Replaying without UUIDs | Duplicate events on reconnect | UUID-keyed ring buffer; consumers fold idempotently. |
| `@MainActor` on the engine | Daemon mode dies on launch (no main thread to schedule on) | Plain `actor`. UI seam stays in the UI module. |
| Domain types in the wire | Can't compile on iOS / Linux | Separate `Codable` DTOs, one converter, parity test. |
| Event grammar grows without categories | Hard to find a place for new events | Group cases mentally; refactor when a new event resists placement. |

---

## Codemixer instance

- `Command` ↔ `AgentCommand` (in `AgentProtocol`)
- `Event` ↔ `AgentEvent` (domain, in `AgentCore`) / `AgentEventWire` (DTO, in `AgentProtocol`)
- `Engine` ↔ `AgentEngine` (in `Core/AgentCore/Engine/AgentEngine.swift`)
- `MulticastEventBus` ↔ `MulticastEventBus` (in `Core/AgentCore/Bus/`)
- `CommandPort` ↔ `AgentEngineCommandPort`

See [docs/architecture.md §§8, 12, 13, 14](../../architecture.md) for the Codemixer-specific narrative; this file is the portable version.

---

## Minimum viable adoption

If you want this pattern in a new project, ship in this order:

1. `Command` enum + `CommandPort` protocol.
2. `Event` enum (domain only — defer the wire DTO until you actually need it).
3. `Engine` actor with `send(_:)` and a private `ingest(_:)`.
4. `MulticastEventBus` actor with `publish` / `subscribe` (defer replay until you need reconnects).
5. One consumer that folds events into a `State` struct.
6. One test that drives a scripted `Command` sequence and asserts the resulting `State`.

You can add wire DTOs, ring buffer, multiclient coherence later — each layers cleanly on top.
