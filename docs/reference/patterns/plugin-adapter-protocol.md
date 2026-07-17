# Pattern: Plugin adapter protocol

**Scope.** Quarantining vendor-specific or domain-specific knowledge into self-contained plug-in modules behind one `Sendable` protocol. The core engine stays generic forever; new vendors arrive as new sibling modules with zero edits to anything else.

**When to use.** Any system that must support N back-ends where the back-ends share an interaction shape but differ in payloads, lifecycle, authentication, or wire format. Examples: code-completion services, LLM CLI agents, version-control providers, payment processors, deployment targets, OAuth providers.

**When not to use.** Single-vendor projects where YAGNI dominates. Cross-cutting concerns that don't compose along vendor lines.

---

## The shape

```
                              ┌──────────────────────┐
                              │      Engine (core)    │
                              │     uses Adapter      │
                              └─────────┬────────────┘
                                        │
                                        ▼
                       ┌───────────────────────────────────┐
                       │   Adapter protocol (Sendable)     │
                       └───────────────────────────────────┘
                                        ▲
                  ┌─────────────────────┼─────────────────────┐
                  │                     │                     │
        ┌─────────┴────────┐  ┌─────────┴────────┐  ┌─────────┴────────┐
        │ Vendor A Adapter │  │ Vendor B Adapter │  │ Vendor C Adapter │
        │   (its module)   │  │   (its module)   │  │   (its module)   │
        └──────────────────┘  └──────────────────┘  └──────────────────┘
```

Every vendor lives in its own SPM target. The core has zero `import VendorASDK`; the adapter has zero awareness of UI, network, or other vendors. The engine wires up the rest from the adapter's declared capabilities.

---

## The complete contract — by sections

```swift
public protocol Adapter: Sendable {

    // 1. Identity
    var id: AdapterID { get }
    var displayName: String { get }
    var iconSymbol: String { get }      // SF Symbol or platform equivalent

    // 2. Discovery, launch & transport
    func locateBinary(env: ResolvedEnvironment) async throws -> URL
    func defaultEnvOverrides() -> [String: String]
    func buildLaunchArgv(context: LaunchContext) -> [String]
    var transportDescriptor: AgentTransportDescriptor { get }

    // 3. Authentication
    func authStatus(env: ResolvedEnvironment) async -> AuthStatus
    func authURLPattern() -> NSRegularExpression?
    func loginCommandArgv() -> [String]?

    // 4. Capability declaration
    var capabilities: AdapterCapabilities { get }

    // 5. Event ingestion
    func makeEventStream(inputs: AdapterInputs) -> AsyncStream<Event>

    // 6. Sending input
    func encodeUserInput(_ text: String) -> Data
    func cancelSequence() -> Data
    func sessionBootstrapBytes(context: LaunchContext) -> Data
    func encodeCommand(_ command: AgentCommand) -> Data?

    // 7. Permission responses (if applicable)
    func encodePermissionResponse(_ decision: PermissionDecision,
                                  for prompt: PermissionPrompt) -> PermissionResponseDelivery

    // 8. Slash-command catalog
    var actionCatalog: [Action] { get }
    func enumerateProjectActions(workspace: URL) async -> [Action]

    // 9. Model catalog (composer picker; default `[]` in protocol extension)
    func availableModels() -> [AgentModelOption]

    // 10. Resume / session listing
    func listResumableSessions(workspace: URL) async -> [SessionSummary]
    func resumeArgvAddition(sessionID: String) -> [String]

    // 11. Rendering hints
    func renderHint(toolName: String, input: ToolInput) -> RenderHint
}
```

Codemixer's live protocol uses `SlashCommand`, `AgentModelOption`, and
transport-specific `AgentTransportDescriptor` names — see `AgentAdapter.swift`.

Each section is a *boundary* — a place where vendor specifics would otherwise
leak into the core. Skipping a section because "vendor X doesn't need it" is
fine only when the core has an explicit interpretation for that sentinel
(`nil`, `[]`, `.none`). Silent skips are not allowed.

## Transport Descriptors

Transport is declared by the adapter, not inferred from capabilities:

```swift
public enum AgentTransportKind: Sendable, Hashable, Codable {
    case interactiveTerminal
    case stdioJSONRPC
    case agentClientProtocol
}

public struct AgentTransportDescriptor: Sendable, Hashable, Codable {
    public static let interactiveTerminal: Self
    public static let stdioJSONRPC: Self
    public static let agentClientProtocol: Self
}
```

- Claude Code declares `.interactiveTerminal`; the implementation wraps
  `PTYHost` + `TerminalEngine` so the real CLI stays on the interactive billing
  path and avoids Agent Credits from third-party / SDK-style Claude Code
  invocations.
- Codex declares `.stdioJSONRPC`; the implementation spawns
  `codex app-server --stdio` and sends JSON-RPC frames directly.
- `.agentClientProtocol` is reserved and currently returns an explicit
  unsupported transport error until a real ACP implementation lands.

Transport is not a capability bit. Capabilities describe optional signal
sources and adapter features; transport describes the process/connection shape.

---

## Capabilities as an `OptionSet`

```swift
public struct AdapterCapabilities: OptionSet, Sendable {
    public let rawValue: UInt32

    public static let hooksOverIPC      = AdapterCapabilities(rawValue: 1 << 0)
    public static let structuredOutput  = AdapterCapabilities(rawValue: 1 << 1)
    public static let streamingJSON     = AdapterCapabilities(rawValue: 1 << 2)
    public static let resumableSessions = AdapterCapabilities(rawValue: 1 << 3)
    public static let permissionPrompts = AdapterCapabilities(rawValue: 1 << 4)
    public static let fsEventsHints     = AdapterCapabilities(rawValue: 1 << 5)
    public static let attachments       = AdapterCapabilities(rawValue: 1 << 6)
}
```

The engine reads `capabilities` *once* at start and wires up only the matching signal sources. Examples:

- `.hooksOverIPC` → engine starts a Unix-domain-socket listener and passes the handle to the adapter via `AdapterInputs.hookSocket`.
- `.fsEventsHints` → engine starts a file-system watcher and passes its `AsyncStream<FSEvent>` via `AdapterInputs.fsEvents`.
- `.permissionPrompts` → engine honours `PermissionResponseDelivery` from the adapter.
- `.resumableSessions` → UI shows a "resume previous session" picker.

If `.hooksOverIPC` is absent, the engine doesn't start the listener — no wasted resources, no half-configured state.

**An adapter never lies about its capabilities.** Declaring `.streamingJSON` and then emitting unparseable bytes is a hard bug. A debug-build assertion checks that adapter behavior matches its declared set on every event.

---

## The signal-fusion responsibility belongs to the adapter

The adapter ingests *multiple* raw signal sources and emits *one* normalised `Event` stream:

```swift
public struct AdapterInputs: Sendable {
    public let outputBytes: AsyncStream<Data>          // primary subprocess output
    public let hookSocket: HookSocketHandle?           // nil unless .hooksOverIPC
    public let workspace: URL
    public let sessionID: AsyncStream<String>          // hot stream — empty until known
    public let fsEvents: AsyncStream<FSEvent>?          // nil unless .fsEventsHints
    public let terminal: (any TerminalSnapshotting)?   // nil for non-terminal vendors
}

public extension Adapter {
    func makeEventStream(inputs: AdapterInputs) -> AsyncStream<Event> {
        AsyncStream { continuation in
            Task {
                async let hookEvents = consumeHooks(inputs.hookSocket)
                async let outputEvents = consumeRawOutput(inputs.outputBytes)
                async let fsEvents = consumeFSEvents(inputs.fsEvents)

                for await event in merge(hookEvents, outputEvents, fsEvents) {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}
```

**Why fusion lives in the adapter, not the core:**

- Different vendors disagree about which signal is canonical for which event.
- Deduplication policy is vendor-specific (e.g. "hook + transcript both report tool-end; trust the hook's timing").
- Claude Code example: transcript JSONL is canonical for final `assistantText`; Stop `last_assistant_message` is fallback after drain — see `ClaudeAdapter` + `CONTRACT.md`.
- The core would otherwise grow a giant priority table for every vendor combination.

**The principle:** the engine consumes *one* `AsyncStream<Event>` per session. The adapter is responsible for ensuring that stream is consistent.

---

## Registering adapters

```swift
public actor AdapterRegistry {
    public static let shared = AdapterRegistry()

    private var byID: [AdapterID: any Adapter] = [:]

    public func register(_ adapter: any Adapter) {
        byID[adapter.id] = adapter
    }

    public func adapter(for id: AdapterID) -> (any Adapter)? {
        byID[id]
    }

    public func all() -> [any Adapter] {
        Array(byID.values).sorted { $0.displayName < $1.displayName }
    }
}
```

Each app boot calls `AdapterRegistry.shared.register(VendorAAdapter())`. The picker UI iterates `all()`. Tests register a `MockAdapter` and proceed.

**Discovery is explicit by design.** Reflection / runtime-scan / dlopen-based plug-ins are fragile, hard to test, and security-loaded. Explicit registration at startup keeps the picker deterministic and the binary signature verifiable.

---

## Adding a vendor in seven steps

1. Create a new SPM target `VendorAAdapter` depending on the core protocol module.
2. Implement `Adapter`. Most sections are short; `makeEventStream` is where the work lives.
3. Declare capabilities accurately (`.streamingJSON`, `.resumableSessions`, etc.).
4. Add a test target `VendorAAdapterTests` with golden fixtures of raw input and expected `Event` output.
5. Register at app startup.
6. (If applicable) add a UI icon and entry to the picker — usually a one-line addition because the picker iterates the registry.
7. Ship.

No edits to the core. No edits to other adapters. No edits to UI components beyond the picker.

---

## Per-tool / per-action rendering hints stay generic

```swift
public enum RenderHint: Sendable {
    case bashStreaming(initialCommand: String)
    case fileEdit(path: URL, language: String?)
    case fileRead(path: URL, language: String?)
    case fileSearch(pattern: String)
    case webFetch(url: URL)
    case mcpTool(serverName: String, toolName: String)
    case raw(json: String)
}
```

Tool names differ across vendors ("Bash" / "shell" / "execute"; "Edit" / "replace" / "patch"), but the *render hint* is stable. UI components key off the hint, not the vendor's tool name. Adding a vendor whose tool happens to be a "bash invocation" just returns `.bashStreaming(...)`; the existing renderer works unchanged.

When you add a new hint case, you're declaring a new visual category. That's a UI commitment; review the visual style guide before adding.

---

## Anti-patterns

| Anti-pattern | Why it's bad |
| --- | --- |
| `if adapter is VendorAAdapter { ... }` anywhere in the core | Reintroduces vendor knowledge into the core. Refactor the special case into the protocol. |
| Adapters depending on each other | Couples vendors. They should be siblings, not a chain. |
| Adapters depending on the UI module | Inverts the dependency arrow. Adapters emit events; the UI consumes them. |
| Implicit registration via runtime scan | Hard to test, hard to audit, hard to sign. |
| Capabilities lying ("I declare X but secretly need Y") | Engine wires the wrong sources, runtime confusion. |
| Vendor SDK imported in the public-facing protocol module | Forces every consumer to import that SDK transitively. Quarantine inside the adapter. |
| Multi-instance singletons of the same adapter | If two registrations of `VendorAAdapter` make sense, model that as multiple `AdapterID`s; never juggle "the second instance." |

---

## Codemixer instance

- `Adapter` ↔ `AgentAdapter` (in `Core/AgentCore/Events/AgentAdapter.swift`).
- `AdapterID` ↔ `AgentID` (with cases `.claudeCode`, `.codex`, `.cursorCLI`, …).
- `AdapterCapabilities` ↔ `AgentCapabilities`.
- `AdapterInputs` ↔ `AgentInputs`.
- `AdapterRegistry` ↔ `AdapterRegistry`.

`ClaudeCode` under `src/AgenticCLIs/` is the v1 reference (ships `ClaudeAdapter`); the registry pattern lets `CodexCLI`, `CursorCLIAdapter`, `GeminiCLI`, etc. ship later as sibling folders with zero core edits. See [`src/AgenticCLIs/README.md`](../../src/AgenticCLIs/README.md) and [docs/architecture.md §5](../../architecture.md) for layout and wiring.

---

## Minimum viable adoption

1. Define the `Adapter` protocol with the 10 sections — even if half of them have trivial defaults for your domain.
2. Define `Capabilities` as an `OptionSet` so engine wiring is declarative.
3. Build a `MockAdapter` in your test-support target before you build the first real one — it will surface protocol awkwardness early.
4. Implement the first real adapter. Aim for ≤ 600 lines.
5. Add a registry and one registration call at boot.
6. Ship.

When you add the second adapter, you'll discover what the protocol got wrong. Refine, fold corrections back, both adapters get cleaner. The third adapter will reveal nothing.
