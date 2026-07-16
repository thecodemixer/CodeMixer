# Pattern: Wire / domain boundary

**Scope.** Splitting your types into two flavours — a *domain* type with rich Foundation references for in-process use, and a *wire* DTO with portable `Codable` representations for the network — with one converter between them and a property test that proves the conversion is lossless.

**When to use.** Any project where the same data needs to travel between a process you control (full Foundation, full platform) and a process or client you don't (iOS, Android, Linux, browser, scripts). The pattern shines once you have a remote-control API, a backup format, or a CLI that exchanges JSON with the GUI.

**When not to use.** Single-process projects where the network frontier doesn't exist. Just use one flavour.

---

## The two flavours

| Layer | Lives in | Uses | Audience |
| --- | --- | --- | --- |
| **Domain** | Core module (e.g. `AgentCore`). Imports Foundation. | `URL`, `Date`, `Duration`, `UUID`, rich enums with associated values, computed properties, methods. | The engine, its subsystems, in-process consumers. |
| **Wire** | Portable module (e.g. `AgentProtocol`). Imports Foundation only. | `String` for URLs, ISO-8601 strings or epoch-ms for dates, integer-millisecond durations, simple Codable enums. | The network, persisted files, remote clients on any platform. |

The portable module has no `import AppKit`, no `import Network`, no platform-specific Foundation calls. In Codemixer, `AgentProtocol` ships inside a **macOS-only** SPM package today, but stays Foundation-only so a future non-Mac client can import the same wire types.

---

## Why both, not one

**Domain types are not on the wire because:**

- `URL` doesn't round-trip cleanly across platforms (resource specifiers, security scopes, base URLs).
- `Date` precision differs across decoders.
- `Duration` (Swift 5.7+) isn't `Codable` natively.
- Methods, computed properties, and `@MainActor` extensions don't survive Codable.

**Wire types are not used in-process because:**

- String-encoded URLs are clumsy to compose.
- Integer-millisecond durations are awkward to compute against.
- A `Codable` enum loses the type safety of associated-value pattern matching once you start using it heavily.

The pattern accepts both tensions and absorbs them at one converter.

---

## A concrete example

```swift
// Domain — Core/AgentCore/Events/AgentEvent.swift
public enum AgentEvent: Sendable {
    case sessionStarted(sessionID: String, model: String?, cwd: URL)
    case taskOutput(taskID: UUID, delta: String)
    case toolStart(id: String, name: String, input: ToolInput, startedAt: Date)
    case noEventGap(taskID: UUID, elapsed: Duration)
    case error(EngineError)
    case stopped(reason: StopReason)
}

// Wire — Core/AgentProtocol/AgentEventWire.swift
public enum AgentEventWire: Codable, Sendable {
    case sessionStarted(SessionStartedPayload)
    case taskOutput(TaskOutputPayload)
    case toolStart(ToolStartPayload)
    case noEventGap(NoEventGapPayload)
    case error(EngineErrorPayload)
    case stopped(StoppedPayload)

    public struct SessionStartedPayload: Codable, Sendable {
        public let sessionID: String
        public let model: String?
        public let cwdPath: String
    }

    public struct TaskOutputPayload: Codable, Sendable {
        public let taskID: String           // UUID as string
        public let delta: String
    }

    public struct ToolStartPayload: Codable, Sendable {
        public let id: String
        public let name: String
        public let input: ToolInputWire
        public let startedAtMS: Int64       // epoch milliseconds
    }

    public struct NoEventGapPayload: Codable, Sendable {
        public let taskID: String
        public let elapsedMS: Int64
    }
    // …
}

public let wireProtocolVersion: Int = 1
```

The wire layer is a one-shape-per-case `Codable` mirror. No clever encoding. No discriminator strings to remember. The compiler's exhaustiveness checks both sides.

---

## The single converter

One file, one type, two methods:

```swift
// Core/AgentCore/Events/WireCodec.swift
public enum WireCodec {

    public static func encode(_ event: AgentEvent) -> AgentEventWire {
        switch event {
        case .sessionStarted(let id, let model, let cwd):
            return .sessionStarted(.init(sessionID: id, model: model, cwdPath: cwd.path))
        case .taskOutput(let id, let delta):
            return .taskOutput(.init(taskID: id.uuidString, delta: delta))
        case .toolStart(let id, let name, let input, let startedAt):
            return .toolStart(.init(
                id: id, name: name,
                input: encode(input),
                startedAtMS: Int64(startedAt.timeIntervalSince1970 * 1000)
            ))
        case .noEventGap(let id, let elapsed):
            return .noEventGap(.init(taskID: id.uuidString, elapsedMS: Int64(elapsed.milliseconds)))
        case .error(let e):
            return .error(encode(e))
        case .stopped(let reason):
            return .stopped(.init(reason: reason.rawValue))
        }
    }

    public static func decode(_ wire: AgentEventWire) -> AgentEvent {
        switch wire {
        case .sessionStarted(let p):
            return .sessionStarted(sessionID: p.sessionID, model: p.model, cwd: URL(fileURLWithPath: p.cwdPath))
        case .taskOutput(let p):
            return .taskOutput(taskID: UUID(uuidString: p.taskID) ?? UUID(), delta: p.delta)
        case .toolStart(let p):
            return .toolStart(
                id: p.id, name: p.name,
                input: decode(p.input),
                startedAt: Date(timeIntervalSince1970: Double(p.startedAtMS) / 1000)
            )
        case .noEventGap(let p):
            return .noEventGap(taskID: UUID(uuidString: p.taskID) ?? UUID(),
                               elapsed: .milliseconds(p.elapsedMS))
        case .error(let p): return .error(decode(p))
        case .stopped(let p): return .stopped(reason: StopReason(rawValue: p.reason) ?? .unknown)
        }
    }
}
```

**Rules of the converter:**

- Lives in *exactly one file*.
- Is `enum`-based (a namespace), so no instance state.
- Exhaustive `switch` on both directions — adding a new case fails the build until the converter is updated.
- No conditional compilation. No `#if os(...)`. The converter is portable.
- No `try` — domain → wire and wire → domain are total functions. If you have a fallible conversion (`UUID(uuidString:)` returns optional), make a sensible default; never throw.

---

## The parity test

The single test that holds the whole pattern together:

```swift
// tests/Remote/RemoteParityTests/WireCodecParityTests.swift
import Testing
@testable import AgentCore
@testable import AgentProtocol

@Suite struct WireCodecParity {

    @Test func everyCaseRoundTripsLosslessly() {
        let samples: [AgentEvent] = [
            .sessionStarted(sessionID: "s1", model: "claude-3.7", cwd: URL(filePath: "/tmp/x")),
            .taskOutput(taskID: UUID(), delta: "hello"),
            .toolStart(id: "t1", name: "Bash", input: .bash(cmd: "ls"), startedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            .noEventGap(taskID: UUID(), elapsed: .milliseconds(750)),
            .error(.adapter(domain: "claude", code: "AUTH", message: "expired")),
            .stopped(reason: .userCancel),
        ]

        for original in samples {
            let wire = WireCodec.encode(original)
            let data = try! JSONEncoder().encode(wire)
            let decoded = try! JSONDecoder().decode(AgentEventWire.self, from: data)
            let restored = WireCodec.decode(decoded)
            #expect(restored == original, "case did not survive round trip: \(original)")
        }
    }

    @Test func wireFormatIsStable() throws {
        let sample = AgentEvent.taskOutput(taskID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                           delta: "hello")
        let wire = WireCodec.encode(sample)
        let json = try JSONEncoder().encode(wire)
        let goldenURL = Bundle.module.url(forResource: "task-output", withExtension: "json")!
        let golden = try Data(contentsOf: goldenURL)
        #expect(json == golden, "wire format changed; review golden or bump wire version")
    }
}
```

**Two assertions:**

1. **Round-trip parity.** Every case encodes, JSON-serializes, deserializes, and decodes back to the same value. The `Equatable` conformance on the domain enum is required.
2. **Format stability.** Each case has a checked-in golden JSON file. Changing the wire format means updating the golden — a deliberate review step.

These tests are the canary. They fail when:

- A new case is added to the domain without updating the wire.
- A new case is added to the wire without updating the converter.
- A field is renamed in the wire (golden mismatch).
- The wire DTO's `Codable` synthesis changes due to a Swift-version upgrade.

---

## Versioning

Every wire frame carries a version number:

```swift
public enum ClientFrame: Codable, Sendable {
    case subscribe(SubscribeFrame)
    case command(CommandFrame)
    case ping
}

public struct CommandFrame: Codable, Sendable {
    public let v: Int                 // wireProtocolVersion
    public let correlationID: UUID
    public let command: AgentCommand
}
```

The reader checks `v` before decoding the rest. Mismatches produce a typed `versionMismatch(server: Int, client: Int)` error.

**Compatibility policy:**

- **Additive**: new optional field on an existing case → usually no `WireVersion` bump; ship coordinated codec updates.
- **Breaking**: renamed tag, removed field, stricter decoding → bump `WireVersion.current`.
- **No dual-speak:** mismatched `v` is rejected with `ServerFrame.versionMismatch`; servers do not decode multiple versions concurrently.
- **No `unknown` wire catch-alls:** wire enums decode exhaustively; new event/command cases require a version bump and coordinated release.

```swift
// Decoders guard version before branching on type:
let version = try c.decode(WireVersion.self, forKey: .v)
guard version == .current else { throw DecodingError... }
```

---

## Domain types stay in the domain

A common slip: code that *reads* a wire frame *and stores* it. Don't.

```swift
// BAD — wire type leaking into engine state
private var lastEvent: AgentEventWire?

// GOOD — convert at the boundary, store domain
private var lastEvent: AgentEvent?

func handle(_ wire: AgentEventWire) {
    let domain = WireCodec.decode(wire)
    self.lastEvent = domain
}
```

The converter is a *boundary*, not a pass-through. The engine sees `AgentEvent`; the network sees `AgentEventWire`; the converter is the single hop between them.

---

## Persistence as another "wire"

Files on disk are also a wire. Apply the same rules:

- A persisted preferences struct lives in the portable module as a `Codable` DTO with a `schemaVersion`.
- The domain `Prefs` struct lives in the core module with richer types.
- A converter handles encoding/decoding, including forward migrations (`schemaVersion: 1 → 2`).

```swift
public struct PrefsWire: Codable, Sendable {
    public let schemaVersion: Int
    public let theme: String              // "light"/"dark"/"auto"
    public let voiceEnabled: Bool
    public let autoResumeThresholdMS: Int64?
}

public struct Prefs: Sendable, Equatable {
    public var theme: Theme               // enum
    public var voiceEnabled: Bool
    public var autoResumeThreshold: Duration?
}

public enum PrefsCodec {
    public static func encode(_ prefs: Prefs) -> PrefsWire { … }
    public static func decode(_ wire: PrefsWire) -> Prefs { … }
    public static func migrate(_ wire: PrefsWire) -> PrefsWire {
        switch wire.schemaVersion {
        case 1: return migrateFromV1(wire)
        case 2: return wire
        default: return PrefsWire.empty
        }
    }
}
```

Same pattern, different cardinality.

---

## Anti-patterns

| Anti-pattern | Symptom | Fix |
| --- | --- | --- |
| Single type used both in-process and on the wire | Foundation types break the portable build; or wire compromises bleed into the engine. | Two types, one converter. |
| Converter scattered across many files | New events drift out of sync. | One file, one `WireCodec`. |
| No round-trip test | Subtle bugs in production. | Property test every case. |
| No golden file | Wire format changes silently, breaking remote clients. | Checked-in JSON golden per case. |
| Field renames without `v` bump | Old clients break. | Bump `v`, write a migration. |
| `Codable` synthesis without explicit `CodingKeys` | Re-ordering or renaming the property changes the wire. | Always declare `CodingKeys` on wire DTOs. |
| Forgetting to bump `WireVersion` on breaking change | Old and new clients disagree silently until runtime reject. | Bump `WireVersion.current`; reject mismatch with `versionMismatch`. |
| `unknown` catch-all on wire enums | Masks schema drift; clients hide new cases instead of upgrading. | Exhaustive wire enums; version bump for new cases. |

---

## Codemixer instance

- Domain types live in `Core/AgentCore/Events/AgentEvent.swift`.
- Wire types live in `Core/AgentProtocol/AgentEventWire.swift`.
- Converter lives in `Core/AgentCore/Events/WireCodec.swift`.
- Parity tests are in `tests/Remote/RemoteParityTests/` (`WireCodecParityTests`, `CommandDispatchParityTests`).
- Wire version declared in `Core/AgentProtocol/WireVersion.swift`; frames in `WireFrames.swift`.

See [docs/architecture.md §§8, 30](../../architecture.md) for the Codemixer narrative on event-sourcing and protocol evolution.

---

## Minimum viable adoption

1. Identify the boundary — the moment a value crosses the network or hits the disk.
2. Define the wire enum / struct in a portable, Foundation-only module.
3. Define (or keep) the domain enum / struct in the engine module.
4. Write the `WireCodec`. Exhaustive switches on both directions.
5. Write the round-trip property test.
6. Add the wire `v: Int` and the `versionMismatch` error.
7. Add golden JSON files for stable wire snapshots.
8. Ship.

When the second client platform arrives, it imports the portable module and is done — no fork, no re-implement.
