# Pattern: Multicast tee primitive

**Scope.** A small building block that takes one `AsyncStream` and splits it into N independent streams, each with its own back-pressure and cancellation, without coupling the consumers. The primitive used under `MulticastEventBus`, debug taps, transcript mirroring, and any "one source, many sinks" wiring.

**When to use.** Any time more than one consumer needs to observe a stream:

- A subprocess's stdout is consumed by both a structured parser and a debug terminal sheet.
- An event stream is consumed by the local UI and the remote-control server.
- An audio stream is split between display and recording.

**When not to use.** Single-consumer streams (just use the original). Streams where consumers need to *transform and merge back* (use `combineLatest` / `merge`).

---

## The simplest tee

```swift
public actor Tee<Element: Sendable> {

    public typealias Stream = AsyncStream<Element>

    private var continuations: [UUID: Stream.Continuation] = [:]

    public init() {}

    /// Returns a fresh subscriber stream. The caller owns its lifetime;
    /// finishing the stream (e.g. by going out of scope) auto-unsubscribes.
    public func subscribe(bufferingPolicy: Stream.Continuation.BufferingPolicy = .bufferingOldest(256)) -> Stream {
        let id = UUID()
        return AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            self.continuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.unsubscribe(id) }
            }
        }
    }

    /// Forwards an upstream element to every subscriber.
    public func send(_ element: Element) {
        for c in continuations.values { c.yield(element) }
    }

    /// Finishes every subscriber stream and drops state. Idempotent.
    public func finish() {
        for c in continuations.values { c.finish() }
        continuations.removeAll()
    }

    private func unsubscribe(_ id: UUID) {
        continuations.removeValue(forKey: id)?.finish()
    }
}
```

**Properties:**

- One actor → serial mutation of the subscriber map; no locks.
- Per-subscriber back-pressure via `bufferingPolicy`. The default `.bufferingOldest(256)` drops the oldest element when a subscriber falls behind, signalling implicitly through the gap.
- Auto-unsubscribe on stream termination — callers don't have to remember to call `unsubscribe`.
- `send` is O(N) in subscribers; for N ≤ 64 this is below 1 µs.

---

## Wiring an upstream `AsyncStream` into the tee

```swift
public extension Tee {
    /// Drains `upstream` and forwards each element. Cancels when the upstream finishes.
    func attach(upstream: AsyncStream<Element>) -> Task<Void, Never> {
        Task { [weak self] in
            for await element in upstream {
                guard let self else { return }
                await self.send(element)
            }
            await self?.finish()
        }
    }
}
```

A common shape: a producer creates a `Tee`, attaches an upstream, hands out `subscribe()` streams to N consumers.

```swift
let pty = try PTYHost(spec: spec)
let tee = Tee<Data>()
let drain = await tee.attach(upstream: pty.outboundBytes)

let parserStream = await tee.subscribe()
let debugStream  = await tee.subscribe(bufferingPolicy: .unbounded)

Task {
    for await chunk in parserStream { await parser.feed(chunk) }
}
Task {
    for await chunk in debugStream { await debugView.append(chunk) }
}

// Later, on shutdown:
drain.cancel()
await tee.finish()
```

---

## Per-subscriber backpressure

The tee's defining property is that **each subscriber's queue is independent**. A slow consumer can't stall a fast one.

| Policy | Behaviour |
| --- | --- |
| `.bufferingOldest(N)` | When the subscriber's queue is full, drop the oldest pending element. The newest data survives. |
| `.bufferingNewest(N)` | When the queue is full, drop the newest. The oldest data survives. |
| `.unbounded` | Never drop. If a subscriber falls hopelessly behind, memory grows. Use with caution; appropriate for debug taps that the user explicitly enabled. |

**Pick by use case:**

- **UI bindings, status pills, activity indicators** → `.bufferingOldest(N)` — the latest state matters more than history.
- **Persistent loggers, transcript mirrors** → `.unbounded` *only if* the consumer is guaranteed to keep up; otherwise `.bufferingOldest` and rely on the canonical source.
- **Replay tools** → `.bufferingOldest(N)` with an explicit "I missed events" signal.

---

## Drop-oldest with overflow signal

The vanilla tee silently drops on overflow. For replay-aware consumers (see [event-sourced-typed-port-core](event-sourced-typed-port-core.md)), surface the drop:

```swift
public actor SignalingTee<Element: Sendable> {

    public enum Yield: Sendable {
        case element(Element)
        case dropped(count: Int)
    }

    private var subscribers: [UUID: SubscriberState] = [:]
    private struct SubscriberState {
        let continuation: AsyncStream<Yield>.Continuation
        var droppedSinceLastEmit: Int = 0
    }

    public init() {}

    public func subscribe(window: Int = 256) -> AsyncStream<Yield> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingOldest(window)) { continuation in
            self.subscribers[id] = SubscriberState(continuation: continuation)
            continuation.onTermination = { @Sendable _ in
                Task { await self.unsubscribe(id) }
            }
        }
    }

    public func send(_ element: Element) {
        for (id, var state) in subscribers {
            // Conservative: if we suspect a backlog, prepend a drop signal.
            if state.droppedSinceLastEmit > 0 {
                state.continuation.yield(.dropped(count: state.droppedSinceLastEmit))
                state.droppedSinceLastEmit = 0
                subscribers[id] = state
            }
            switch state.continuation.yield(.element(element)) {
            case .enqueued:
                break
            case .dropped:
                state.droppedSinceLastEmit += 1
                subscribers[id] = state
            case .terminated:
                subscribers.removeValue(forKey: id)
            @unknown default:
                break
            }
        }
    }

    public func finish() {
        for s in subscribers.values { s.continuation.finish() }
        subscribers.removeAll()
    }

    private func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.continuation.finish()
    }
}
```

The consumer pattern-matches on `Yield`:

```swift
for await yield in tee.subscribe() {
    switch yield {
    case .element(let value): handle(value)
    case .dropped(let n):     log.warning("dropped \(n) elements; requesting snapshot")
                              await requestSnapshot()
    }
}
```

`AsyncStream.Continuation.yield(_:)` returns `.dropped` only when the buffering policy actually dropped; the tee uses that as a precise signal.

---

## Cancellation semantics

- **Unsubscribe by canceling the consumer's stream** (let it go out of scope, `break` out of the for-await loop, or task cancellation). `onTermination` fires; the actor removes the entry.
- **Upstream finish** propagates to all subscribers via `tee.finish()`. Consumers see their stream end.
- **Producer cancellation** (canceling the drain task) does **not** auto-finish the tee — call `tee.finish()` explicitly. This lets you pause an upstream without closing subscriber streams.

---

## When to use which tee shape

| Use case | Shape |
| --- | --- |
| One consumer | No tee — just use the original stream. |
| Two-three stable consumers, no overflow concern | Vanilla `Tee` with `.bufferingOldest(256)`. |
| Many consumers, replay-aware | `SignalingTee` + ring buffer (see `MulticastEventBus`). |
| Consumers come and go dynamically | `Tee` with auto-unsubscribe via `onTermination`. |
| Consumer must transform and merge with another stream | Don't use a tee; use `AsyncAlgorithms.merge` / `zip`. |

---

## Multicast vs `MulticastEventBus`

`MulticastEventBus` (see [event-sourced-typed-port-core](event-sourced-typed-port-core.md)) is a `Tee` plus:

- A ring buffer for reconnect-with-replay.
- UUID-keyed event identity.
- Synthetic `engineRestarted` when the ring overflows.

The plain `Tee` is the right primitive when you don't need replay (e.g. raw byte streams between subprocesses and parsers).

---

## Anti-patterns

| Anti-pattern | Why it's bad | Fix |
| --- | --- | --- |
| Single shared queue for all subscribers | One slow consumer stalls everyone | Per-subscriber `AsyncStream.Continuation`. |
| `.unbounded` buffering by default | OOM under load | `.bufferingOldest(N)` default; opt into `.unbounded`. |
| Forgetting `onTermination` | Subscribers leak after consumer death | Always register the termination handler. |
| Synchronous tee with locks | Re-entrancy bugs | Actor-based tee; no locks needed. |
| Drop signal as a side-channel boolean | Hard to coordinate with the stream order | Inline `Yield` enum keeps the signal in-band. |
| Multiple drains for the same upstream | Race conditions; duplicate forwarding | One `attach` per upstream. |

---

## Codemixer instance

- `AgentEngine.start()` uses a local inline fan-out for PTY bytes to both `TerminalEngine` and the adapter's event stream.
- `MulticastEventBus` is the replay-aware multicast: `HistoryEntry`-tagged events, `subscribe(after:)`, `subscribeWithOutcome`, and self-cleaning `onTermination` unsubscribe.
- FSEvents-driven diff refresh lives in `AgentEngine` (not in the adapter's `makeEventStream`).

See [docs/architecture.md §§9, 14](../../architecture.md) for the Codemixer narrative.

---

## Minimum viable adoption

1. Drop the `Tee<Element>` actor above into your shared utility module.
2. Replace any "single stream, two consumers" wiring with a tee.
3. Choose `bufferingPolicy` per subscriber based on use case.
4. If overflow matters, upgrade to `SignalingTee` so consumers can request snapshots.
5. Verify the auto-unsubscribe behaviour: drop a subscriber, send 10 more events, ensure the tee no longer references the dropped subscriber.

The result: a small primitive that turns "one source, many sinks" from a recurring boilerplate into a one-line wiring.
