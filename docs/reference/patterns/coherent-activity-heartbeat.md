# Pattern: Coherent activity heartbeat

**Scope.** A server-side state machine that emits structured "still working" events with locked thresholds, so every connected client agrees on activity timing to the millisecond. The pattern unifies "is the agent thinking?" UX across in-process UI, remote clients, voice prompts, and automation.

**When to use.** Any system where:

- Work happens in bursts with gaps the user must understand.
- Multiple consumers (windows, devices, clients) need to render the same "is it working?" hint.
- The work has multiple sub-states (thinking, tool, stream, idle) that warrant different UI.

**When not to use.** Pure request/response with sub-second latency. Single-consumer apps where a local spinner is enough.

---

## The two cooperating actors

```
   ┌─────────────────────────────────────────────────────────────────┐
   │                       Engine (server-side)                      │
   │                                                                 │
   │    ┌────────────────────────┐   ┌────────────────────────────┐  │
   │    │ HeartbeatActivityMonitor│   │  StatusPhraseResolver       │  │
   │    │  (actor)                │   │  (actor)                    │  │
   │    │                         │   │                             │  │
   │    │  on every Event:        │   │  on every Event/snapshot:    │  │
   │    │   bump baseline         │   │   resolve current phrase    │  │
   │    │  every 500ms while busy:│   │  on change:                 │  │
   │    │   emit noEventGap       │   │   emit statusPhraseChanged  │  │
   │    │  on substate change:    │   └─────────────────────────────┘  │
   │    │   emit activityChanged  │                                    │
   │    └─────────────────────────┘                                    │
   │                                                                   │
   │           Both publish into MulticastEventBus                     │
   └─────────────────────────────────────────────────────────────────┘
                                  │
            ┌─────────────────────┼─────────────────────┐
            ▼                     ▼                     ▼
       Mac UI               Mobile remote          Voice / TTS
   (renders shimmer,      (renders shimmer,     (announces "still
    status pill)            status pill)         working" after 10s)
```

The clients are passive — they render whatever the resolver decides. The thresholds and the priority list live **only on the server**.

---

## `HeartbeatActivityMonitor`

```swift
public actor HeartbeatActivityMonitor {

    public struct Tick: Sendable {
        public let elapsed: Duration
        public let substate: ActivitySubstate
    }

    public enum Baseline: Sendable {
        case awaitingFirstChunk
        case streamingText
        case thinking
        case runningTool
        case idle
    }

    private let clock: any Clock
    private let onTick: @Sendable (Tick) async -> Void
    private var currentTaskID: UUID?
    private var taskStartedAt: ContinuousClock.Instant?
    private var lastEventAt: ContinuousClock.Instant?
    private var baseline: Baseline = .idle
    private var substate: ActivitySubstate = .idle
    private var timer: Task<Void, Never>?

    public init(clock: any Clock,
                onTick: @escaping @Sendable (Tick) async -> Void) {
        self.clock = clock
        self.onTick = onTick
    }

    public func startTurn(_ id: UUID, baseline: Baseline) async {
        currentTaskID = id
        taskStartedAt = clock.monotonic()
        lastEventAt = clock.monotonic()
        self.baseline = baseline
        await setSubstate(.awaitingFirstChunk)
        startTimer()
    }

    public func bump(baseline: Baseline) async {
        lastEventAt = clock.monotonic()
        self.baseline = baseline
        await setSubstate(stableSubstate(for: baseline, gap: .zero))
    }

    public func endTurn() async {
        currentTaskID = nil
        taskStartedAt = nil
        lastEventAt = nil
        baseline = .idle
        await setSubstate(.idle)
        timer?.cancel()
        timer = nil
    }

    private func startTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await self?.clock.sleep(for: .milliseconds(500))
                await self?.heartbeat()
            }
        }
    }

    private func heartbeat() async {
        guard let id = currentTaskID, let last = lastEventAt else { return }
        let gap = clock.monotonic() - last
        let resolved = stableSubstate(for: baseline, gap: gap)
        if resolved != substate {
            await setSubstate(resolved)
        }
        await onTick(Tick(elapsed: gap, substate: resolved))
    }

    private func setSubstate(_ next: ActivitySubstate) async {
        substate = next
    }

    private func stableSubstate(for baseline: Baseline, gap: Duration) -> ActivitySubstate {
        // Locked thresholds — never replicated client-side.
        if gap < .milliseconds(800) {
            switch baseline {
            case .awaitingFirstChunk: return .awaitingFirstChunk
            case .streamingText:       return .streamingText
            case .thinking:            return .thinking
            case .runningTool:         return .runningTool
            case .idle:                return .idle
            }
        }
        if gap < .seconds(10)  { return .working }
        if gap < .seconds(90)  { return .stalled }
        return .suspectedHang
    }
}
```

**Properties:**

- The actor is the *only* place the 800ms / 10s / 90s thresholds appear. Clients receive only the resolved substate.
- `bump(baseline:)` is called from the engine on every ingested event, immediately resetting the gap to zero.
- The 500ms timer runs on the actor's executor (via `Task`); when the actor is busy, the tick queues — preserving causality with ingested events.
- `endTurn()` cancels the timer. No background work continues after a turn ends.

---

## `ActivitySubstate` — the publishable type

```swift
public enum ActivitySubstate: String, Sendable, Codable, Equatable {
    case idle
    case awaitingFirstChunk
    case streamingText
    case thinking
    case runningTool
    case working          // generic "still going" — 800ms+ since last event
    case stalled          // 10s+ since last event
    case suspectedHang    // 90s+ since last event
}
```

Each value is a UI commitment. Clients map the enum to visuals:

| Substate | UI |
| --- | --- |
| `.idle` | Composer enabled; no shimmer; no status pill. |
| `.awaitingFirstChunk` | Shimmer dots; status pill showing the resolved phrase. |
| `.streamingText` | Shimmer dots; phrase "Streaming response…". |
| `.thinking` | Brain pulsing in the bubble's thinking block. |
| `.runningTool` | Tool card animated; phrase shows the tool name. |
| `.working` | Phrase becomes generic "Working… (Ns)" with elapsed seconds. |
| `.stalled` | Phrase becomes "Still working…"; Stop button becomes prominent. |
| `.suspectedHang` | Toast appears: "Agent may be stalled. Cancel?" |

Adding a new substate requires updating every client; it's a wire-version bump candidate.

---

## `StatusPhraseResolver`

A second actor decides what *text* the status pill shows. Its priority list:

```swift
public actor StatusPhraseResolver {

    private var activeToolName: String?       // "Bash", "Edit"
    private var liveThinkingPhrase: String?   // from streaming thinking content
    private var tuiHintPhrase: String?        // last "Pondering…" etc. from screen snapshot
    private var elapsed: Duration = .zero
    private var lastResolved: String?

    private let onChange: @Sendable (StatusPhraseSource, String) async -> Void

    public init(onChange: @escaping @Sendable (StatusPhraseSource, String) async -> Void) {
        self.onChange = onChange
    }

    public func setActiveTool(_ name: String?) async { activeToolName = name; await emitIfChanged() }
    public func setThinking(_ phrase: String?) async { liveThinkingPhrase = phrase; await emitIfChanged() }
    public func setTUIHint(_ phrase: String?) async { tuiHintPhrase = phrase; await emitIfChanged() }
    public func setElapsed(_ duration: Duration) async { elapsed = duration; await emitIfChanged() }

    private func emitIfChanged() async {
        let (source, phrase) = resolve()
        if phrase != lastResolved {
            lastResolved = phrase
            await onChange(source, phrase)
        }
    }

    private func resolve() -> (StatusPhraseSource, String) {
        if let tool = activeToolName { return (.tool, "Running \(tool)…") }
        if let phrase = liveThinkingPhrase { return (.thinking, phrase) }
        if let phrase = tuiHintPhrase { return (.tui, phrase) }
        return (.heartbeat, "Working… (\(elapsed.seconds)s)")
    }
}

public enum StatusPhraseSource: String, Sendable, Codable {
    case tool, thinking, tui, heartbeat
}
```

**Priority is high → low:** active tool > live thinking > TUI hint > heartbeat default. The client receives the resolved phrase and the source tag (used for analytics and debugging only — not for UI logic).

---

## Why server-side resolution

If clients computed activity locally:

- Each client's clock disagrees by milliseconds (Wi-Fi jitter, sleep cycles).
- One client says "stalled at 10s," another at "9.8s," a third still at "working" — the user wonders which to trust.
- Voice clients (TTS announcements) and visual clients can't synchronise.
- Reduce-Motion / low-power adjustments would have to be made N times.

With server-side resolution:

- Every client sees the exact same substate transitions at the exact same publish moment.
- Reduce-Motion is the *renderer's* concern: the substate is the same, the animation is different.
- TTS announcements ("agent may be stalled") fire when the server says so, identically to the visual.

---

## The bus integration

The engine wires both actors at start:

```swift
public func start(...) async throws {
    // …

    let heartbeat = HeartbeatActivityMonitor(clock: seams.clock) { [weak self] tick in
        await self?.onHeartbeat(tick)
    }
    self.heartbeat = heartbeat

    let resolver = StatusPhraseResolver { [weak self] source, phrase in
        await self?.bus.publish(.statusPhraseChanged(source: source, phrase: phrase))
    }
    self.phraseResolver = resolver

    // …
}

private func ingest(_ event: AgentEvent) async {
    switch event {
    case .toolStart(let name, _, _, _):
        await phraseResolver?.setActiveTool(name)
        await heartbeat?.bump(baseline: .runningTool)
    case .toolEnd:
        await phraseResolver?.setActiveTool(nil)
        await heartbeat?.bump(baseline: .awaitingFirstChunk)
    case .textDelta:
        await heartbeat?.bump(baseline: .streamingText)
    case .thinkingChunk(_, let delta):
        await phraseResolver?.setThinking(delta)
        await heartbeat?.bump(baseline: .thinking)
    case .thinkingComplete:
        await phraseResolver?.setThinking(nil)
    default: break
    }
    await bus.publish(event)
}

private func onHeartbeat(_ tick: HeartbeatActivityMonitor.Tick) async {
    guard let id = currentTurnID else { return }
    await phraseResolver?.setElapsed(tick.elapsed)
    await bus.publish(.noEventGap(taskID: id, elapsed: tick.elapsed))
    await bus.publish(.activityStateChanged(tick.substate))
}
```

Three events flow on the bus:

1. **Original event** (e.g. `toolStart`) — unchanged, the canonical record.
2. **`statusPhraseChanged`** — when the resolver's output changes.
3. **`activityStateChanged`** + **`noEventGap`** — when the heartbeat's substate changes or every 500ms during work.

Clients render based on the three. There is no fourth source.

---

## Testing with `FakeClock`

The pattern is naturally testable through the `Clock` seam:

```swift
@Test func stallTransitionsCorrectly() async throws {
    let clock = FakeClock()
    var ticks: [HeartbeatActivityMonitor.Tick] = []

    let monitor = HeartbeatActivityMonitor(clock: clock) { tick in
        ticks.append(tick)
    }

    let id = UUID()
    await monitor.startTurn(id, baseline: .awaitingFirstChunk)

    // Advance 9 seconds — should still be .working
    clock.advance(by: .seconds(9))
    #expect(ticks.last?.substate == .working)

    // Advance to 10 seconds — should transition to .stalled
    clock.advance(by: .seconds(1))
    #expect(ticks.last?.substate == .stalled)

    // Advance to 90 seconds total — should transition to .suspectedHang
    clock.advance(by: .seconds(80))
    #expect(ticks.last?.substate == .suspectedHang)

    await monitor.endTurn()
}
```

Microseconds, deterministic, exhaustive.

---

## Anti-patterns

| Anti-pattern | Symptom | Fix |
| --- | --- | --- |
| Each client computes elapsed time from its own clock | Three clients disagree about "stalled" timing | Server resolves; clients render. |
| Heartbeat ticks at 50ms | Bus saturates, CPU climbs | 500ms is the empirical sweet spot. |
| Heartbeat continues after `endTurn()` | Background activity events confuse the UI | Cancel the timer in `endTurn`. |
| Resolver re-emits the same phrase | Bus traffic, visual flicker | Track `lastResolved` and only emit on change. |
| Threshold values hard-coded in clients | Bumping them requires shipping every client | Locks live in the server. |
| Substate enum stored as `Int` instead of `String` rawValue | Adding a case shifts all numeric values; old clients break | Always rawValue `String`. |
| Heartbeat using `Date()` instead of monotonic time | NTP adjustments cause backward jumps | Always `ContinuousClock` monotonic. |

---

## Codemixer instance

- `HeartbeatActivityMonitor` ↔ `Core/AgentCore/Activity/HeartbeatActivityMonitor.swift`.
- `StatusPhraseResolver` ↔ `Core/AgentCore/Status/StatusPhraseResolver.swift`.
- `ActivitySubstate` ↔ `Core/AgentProtocol/Decisions.swift` (wire-shared because clients receive it).
- Locked thresholds: 800ms / 10s / 90s, per [docs/architecture.md §15](../../architecture.md).

---

## Minimum viable adoption

1. Define your `ActivitySubstate` enum on the wire side.
2. Build a `HeartbeatActivityMonitor` actor. Hard-code the thresholds inside it.
3. Wire it to the engine's `ingest`: every event calls `bump(baseline:)`.
4. Publish `.noEventGap` and `.activityStateChanged` from a timer callback.
5. Build a `StatusPhraseResolver` (optional, but recommended). Publish `.statusPhraseChanged`.
6. UI consumers render based on the published events — they compute *nothing*.
7. Add `FakeClock`-driven tests for each threshold.

The user experience improvement is immediate: every gap in agent response is bridged by a server-coherent signal that the agent is still alive.
