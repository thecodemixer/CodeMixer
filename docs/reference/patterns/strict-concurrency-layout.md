# Pattern: Strict-concurrency layout

**Scope.** A repeatable mental model for laying out a Swift 6.2 codebase with `StrictConcurrency = complete`: which types are `actor`, which are `@MainActor`, where `Sendable` boundaries live, where `@unchecked Sendable` is acceptable, and how cross-isolation calls are made.

**When to use.** Every new Swift 6.2 module. The rules are domain-agnostic; they apply equally to chat apps, IDE plug-ins, network services, and game tooling.

**When not to use.** Code under Swift 5 minimum-concurrency mode. (Migrate first, then read this.)

---

## Four isolation domains

Every type in the codebase lives in exactly one of these:

| Domain | Examples | Notes |
| --- | --- | --- |
| **Plain `actor`** | Engines, buses, IO orchestrators, caches, parsers that own mutable state. | Default for non-UI stateful types. Run on Swift's cooperative pool. |
| **`@MainActor`** | SwiftUI / UIKit / AppKit views, view models, anything that touches a `View`. | Forbidden outside the UI module. |
| **Global concurrent (cooperative)** | `Task { ... }` for short, one-shot async work. Helper functions that take inputs and return outputs without mutating shared state. | No long-lived loops; loops belong in actors. |
| **`@unchecked Sendable` bridges** | Adapters around callback-based APIs (FSEvents, DispatchIO, third-party `@unchecked Sendable` types). | Quarantined to specific files; reviewed line-by-line; documented invariants. |

**The discipline:** every type's domain is explicit. There is no "default" — if you cannot articulate which domain a new type belongs to, you do not understand the type yet.

---

## The MainActor seam

```
                  ┌───────────────────────┐
                  │  SwiftUI View         │  @MainActor (by inheritance)
                  └───────────┬───────────┘
                              │
                              ▼
                  ┌───────────────────────┐
                  │  ViewModel             │  @MainActor
                  │  @Observable           │
                  └───────────┬───────────┘
                              │
            await           ──┴──            for await
            ──────────────  S e a m  ──────────────
                              │
                              ▼
                  ┌───────────────────────┐
                  │  Engine                │  plain actor
                  │                        │
                  └───────────┬───────────┘
                              │
                              ▼
                  ┌───────────────────────┐
                  │  Subsystems            │  plain actors
                  │  (PTY, network, IO)    │
                  └───────────────────────┘
```

**`@MainActor` lives only in the UI module.** Every other module is forbidden from using it. This is checked by a grep at PR time:

```bash
grep -RE "@MainActor" src/ | grep -v "src/AgentUI/"   # must be empty
```

**Cross-seam calls are explicit:**

- **UI → Engine**: `await engine.send(command)` — the view model awaits the actor method.
- **Engine → UI**: never directly. The engine publishes to a `MulticastEventBus`; the view model subscribes via `for await event in stream`; the view model applies updates on its own main-actor isolation.

The seam is the only `await` between domains. No async closures captured across actors; no class instances shared across actors; no global mutable state.

---

## Why a plain `actor`, not `@MainActor`, for the engine

If the engine were `@MainActor`-isolated:

- It cannot run in a headless daemon (no main thread to schedule on by convention).
- Long-running subsystem work blocks the main thread.
- Tests are forced through `await MainActor.run { ... }` for every assertion.

A plain `actor`:

- Runs equally well in any process.
- Off-loads work to the cooperative pool.
- Tests just `await engine.send(...)`.

The UI module pays the cost (one `for await` loop and `Task { @MainActor in ... }` for the few hot bindings) so every other module stays portable.

---

## `Sendable` discipline

Every public type that crosses an isolation boundary is `Sendable`. If a type isn't, wrap it.

```swift
public struct EventEnvelope: Sendable {
    public let id: UUID                  // Sendable
    public let publishedAt: Date         // Sendable
    public let payload: Event            // must be Sendable
}

public enum Event: Sendable {
    case taskStarted(id: UUID, input: String)
    case taskOutput(id: UUID, delta: String)
    // …
}
```

**Practical checklist when adding a public type:**

- [ ] Declared `Sendable`?
- [ ] All stored properties are themselves `Sendable`?
- [ ] No reference types unless they're themselves `Sendable` (rare — usually you wrap them).
- [ ] No closures unless `@Sendable`.
- [ ] No `Any` unless boxed in a `Sendable` wrapper that documents the constraint.

When the compiler insists a type isn't `Sendable`, listen. The fix is almost always to make it a `struct` (value type, auto-`Sendable` once all properties are).

---

## When `@unchecked Sendable` is acceptable

Three cases, each quarantined to a single file with documentation:

1. **C-callback bridges.** FSEvents fires on a CF runloop callback; `DispatchIO` reads fire on a dispatch queue; both require capturing a Swift closure. Wrap the bridge in an `@unchecked Sendable` class with internal locking.

2. **`@preconcurrency import` of a third-party type** that isn't (yet) `Sendable`. Wrap it in an actor (preferred) or in an `@unchecked Sendable` adapter (acceptable) that exposes only safe operations.

3. **Final test fakes** that protect their internals with a lock. The unchecked annotation is appropriate because the *user* of the fake (the test code) sees a `Sendable` API.

In all three, the file leads with:

```swift
// MARK: - @unchecked Sendable bridge
//
// Invariants:
//  1. All mutable state guarded by `lock`.
//  2. Callbacks fire on a single serial dispatch queue.
//  3. `cancel()` is idempotent and safe from any thread.
//
// Reviewed: <date>, <reviewer>.
```

`@unchecked Sendable` in unannotated, undocumented places is a hard PR reject.

---

## Re-entrancy: the actor's main hazard

Inside an actor, every `await` is a re-entrancy point. Another method on the same actor can run while you're awaiting. Two rules:

1. **Snapshot mutable state before `await`.** Don't read `self.foo` after an await without re-reading it.

```swift
// BAD
func handle(_ event: Event) async {
    let count = events.count
    await persist(event)               // re-entrant
    print("there were \(count) events") // stale!
}

// GOOD
func handle(_ event: Event) async {
    await persist(event)
    let count = events.count            // freshly read after await
    print("there are now \(count) events")
}
```

2. **Don't hold an invariant across an `await`.** If `state == .running` matters, recheck it after the await. The actor's contract is that *between* awaits the state is consistent; *across* an await, it isn't.

---

## Structured concurrency for child work

Inside an actor, prefer structured concurrency:

```swift
public func runTask() async throws {
    async let result = subsystemA.process()
    async let log = subsystemB.archive()
    let (r, _) = try await (result, log)
    apply(r)
}
```

Over unstructured:

```swift
public func runTask() async throws {
    Task { await subsystemA.process() }   // detached, no cancellation propagation
    // …
}
```

**Detached `Task`s are used only at the outermost boundaries** — the very top of the bus subscriber loop, the SIGCHLD reaper, the network listener. Inside an actor's methods, prefer `async let` and `withTaskGroup`.

Cancellation propagates through structured tasks automatically. Detached tasks must be tracked in a `Set<Task<…>>` so they can be cancelled on shutdown.

---

## Layout cheat-sheet

For a typical N-module project, the type-domain assignment is mechanical:

| Module | Common types |
| --- | --- |
| `Protocol` (portable wire) | `Codable, Sendable` enums and structs only. No isolation. |
| `Core` (engine) | Plain actors. `Sendable` value types for inputs / outputs. |
| `Adapter` (vendor plug-in) | One actor (or extension on a stateless struct conforming to the protocol). |
| `RemoteControl` | Plain actors for network endpoints. `Sendable` frame types. |
| `UI` | `@MainActor` views, view models, and the UI-side coordinator. |
| `TestSupport` | `Sendable` fakes (often `@unchecked Sendable` with internal locking). |
| Executables (`App`, `Daemon`) | `@main` only. No domain-bearing types. |

If you find yourself wanting `@MainActor` outside `UI`, stop and reconsider. The bridge belongs in the UI module.

---

## Strict-concurrency build settings

`Package.swift`:

```swift
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]
```

CI flags:

```bash
swift build -Xswiftc -warnings-as-errors
swift test  -Xswiftc -warnings-as-errors
```

A warning means the build fails. Strict concurrency without `-warnings-as-errors` is a sticky-note on the fridge.

---

## Anti-patterns

| Anti-pattern | Symptom | Fix |
| --- | --- | --- |
| `@MainActor` on a non-UI module | Daemon target fails to launch | Move the type to plain `actor`. |
| Reaching into actor internals via `nonisolated(unsafe)` | Race conditions | Add a real method to the actor. |
| `class` for state when `actor` would do | `@unchecked Sendable` proliferates | Make it an actor. |
| Capturing `self` in a `Task` inside an actor method without `[weak self]` | Memory leak | `Task { [weak self] in ... }`. |
| Awaiting a global function inside a long actor critical section | Other actor methods queue up | Snapshot state, exit the actor, do the work, re-enter only to apply results. |
| Hand-rolling locks in a struct because "it's faster" | `Sendable` invariants impossible to prove | Make it an actor; let Swift do the work. |
| Cross-actor closure capture | Compiler complains; you reach for `@unchecked` to silence it | The capture is the bug, not the diagnostic. Refactor to pass `Sendable` payloads. |

---

## Codemixer instance

- The engine (`AgentEngine`), bus (`MulticastEventBus`), PTY (`PTYHost`), terminal (`TerminalEngine`), hook server (`HookServer`), git diff (`GitDiffEngine`), heartbeat (`HeartbeatActivityMonitor`), status (`StatusPhraseResolver`) are all plain actors.
- `@MainActor` appears only in `AgentUI` (view models, `EngineViewModel`, `ConversationViewModel`, etc.).
- `SwiftTerm.Terminal` is wrapped in the `TerminalEngine` actor; its callback delegate is `@unchecked Sendable` with documented invariants.
- FSEvents and DispatchIO use `@unchecked Sendable` bridges.
- `RemoteControlServer` is a plain actor; client connections are sub-actors.

See [docs/architecture.md §7](../../architecture.md) for the Codemixer narrative.

---

## Minimum viable adoption

1. Turn on `StrictConcurrency = complete` and `-warnings-as-errors`.
2. Fix every warning by making types `Sendable` or moving them to actors. Don't suppress.
3. Move every type to a plain `actor` by default. Reach for `@MainActor` only at the UI seam.
4. Audit every `@unchecked Sendable` annotation. Add the invariants block above.
5. Add a CI grep that fails the build if `@MainActor` appears outside the UI module.
6. Ship.

After two weeks, the codebase is concurrency-safe by construction. Stay vigilant in PR review; the discipline pays compounding interest.
