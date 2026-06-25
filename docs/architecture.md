# Codemixer Architecture

This document is the source of truth for *how Codemixer is put together*. [docs/style/code-style.md](style/code-style.md) governs how individual files read; [docs/style/visual-style.md](style/visual-style.md) governs how the product looks; this file governs how the system thinks. Read it once, fully, before you wire a new module to the engine, before you add an event, before you redraw an arrow.

When documents disagree, this file wins on structural decisions, `code-style.md` wins on how code reads, and `visual-style.md` wins on how something appears on screen.

---

## Contents

1. [Why this document exists](#1-why-this-document-exists)
2. [Product surface in one paragraph](#2-product-surface-in-one-paragraph)
3. [Foundational constraints](#3-foundational-constraints)
4. [The two-mode product](#4-the-two-mode-product)
5. [SPM module map](#5-spm-module-map)
6. [Layering and the dependency arrow](#6-layering-and-the-dependency-arrow)
7. [Concurrency model](#7-concurrency-model)
8. [The event-sourced core](#8-the-event-sourced-core)
9. [The PTY pipeline](#9-the-pty-pipeline)
10. [Event source priority](#10-event-source-priority)
11. [`AgentAdapter` — the agent extension point](#11-agentadapter--the-agent-extension-point)
12. [`AgentCommand` — the input alphabet](#12-agentcommand--the-input-alphabet)
13. [`AgentEngine` — the orchestrator](#13-agentengine--the-orchestrator)
14. [`MulticastEventBus` — fan-out and replay](#14-multicasteventbus--fan-out-and-replay)
15. [Activity indicators subsystem](#15-activity-indicators-subsystem)
16. [Dependency injection seams](#16-dependency-injection-seams)
17. [State machine and turn lifecycle](#17-state-machine-and-turn-lifecycle)
18. [Permissions subsystem](#18-permissions-subsystem)
19. [Git diff subsystem](#19-git-diff-subsystem)
20. [Persistence model](#20-persistence-model)
21. [Remote control architecture](#21-remote-control-architecture)
22. [Headless daemon (`codemixerd`)](#22-headless-daemon-codemixerd)
23. [Security model](#23-security-model)
24. [Error model](#24-error-model)
25. [Performance model](#25-performance-model)
26. [Testing topology](#26-testing-topology)
27. [Tooling and enforcement](#27-tooling-and-enforcement)
28. [End-to-end data flows](#28-end-to-end-data-flows)
29. [Failure modes and recovery](#29-failure-modes-and-recovery)
30. [Versioning and wire-protocol evolution](#30-versioning-and-wire-protocol-evolution)
31. [Extension recipes](#31-extension-recipes)
32. [Trade-offs and rejected alternatives](#32-trade-offs-and-rejected-alternatives)
33. [Glossary](#33-glossary)
34. [When in doubt](#34-when-in-doubt)

---

## Platform applicability

Codemixer ships first on **macOS 14+** and is structured so a future iOS / iPadOS / visionOS client can render the same `AgentEvent` stream over the remote-control API. Most architecture below is platform-agnostic Swift; concrete decisions that lean on a specific OS (`posix_spawn`, FSEvents, `NWListener`, Keychain, `launchctl`, `NSWorkspace`) are tagged inline:

- **[macOS]** — applies only on macOS.
- **[iOS / iPadOS / visionOS]** — applies on the noted mobile platforms.
- **[Apple cross-platform]** — applies anywhere the SwiftUI / Foundation / Network frameworks ship.
- **[Portable Swift]** — pure-Foundation / Swift; compiles on macOS, iOS, and Linux.

The wire-protocol module `AgentProtocol` is [Portable Swift] by design — that boundary is the reason the future iOS client doesn't have to fork.

---

## 1. Why this document exists

Three reasons:

1. **The architecture is unusual.** Codemixer drives an interactive TUI CLI agent through an *invisible* PTY while presenting a fully-native SwiftUI surface. The same engine runs in-process inside a Mac GUI app and standalone in a headless daemon. The same wire protocol carries Mac UI updates and remote iOS-client updates. None of these are off-the-shelf shapes; each warrants explicit justification.

2. **The constraints are unusually rigid.** Hidden PTY (billing). Strict concurrency (Swift 6.2). Headless capable (daemon). Adapter-pluggable (multi-agent). Remote-controllable (iOS later). Each constraint eliminates many otherwise-reasonable shapes; the survivors are described here so they don't get re-discovered by accident later.

3. **The wrong abstraction is expensive.** A misplaced `@MainActor`, an unscoped `Sendable` violation, a leaky adapter, a tightly-coupled UI binding, all rot the build. This document names the joints; future PRs are reviewed against it.

When a reviewer says *"this doesn't match the architecture"*, they mean this file.

---

## 2. Product surface in one paragraph

Codemixer is a native macOS workspace for driving any CLI coding agent (Claude Code in v1, Codex / Cursor CLI / Gemini CLI / OpenCode / Copilot in v1.1+) under a hidden pseudo-terminal. The terminal is never shown; every byte of agent output is translated into typed `AgentEvent`s and rendered by SwiftUI. The app runs as a GUI for direct use, as a headless daemon (`codemixerd`) for background sessions, and exposes a WebSocket remote-control API (TLS optional; see `RemoteDefaults`) that a future iOS client will speak verbatim. Architecture is event-sourced, actor-isolated, dependency-injected, and adapter-extensible by design.

---

## 3. Foundational constraints

Every shape downstream is the consequence of one of these. They are immovable.

### 3.1 Billing alignment (no metered API)

We drive `claude` (and similarly-licensed agents) under an interactive TTY so Anthropic's interactive-subscription billing applies. This eliminates:

- The Anthropic SDK / `--print` mode.
- The Agent SDK's `--input-format stream-json --output-format stream-json` mode.
- Any path where `CLAUDE_CODE_ENTRYPOINT` is set to a non-interactive value.

This forces: hidden PTY, full TUI keep-alive, structured-event reconstruction from hooks + transcripts + minimal TUI scraping rather than first-class JSON streaming.

### 3.2 No visible terminal

Users see a SwiftUI app, never a terminal. SwiftTerm is used as a *headless* VT-510 engine (state, snapshots, DSR/DA reply generation) — never as a `TerminalView`. This forces:

- `TerminalEngine` is an `actor` wrapping `SwiftTerm.Terminal` with no view layer.
- The screen is data; the UI is rendered from `AgentEvent`s, not from terminal cells.
- TUI parsing is a fallback signal source, never the primary one.

### 3.3 Swift 6.2 strict concurrency

All targets compile with `StrictConcurrency = complete`. No `nonisolated(unsafe)` outside C-bridge files. No global mutable state. Cross-actor data is `Sendable`. This forces:

- `actor` over class for state-bearing types.
- `@MainActor` lives at the UI seam only — not inside the engine.
- Domain `AgentEvent` (Foundation types) and wire `AgentEventWire` (Codable DTOs) are separate; conversion at the network boundary.

### 3.4 Headless-first

The engine must run identically inside the GUI app and inside a no-SwiftUI daemon binary. This forces:

- `AgentEngine` is a plain `actor`, never `@MainActor`.
- `AgentCore` and `ClaudeCode` import zero SwiftUI / AppKit / UIKit.
- Every UI interaction routes through `AgentEngineCommandPort.send(_:)` — there is no UI-only fast path.
- A CI job greps the daemon binary's symbol table for SwiftUI symbols; if any appear, the build fails.

### 3.5 Adapter-pluggable

Adding `Codex` / `Cursor CLI` / `Gemini CLI` / `OpenCode` / `Copilot` must be a sibling target conforming to `AgentAdapter` — no edits to `AgentCore`, `AgentUI`, or `AgentProtocol`. This forces:

- All Claude-specific knowledge is quarantined in `AgenticCLIs/ClaudeCode` (`ClaudeCode` target).
- `AgentAdapter` is a complete protocol covering binary discovery, env, auth, event sourcing, encoding user input, encoding permission responses, slash commands, session listing, and tool render hints.
- `AgentCapabilities` is an OptionSet that lets adapters declare which signal sources they use.

### 3.6 Remote-controllable

A future iOS client must speak the same protocol as the Mac UI. This forces:

- A pure-Foundation `AgentProtocol` target with `AgentCommand`, `AgentEventWire`, frame envelopes — no platform imports.
- The Mac UI uses the same `AgentEngineCommandPort` the remote client does; tests guarantee parity.
- `MulticastEventBus` fans out to N subscribers, with ring-buffer replay for reconnects.

### 3.7 Sandbox disabled, hardened runtime enabled

We spawn child processes, open PTYs, traverse the user's home directory, and watch arbitrary paths via FSEvents. App Sandbox is therefore off; Hardened Runtime stays on (we don't load third-party dylibs, so no `com.apple.security.cs.*` exemptions are needed). The CI checks `Codemixer.app/Contents/Info.plist` to assert the sandbox key is absent.

---

## 4. The two-mode product

Codemixer has two deployment shapes, both built from the same `Codemixer` package:

```
┌──────────────────────────────────────────────────────────────────────┐
│  Mode A: GUI in-process (default for solo desktop use)               │
│                                                                      │
│   Codemixer.app  ─→  AgentEngine (actor, in-process)                │
│                       │                                              │
│                       └─→  ClaudeCode (`ClaudeAdapter`), PTY, transcript, hooks    │
│                                                                      │
│   AgentRemoteControl (optional, off by default) ─→ WebSocket on :8421  │
└──────────────────────────────────────────────────────────────────────┘
```

```
┌──────────────────────────────────────────────────────────────────────┐
│  Mode B: Daemon + GUI (background sessions, multi-client)            │
│                                                                      │
│   codemixerd  ─→  AgentEngine (actor, headless)                      │
│                    │                                                 │
│                    └─→  AgentRemoteControl ─→ WebSocket on :8421       │
│                         HTTP sidecar on :8422 (health, attachments)    │
│                                                                      │
│   Codemixer.app  ─→  loopback WebSocket client of codemixerd         │
│                                                                      │
│   iPhone Codemixer Remote  ─→  LAN WebSocket client of codemixerd    │
└──────────────────────────────────────────────────────────────────────┘
```

In Mode B, the Mac GUI is *just another remote client* talking over loopback (the same wire format the phone uses). This is the design's load-bearing decision: there is no "GUI fast path." Both modes use the same engine, the same wire protocol, the same command port, the same fan-out bus.

The user opts into Mode B via **Settings → Remote → Enable on login**, which writes a LaunchAgent plist. Until then, Mode A is the default and the daemon is dormant.

---

## 5. SPM module map

The package `Codemixer` ships seven library targets, one C target, and eight test targets. `src/CodemixerApp/Codemixer.xcodeproj` adds a thin GUI app target (`Codemixer.app`); the daemon builds via SPM only.

```
Package.swift                          # SPM manifest (repo root)
src/
├── Core/                      # agent-agnostic engine + portable wire protocol + POSIX shim
│   ├── CPosixBridge/          # C shim: openpty, posix_spawn helpers
│   ├── AgentProtocol/         # [Portable Swift] wire types only
│   └── AgentCore/             # generic engine, PTY, terminal, bus
├── AgenticCLIs/               # agent CLI adapters — see AgenticCLIs/README.md
│   └── ClaudeCode/            # Adapter/, Common/, digital-twin/, contract README
├── Remote/                    # headless daemon + WebSocket remote-control library
│   ├── AgentRemoteControl/    # [macOS] TLS WSS server, pairing
│   └── CodemixerDaemon/       # headless daemon executable sources
├── AgentUI/                   # SwiftUI; depends on AgentCore only
├── CodemixerApp/              # GUI app sources + Project.swift + Codemixer.xcodeproj
tests/
├── TestSupport/
│   ├── AgentTestSupport/      # MockAdapter, deterministic fakes (test-only library target)
│   └── AgentTestSupportTests/
├── Core/
│   ├── AgentProtocolTests/
│   └── AgentCoreTests/
├── Remote/
│   ├── AgentRemoteControlTests/
│   └── RemoteParityTests/     # guards Mac-UI ↔ wire codec parity
├── AgenticCLIs/               # per-agent adapter + twin suites — see tests/AgenticCLIs/README.md
│   └── ClaudeCode/
│       ├── ClaudeAdapterTests/
│       └── ClaudeCodeTwinTests/
├── AgentUITests/
```

### Target descriptions

| Target | Platform | Imports | Concern |
| --- | --- | --- | --- |
| `CPosixBridge` | [macOS] (C99) | — | `openpty`, `posix_spawn` file-actions, `set_winsize`, `killpg`. Pure C; zero Swift between fork-equivalent boundary and `execve`. |
| `AgentProtocol` | [Portable Swift] | Foundation | `AgentCommand`, `AgentEventWire`, `ClientFrame` / `ServerFrame`, `AttachmentRef`, `PermissionDecision`, `StopReason`, prefs DTOs. No platform imports — compiles on macOS, iOS, Linux. |
| `AgentCore` | [Apple cross-platform] | `CPosixBridge`, `AgentProtocol`, `SwiftTerm` | The engine. PTY, spawner, reaper, env resolver, terminal engine, hook UDS server, FSEvents watcher, git diff, `AgentAdapter` protocol, `AgentEvent`, `AgentEngine`, `MulticastEventBus`, `HeartbeatActivityMonitor`, `StatusPhraseResolver`, `Seams/{Clock,RandomSource,Environment,FileSystem}`. No SwiftUI. |
| `ClaudeCode` | [Apple cross-platform] | `AgentCore`, `AgentProtocol` | Claude-specific integration: binary discovery, hooks, transcript JSONL, TUI fallback, shared path/input helpers, and the `ClaudeCodeTwin` digital twin. |
| `AgentRemoteControl` | [macOS] | `AgentCore`, `AgentProtocol`, Network, CryptoKit | `RemoteControlServer` (TLS NWListener), `PairingService`, `BonjourAdvertiser`, attachment HTTP staging, bearer-token store in Keychain. |
| `AgentUI` | [Apple cross-platform] | `AgentCore` | SwiftUI views and view-models. Imports `AgentCore` only. The `@MainActor` boundary lives here. |
| `AgentTestSupport` | [Portable Swift] | `AgentCore`, `AgentProtocol` | `MockAdapter`, deterministic `Clock` / `RandomSource` / `Environment` / `FileSystem` fakes, fixture loaders. Reusable in any test target. |

### Test targets

| Target | Path | Concern |
| --- | --- | --- |
| `AgentProtocolTests` | `tests/Core/AgentProtocolTests/` | Wire frames, prefs/decisions `Codable`. |
| `AgentCoreTests` | `tests/Core/AgentCoreTests/` | Engine, PTY, bus, git, hooks, persistence, seams. |
| `ClaudeAdapterTests` | `tests/AgenticCLIs/ClaudeCode/ClaudeAdapterTests/` | Hook decode, transcript, TUI fallback, slash commands. |
| `ClaudeCodeTwinTests` | `tests/AgenticCLIs/ClaudeCode/ClaudeCodeTwinTests/` | Digital-twin contract + engine E2E. |
| `AgentRemoteControlTests` | `tests/Remote/AgentRemoteControlTests/` | Pairing, TLS, sidecar, Bonjour, remote client, E2E. |
| `RemoteParityTests` | `tests/Remote/RemoteParityTests/` | Wire codec + command-dispatch parity canary. |
| `AgentUITests` | `tests/AgentUITests/` | View-model reduction, interaction coverage, voice/export. |
| `AgentTestSupportTests` | `tests/TestSupport/AgentTestSupportTests/` | Smoke tests for shared fakes (`FakeClock`, etc.). |

### Executable targets

| Target | Imports | Concern |
| --- | --- | --- |
| `Codemixer.app` | `AgentUI`, `AgentRemoteControl`, `ClaudeCode` | The GUI. Registers `ClaudeAdapter()` at startup. |
| `codemixerd` | `AgentCore`, `AgentRemoteControl`, `ClaudeCode` | The daemon. **Does not** link `AgentUI`. CI greps the binary symbols to enforce this. |
| `fake-claude` | `AgenticCLIs/ClaudeCode/digital-twin/fake-claude` | Minimal CLI twin for CI and local development without a real Claude login. |

### Hard import rules (lint-enforced)

- `AgentProtocol` may import only Foundation. No SwiftUI, no Network, no FSEvents, no AppKit.
- `AgentCore` may not import SwiftUI, AppKit, or UIKit.
- `ClaudeCode` may not import SwiftUI, AppKit, or UIKit.
- `AgentRemoteControl` may not import SwiftUI, AppKit, or UIKit.
- `AgentUI` may not import `ClaudeCode` or `AgentRemoteControl` — it imports `AgentCore` only.
- `codemixerd` may not link `AgentUI`. CI fails the build if it does.

These rules are checked by a SwiftLint custom rule plus a grep over each target's source set, run on every PR.

---

## 6. Layering and the dependency arrow

The dependency arrow points one way: from concrete to abstract, from outer to inner, from platform to portable.

```
              ┌──────────────────────┐
              │   Codemixer.app      │     ← UI shell, registration
              └──────────┬───────────┘
                         ▼
              ┌──────────────────────┐
              │      AgentUI         │     ← SwiftUI surface
              └──────────┬───────────┘
                         ▼
              ┌──────────────────────┐
   ┌──────────┤      AgentCore       ├──────────┐
   │          └──────────┬───────────┘          │
   ▼                     ▼                      ▼
┌──────────┐  ┌──────────────────────┐  ┌──────────────────┐
│ Adapter  │  │   AgentRemoteControl │  │ AgentTestSupport │
│ (Claude  │  │   (macOS-only)       │  │                  │
│  …)      │  │                      │  │                  │
└────┬─────┘  └──────────┬───────────┘  └──────────────────┘
     ▼                   ▼
┌──────────────────────────────────┐
│      AgentProtocol               │     ← portable wire types
└──────────────────────────────────┘
     ▼
┌──────────────────────────────────┐
│  CPosixBridge / Foundation       │     ← the metal
└──────────────────────────────────┘
```

Rules of the arrow:

- **No module imports above it.** `AgentCore` cannot import `AgentUI`. `ClaudeCode` cannot import `AgentUI` or `AgentRemoteControl`. `AgentProtocol` cannot import anything platform-specific.
- **Cross-imports at the same layer are forbidden.** `ClaudeCode` and `AgentRemoteControl` never import each other. They both depend down on `AgentCore`; they communicate through `AgentEvent` / `AgentCommand`.
- **The boundary between domain and wire is explicit.** `AgentCore` speaks `AgentEvent` (Foundation types like `URL`, `Date`); `AgentProtocol` speaks `AgentEventWire` (Codable, string-encoded). `WireCodec` is the only place that converts.

A picture every contributor should be able to draw from memory.

---

## 7. Concurrency model

Codemixer is built on Swift 6.2 strict concurrency. The four isolation domains:

| Domain | Examples | Notes |
| --- | --- | --- |
| **Plain actor** | `AgentEngine`, `MulticastEventBus`, `PTYHost`, `TerminalEngine`, `HookServer`, `GitDiffEngine`, `HeartbeatActivityMonitor`, `StatusPhraseResolver`, `SessionStore` | All engine-side state. Run identically in GUI and daemon. Never `@MainActor`. |
| **`@MainActor`** | `EngineViewModel`, every SwiftUI `View`, `ConversationViewModel`, `DiffPanelViewModel`, `ComposerModel`, `Speech` recognizers | UI thread only. Bridges the bus by `Task { for await ev in bus.subscribe() { applyOnMain(ev) } }`. |
| **Global concurrent (cooperative)** | `Task` for one-shot work (env resolution, login URL opening) | No long-lived loops; loops belong inside actors. |
| **`@unchecked Sendable` bridges** | `TerminalDelegate` shim around `SwiftTerm.Terminal`'s callback API; FSEvents callback shim; DispatchIO callback shim | Quarantined to specific files; documented invariants. Reviewed line-by-line. |

### Crossing isolation

- **Engine → UI**: the engine publishes onto `MulticastEventBus`; the UI subscribes via an `AsyncStream<AgentEvent>` and applies on `@MainActor`. There is no direct method call into UI code.
- **UI → Engine**: every user action constructs an `AgentCommand` and calls `await engine.send(_:)` through `AgentEngineCommandPort`. There is no direct method call into engine internals.
- **Engine → Adapter**: the engine awaits the adapter's `makeEventStream(inputs:)` — an `AsyncStream<AgentEvent>`. The adapter is `Sendable`; its closure may run on any executor.
- **Adapter → Engine**: adapters do not call back into the engine. They emit events; the engine ingests them.

### Sendable boundaries

- All public types in `AgentProtocol` are `Sendable`.
- All public types in `AgentCore` that cross actor boundaries (`AgentEvent`, `AgentCommand`, `AgentCapabilities`, `LaunchContext`, `PermissionPrompt`, `ToolInput`, `ToolOutput`) are `Sendable`.
- `URL`, `UUID`, `Date`, `Duration` are inherently `Sendable`.
- Where SwiftTerm types must cross, we wrap them in actor-isolated `Snapshot` value types — never expose `SwiftTerm.Terminal` directly.

### The `@MainActor` rule

The only `@MainActor`-tagged types in the entire SPM kit are inside `AgentUI`. Outside `AgentUI`, `@MainActor` is forbidden. This is checked at PR time by grepping for `@MainActor` outside `src/AgentUI/`.

---

## 8. The event-sourced core

Codemixer's core data flow is **event sourced**. Every observable thing is an `AgentEvent`; every UI surface (and every remote client) derives its state by folding the event stream. There is no second source of truth.

### The `AgentEvent` grammar

```swift
public enum AgentEvent: Sendable {
    case sessionStarted(sessionID: String, model: String?, cwd: URL)
    case userTurn(id: String, text: String)
    case textDelta(messageID: UUID, delta: String)
    case assistantText(id: String, blockID: String, text: String, isFinal: Bool)
    case thinkingChunk(blockID: UUID, delta: String)
    case thinkingComplete(blockID: UUID, duration: Duration)
    case toolStart(id: String, name: String, input: ToolInput, startedAt: Date)
    case toolProgress(callID: UUID, progress: ToolProgress)
    case toolEnd(id: String, success: Bool, output: ToolOutput, durationMS: Int)
    case permissionRequest(prompt: PermissionPrompt)
    case permissionAlreadyResolved(id: UUID, byDevice: String)
    case statusPhraseChanged(source: StatusPhraseSource, phrase: String)
    case activityStateChanged(ActivitySubstate)
    case noEventGap(turnID: UUID, elapsed: Duration)
    case authURL(URL)
    case bell
    case fileTouched(URL, kind: FileChangeKind)
    case usage(tokens: Int, costUSD: Double?)
    case engineRestarted
    case stopped(reason: StopReason)
    case error(AgentError)
}
```

### Five categorical roles

| Role | Cases |
| --- | --- |
| **Session lifecycle** | `sessionStarted`, `engineRestarted`, `stopped`, `error` |
| **Conversation** | `userTurn`, `textDelta`, `assistantText`, `thinkingChunk`, `thinkingComplete` |
| **Tool execution** | `toolStart`, `toolProgress`, `toolEnd` |
| **Permissions** | `permissionRequest`, `permissionAlreadyResolved` |
| **Activity & ambient** | `statusPhraseChanged`, `activityStateChanged`, `noEventGap`, `authURL`, `bell`, `fileTouched`, `usage` |

A consumer that knows nothing else can render a complete conversation by folding these events. New event cases require: (a) wire DTO in `AgentEventWire`, (b) `WireCodec` round-trip, (c) `RemoteParityTests` coverage, (d) a UI consumer or an explicit decision that none is wanted.

### Event identity and replay

- Every event carries a UUID at the wire boundary (`AgentEventWire.id`). Generated by the engine on publish.
- The bus's ring buffer (500 events) is keyed by these UUIDs.
- Remote clients send `lastSeenEventID` on subscribe; the bus replays everything after it.
- Replays are *idempotent at the consumer*: each consumer must tolerate seeing the same event twice (it does, because the consumer's state is derived from a fold).

### Domain vs wire

- `AgentEvent` lives in `AgentCore`. It uses Foundation types directly (`URL`, `Date`, `Duration`).
- `AgentEventWire` lives in `AgentProtocol`. It's a `Codable` mirror with string-encoded URLs, ISO-8601 dates, and millisecond `Duration`.
- `WireCodec.encode(_:) -> AgentEventWire` / `WireCodec.decode(_:) -> AgentEvent` is the only conversion site.
- `RemoteParityTests` verifies every case round-trips losslessly via a property test.

---

## 9. The PTY pipeline

Underneath every adapter is the same byte pipeline.

```
┌────────────┐    posix_spawn (no Swift between fork-equivalent and exec)
│ AgentCore  │  ─────────────────────────────────────────────────────────
│ spawn      │    child = openpty slave; SETSID + CLOEXEC_DEFAULT
└─────┬──────┘                       │
      │                              ▼
      │                       ┌──────────────┐
      │   PTY master FD       │  child       │
      │  ◀───────  bytes ─────│  (claude…)   │
      │   bytes  ─────▶       │              │
      │                       └──────────────┘
      ▼
┌────────────────────────────┐
│ PTYHost (actor)            │      DispatchIO read channel; serial write queue
│  • outboundBytes: AsyncStream<Data>
│  • write(_ bytes: Data)
│  • resize(rows:cols:)       │      ioctl(TIOCSWINSZ) → kernel emits SIGWINCH
└──────┬──────────────────────┘
       │
       ▼
┌────────────────────────────┐
│ AgentEngine inline fan-out │      one PTY byte stream → terminal + adapter
└──────┬──────────────────────┘
       │
       ├──────────────► TerminalEngine (actor)  → outboundReplies → back to PTYHost.write
       │                  (DSR, DA, CPR, XTVERSION, mouse, focus)
       │
       └──────────────► adapter.makeEventStream(inputs:)
                          • hookSocket
                          • screen snapshot
                          • transcript tailer (adapter-internal)
```

### Process spawn invariants

- **Zero Swift code between `posix_spawn` and `execve`.** We use the system's `posix_spawn` with file actions built in C (`CPosixBridge.agent_posix_spawn`). The Swift runtime is fork-unsafe; we avoid the issue entirely.
- **`POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT`.** New session, all parent FDs closed by default, child only inherits what we explicitly `addopen`.
- **The slave PTY is opened without `O_NOCTTY`.** The kernel grabs it as the controlling TTY for the new session leader. This is how interactive billing stays aligned.
- **The child sees its own process group**, so we can `killpg(-pgid, SIGTERM)` to take down `claude` and any subprocesses it spawns cleanly.

### PTYHost shape

```swift
protocol AgentPTY: Sendable {
    var outboundBytes: AsyncStream<Data> { get }
    func write(_ bytes: Data) async throws
    func interrupt() async
    func close() async
}

public actor PTYHost: AgentPTY {
    public let outboundBytes: AsyncStream<Data>   // bytes from child stdout/stderr
    public func write(_ bytes: Data) async throws
    public func resize(rows: Int, cols: Int) throws
    public func interrupt()                       // killpg(SIGINT)
    public func close() async
}
```

- Default window 120×40, **fixed across UI resizes** so the TUI fallback parser sees a stable layout.
- Reads use `DispatchIO` stream channel; writes go through a serial dispatch queue inside the actor.
- `FD_CLOEXEC` is set on the master immediately after `openpty`.
- `AgentPTY` is an internal engine seam, not a plugin API. Production always
  constructs `PTYHost`; tests inject scripted PTYs to deterministically force
  write failures, verify exact bytes, and prove event ordering without racing a
  real child process.
- The seam is intentionally minimal: outbound bytes, `write`, `interrupt`, and
  `close`. Spawn, resize, fd ownership, process groups, and reaping stay owned
  by `PTYHost` so the test seam cannot become a second production pty stack.

### TerminalEngine shape

```swift
actor TerminalEngine: TerminalSnapshotting {
    let outboundReplies: AsyncStream<Data>   // DSR/CPR/XTVERSION/mouse/focus replies
    func feed(_ bytes: Data)
    func resize(cols: Int, rows: Int)
    func snapshot() -> Snapshot               // Sendable value type
    let damaged: AsyncStream<DamageRange>     // emitted on DEC-2026 sync-output end OR 16ms debounce
}
```

- `@preconcurrency import SwiftTerm`.
- A `TerminalDelegate` shim is `@unchecked Sendable` and forwards `send(source:data:)` to `outboundReplies`. The engine plumbs those replies back into `PTYHost.write` — **without this Ink/Claude hangs on DA1/DA2/DSR/XTVERSION probes**.
- The engine is *engine-only*; there is no view. Snapshots are value types.

### Cleanup

- **`ChildReaper`** installs `SIG_IGN` on `SIGCHLD` early, then a `DispatchSource.makeSignalSource(.signal, SIGCHLD)` that `waitpid(-1, WNOHANG)` in a loop. Emits `.exited(pid, status)` events.
- **Graceful shutdown** is `killpg(SIGTERM) → 2s grace → killpg(SIGKILL) → waitpid → close PTY`. The reaper guarantees zombies don't accumulate.

---

## 10. Event source priority

The engine fuses up to four signal sources into one canonical event stream. The priorities are deterministic:

1. **Hooks (UDS, injected via `--settings`)** — ground truth for tool lifecycle: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, `SubagentStop`, `PreCompact`. Claude's contract is documented at `code.claude.com/docs/en/hooks`; the JSON payload is the most stable signal we have. Adapters that don't support hooks declare a different capability set.

2. **Transcript JSONL tailer** — canonical assistant message text, thinking blocks, and tool args / results, written by the agent itself. For Claude this is `~/.claude/projects/<slug>/<id>.jsonl`. Tailed with `lseek`+poll, not FSEvents (more responsive on writes-to-end-of-file).

3. **FSEvents on workspace** — covers any file change outside hook coverage (manual edits during a run, sibling tools, untracked tools). Drives the diff panel; never the conversation surface.

4. **TUI secondary parser** (SwiftTerm headless snapshots) — narrow scope only:
   - Live status phrase ("Pondering…", spinners) for `StatusPhraseResolver`.
   - Edge-case permission prompts the adapter didn't catch via hooks.
   - Diagnostic fallback when other sources miss an event.
   **Never** used for assistant chat text or tool arguments. This collapses the highest risk in v1.

### Why priority matters

If hooks say *"PostToolUse(Edit) at t=42"* and the transcript also yields *"tool_use result at t=42"*, the engine de-dupes by `(toolCallID, kind)` — emitting one `toolEnd` event. The hook always wins on lifecycle timing; the transcript fills in payload details the hook elided.

### Where the fusion happens

Inside the adapter's `makeEventStream(inputs:)`. The engine does **not** fuse; it merely consumes the merged stream. This keeps Claude-specific reconciliation logic out of `AgentCore`.

---

## 11. `AgentAdapter` — the agent extension point

Every CLI agent is integrated through a single protocol. The complete contract:

```swift
public protocol AgentAdapter: Sendable {
    // 1. Identity
    var id: AgentID { get }
    var displayName: String { get }
    var iconSymbol: String { get }

    // 2. Discovery & launch
    func locateBinary(env: ResolvedEnvironment) async throws -> URL
    func defaultEnvOverrides() -> [String: String]
    func buildLaunchArgv(context: LaunchContext) -> [String]

    // 3. Authentication
    func authStatus(env: ResolvedEnvironment) async -> AuthStatus
    func authURLPattern() -> NSRegularExpression?
    func loginCommandArgv() -> [String]?

    // 4. Event sources
    var capabilities: AgentCapabilities { get }

    // 5. Event ingestion
    func makeEventStream(inputs: AgentInputs) -> AsyncStream<AgentEvent>

    // 6. Sending input
    func encodeUserPrompt(_ text: String) -> Data
    func cancelSequence() -> Data

    // 7. Permission responses
    func encodePermissionResponse(_ decision: PermissionDecision,
                                  for prompt: PermissionPrompt) -> PermissionResponseDelivery

    // 8. Slash commands
    var slashCommandCatalog: [SlashCommand] { get }
    func enumerateProjectCommands(workspace: URL) async -> [SlashCommand]

    // 9. Resume / session listing
    func listResumableSessions(workspace: URL) async -> [SessionSummary]
    func resumeArgvAddition(sessionId: String) -> [String]

    // 10. Tool rendering hints
    func toolRenderHint(toolName: String, input: AgentEvent.ToolInput) -> ToolRenderHint
}
```

### `AgentCapabilities`

```swift
public struct AgentCapabilities: OptionSet, Sendable {
    public static let hooksOverUDS         = AgentCapabilities(rawValue: 1 << 0)
    public static let transcriptJSONL      = AgentCapabilities(rawValue: 1 << 1)
    public static let streamJSONStdio      = AgentCapabilities(rawValue: 1 << 2)
    public static let ptyTUIFallback       = AgentCapabilities(rawValue: 1 << 3)
    public static let permissionPrompts    = AgentCapabilities(rawValue: 1 << 5)
    public static let resumableSessions    = AgentCapabilities(rawValue: 1 << 6)
}
```

The engine reads `capabilities` and wires up only what's needed:

- `.hooksOverUDS` → start `HookServer`, plumb the socket into `AgentInputs`.
- `.transcriptJSONL` → adapter is responsible for tailing; engine just provides `sessionID` hot stream.
- `.ptyTUIFallback` → adapter consumes `inputs.screen` snapshots.
- `.permissionPrompts` → `PermissionResponseDelivery` is honored.
- `.resumableSessions` → enables the *Sessions* picker.

### `PermissionResponseDelivery`

A response can travel two channels — back into the PTY (the agent's TUI permission prompt) or as JSON stdout to the hook process (Claude's hook-driven `Notification` flow). The adapter chooses; the engine writes.

```swift
public enum PermissionResponseDelivery: Sendable {
    case writePTY(Data)
    case respondToHookProcess(jsonStdout: Data)
    case both(ptyBytes: Data, hookStdout: Data)
}
```

### `AdapterRegistry`

```swift
public actor AdapterRegistry {
    public static let shared = AdapterRegistry()
    public func register(_ adapter: any AgentAdapter)
    public func all() -> [any AgentAdapter]
    public func adapter(for id: AgentID) -> (any AgentAdapter)?
}
```

The GUI registers `ClaudeAdapter()` at startup. New adapters scaffold under `src/AgenticCLIs/<AgentName>/` (see `src/AgenticCLIs/README.md`), ship as their own SPM library target, and register with one `register` call; UI affordances should keep resolving adapters through `AdapterRegistry` rather than importing adapter targets.

---

## 12. `AgentCommand` — the input alphabet

The engine has exactly one input port: `AgentEngineCommandPort.send(_ command: AgentCommand) async throws`. There is no UI-only fast path; every action — local or remote — constructs a typed command.

```swift
public enum AgentCommand: Codable, Sendable {
    case sendPrompt(text: String, attachments: [AttachmentRef])
    case cancelCurrentTurn
    case editAndResubmitLast(target: UUID, text: String, attachments: [AttachmentRef])
    case respondToPermission(id: UUID, decision: PermissionDecision)
    case respondToInlinePrompt(promptID: UUID, text: String)
    case newSession
    case compact
    case selectModel(id: String)
    case setPermissionMode(PermissionMode)
    case toggleThinkMode(Bool)
    case toggleReviewMode(Bool)
    case runSlashCommand(name: String, args: [String])
    case runCustomCommand(path: String, args: [String])
    case openProject(URL)
    case closeSession
    case speakAssistantBubble(id: String)
    case revertFile(URL)
    case revertHunk(URL, hunkID: UUID)
    case updateAutoApprovalRules([AutoApprovalRule])
    case updateAppearancePref(key: AppearancePrefKey, value: AppearancePrefValue)
    case requestSnapshot(SnapshotKind)
}
```

### Three command-shape categories

| Category | Examples | Engine response |
| --- | --- | --- |
| **Agent input** | `sendPrompt`, `cancelCurrentTurn`, `editAndResubmitLast`, `runSlashCommand` | Translated to PTY bytes via `adapter.encodeUserPrompt(_:)` / `adapter.cancelSequence()`. |
| **Engine state** | `newSession`, `selectModel`, `setPermissionMode`, `toggleThinkMode` | Translated to slash-command lines, then written to PTY. |
| **Out-of-band** | `revertFile`, `updateAutoApprovalRules`, `updateAppearancePref`, `requestSnapshot`, `speakAssistantBubble` | Handled by a higher-level service layer (`GitDiffEngine`, `SessionStore`, TTS). The engine returns immediately. |

The third category may sound like a violation of the single-port discipline — it isn't. The *port* is still single; the engine is a tiny router that fans out to subsystems for non-agent commands. The wire protocol remains uniform; the mobile client sends `updateAppearancePref` the same way it sends `sendPrompt`.

### Why command-based UI?

- **Parity.** Mac UI ↔ remote client wire compatibility is a property test (`RemoteParityTests`).
- **Auditability.** Every state change is observable as a command in the daemon log.
- **Headless symmetry.** The daemon has no UI; commands are the only way in.

---

## 13. `AgentEngine` — the orchestrator

`AgentEngine` is the actor that owns the running session.

### Lifecycle

```text
init(seams: Seams = .live)
  ↓
start(adapter:, workspace:, resumeSessionID:, permissionMode:)
  ↓
  • ShellEnvironmentResolver.resolve()
  • adapter.locateBinary(env:)
  • if .hooksOverUDS ∈ capabilities: HookServer.start()
  • argv = adapter.buildLaunchArgv(context: LaunchContext)
  • ptyFactory(ChildSpec(executable:, arguments:, environment:, cwd:))
    - production factory constructs PTYHost
    - tests may inject scripted AgentPTY implementations
  • TerminalEngine() — wired to pty.outboundBytes
  • adapter.makeEventStream(inputs:) → consume on a Task → ingest(_)
  • HeartbeatActivityMonitor — drives noEventGap + activityStateChanged
  • state = .running(sessionID: nil)
  ↓
send(_ command: AgentCommand) async throws
  ↓
shutdown(reason:)
  ↓
  • cancel forwarding task
  • close PTY (killpg(SIGTERM) → 2s grace → SIGKILL → waitpid)
  • stop HookServer
  • stop FSEventsWatcher
  • drain MulticastEventBus
  • publish .stopped(reason:)
  • state = .stopped
```

### Internal state

```swift
public actor AgentEngine: AgentEngineCommandPort {
    public let bus: MulticastEventBus
    private var adapter: (any AgentAdapter)?
    private var state: EngineState
    private var pty: (any AgentPTY)?
    private var terminal: TerminalEngine?
    private var hookServer: HookServer?
    private var fsWatcher: FSEventsWatcher?
    private var currentSessionID: String?
    private var currentTurnID: UUID?
    private var pendingPermissions: [UUID: PermissionPrompt]
    private var lastUserBubbleID: UUID?
    private var heartbeat: HeartbeatActivityMonitor?
    private var phraseResolver: StatusPhraseResolver
}
```

### What the engine *does not* do

- Render anything.
- Speak Claude's hook JSON schema.
- Decide auto-approval policy (that's a higher service).
- Maintain conversation history (clients fold the bus stream themselves).

The engine is small on purpose. Most logic lives in adapters and clients.

---

## 14. `MulticastEventBus` — fan-out and replay

The bus is the engine's outbound port.

```swift
public actor MulticastEventBus {
    public func publish(_ event: AgentEvent) async
    public func subscribe() -> Subscription
    public func unsubscribe(_ subscription: Subscription)
    public func replay(since lastSeenEventID: UUID?) -> [AgentEvent]
}

public struct Subscription: Sendable {
    public let id: UUID
    public let stream: AsyncStream<AgentEvent>
}
```

### Properties

- **N subscribers.** In Mode B, the GUI is one subscriber, each remote client is another. No special-casing.
- **Per-subscriber bounded queue.** Default 1024 events. Drop-oldest on overflow with an `eventDropped` signal so the consumer knows to ask for a snapshot.
- **Ring buffer of last 500 events** for reconnect-with-replay. Keyed by event UUID. Replay returns events strictly after `lastSeenEventID`; `nil` means "from the start of the buffer."
- **No reordering.** Events are delivered in publish order to each subscriber.

### Backpressure model

Subscribers consume on their own schedule. If a remote phone over flaky Wi-Fi falls behind, its queue overflows independently — other subscribers are unaffected. When the phone reconnects with a stored `lastSeenEventID`, it gets the replay. If it fell behind by more than 500 events, the engine sends a `engineRestarted` synthetic event so the client knows to request a full snapshot via `requestSnapshot(.conversation)`.

### Multicast load test

`AgentCoreTests` runs N=50 simulated subscribers under bursty load (1000 events/sec for 5 seconds) and asserts that:

- Each subscriber receives every event published while it was subscribed.
- No subscriber's queue overflows under <600 events/sec aggregate fan-out.
- The ring buffer's UUID lookup is O(1) (backed by a hash map alongside the deque).

---

## 15. Activity indicators subsystem

The "agent feels alive between events" experience is implemented entirely server-side, in two cooperating actors.

### `HeartbeatActivityMonitor`

```swift
actor HeartbeatActivityMonitor {
    func startTurn(_ id: UUID, baseline: ActivitySubstate) async
    func bump(baseline: ActivitySubstate) async      // called on every event
    func endTurn() async
    // Emits noEventGap(turnID:, elapsed:) every 500ms while non-idle.
    // Emits activityStateChanged(_:) on substate transitions.
}
```

State machine:

```text
.idle ─(turn begins)─▶ .awaitingFirstChunk
                          │
                          │  ≥ 800ms  →  .working
                          │  ≥ 10s    →  .stalled
                          │  ≥ 90s    →  .suspectedHang
                          ▼
                    .streamingText / .thinking / .runningTool  (whichever event arrives)
                          │
                          └─(turn ends)─▶  .idle
```

Locked thresholds (800ms / 10s / 90s) live in `AgentCore` only — never replicated in clients. Clients merely consume `activityStateChanged(_:)` and react.

### `StatusPhraseResolver`

```swift
actor StatusPhraseResolver {
    func ingest(_ snapshot: TerminalEngine.Snapshot) async   // TUI hint
    func setActiveTool(_ name: String?) async
    func setThinkingPhrase(_ phrase: String?) async
    // Emits statusPhraseChanged(source:, phrase:) on change.
}
```

Priority (high → low):

1. Active tool name (`"Running Bash…"`).
2. Live thinking-block phrase from the transcript (`"Searching for prior art…"`).
3. TUI-parsed phrase from the SwiftTerm snapshot (`"Pondering…"`).
4. Default `"Working… (Ns)"` with elapsed seconds from the heartbeat.

Clients render the resolved phrase verbatim. They do not re-derive priority.

### Why server-side

If `noEventGap` / `activityStateChanged` were client-side, the GUI and the mobile remote would disagree about *when* the agent went stalled (different clocks, different jitter). Server-side resolution means every client sees the same activity state, the same Nth second, the same crossfade — guaranteed by the bus order. This is essential for multi-client coherence.

---

## 16. Dependency injection seams

Every non-deterministic dependency the engine touches has a protocol seam in `Core/AgentCore/Seams/` and a deterministic fake in `AgentTestSupport`. The four cross-engine seams:

```swift
public protocol AgentClock: Sendable {
    func now() -> Date
    func monotonic() -> ContinuousClock.Instant
    func sleep(for duration: Duration) async throws
}

public protocol RandomSource: Sendable {
    func next<T: FixedWidthInteger>(in range: Range<T>) -> T
    func uuid() -> UUID
}

public protocol Environment: Sendable {
    func value(for key: String) -> String?
    func snapshot() -> [String: String]
}

public protocol FileSystem: Sendable {
    func fileExists(at: URL) -> Bool
    func isDirectory(at: URL) -> Bool
    func createDirectory(at: URL, intermediates: Bool) throws
    func readData(from: URL) throws -> Data
    func writeAtomically(_ data: Data, to: URL) throws
    func remove(at: URL) throws
    func contentsOfDirectory(at: URL) throws -> [URL]
    func modificationDate(of: URL) throws -> Date
}
```

### Live vs fake

- `Core/AgentCore/Seams/SystemClock.swift`, `SystemRandom.swift`, `ProcessEnvironment.swift`, `SystemFileSystem.swift` — live implementations.
- `AgentTestSupport/FakeClock.swift`, `FakeRandom.swift`, `InMemoryEnvironment.swift`, `InMemoryFileSystem.swift` — deterministic doubles with seek / advance / preload APIs.

### Wired through `Seams`

A single value struct carries all four into the engine:

```swift
public struct Seams: Sendable {
    public var clock: any AgentClock
    public var random: any RandomSource
    public var environment: any Environment
    public var fileSystem: any FileSystem
    public static let live = Seams(clock: SystemClock(), random: SystemRandom(),
                                   environment: ProcessEnvironment(), fileSystem: SystemFileSystem())
}
```

Every actor that needs any of these takes a `Seams` (or the specific seam protocol) at init. **Direct calls to `Date()`, `Int.random`, `ProcessInfo.processInfo.environment`, or `FileManager.default` outside `Seams/Live*.swift` are forbidden by a custom SwiftLint rule.**

### Why this matters

Without seams, every async test of the heartbeat ticker would have to actually sleep 500ms. With seams, `FakeClock.advance(by: .seconds(10))` deterministically drives 20 heartbeats in a millisecond. The same applies to UUID generation in tests (predictable IDs), env resolution (no shell), and file IO (no disk).

`AgentPTY` is the one narrower, engine-local seam. It exists only to test PTY
write and close failures deterministically; it is injected through
`AgentEngine`'s internal test initializer and is not part of the adapter
extension surface.

---

## 17. State machine and turn lifecycle

`AgentState` is the engine-side reducer over `AgentEvent`. The states:

```swift
public enum AgentState: Sendable, Equatable {
    case bootstrapping
    case awaitingAuth(reason: AuthReason)
    case idle
    case userTurn(text: String)
    case thinking
    case runningTool(name: String, id: String, startedAt: Date)
    case awaitingPermission(prompt: PermissionPrompt)
    case errored(reason: String)
    case shutdown
}
```

### A canonical turn

```
.idle
  ↓  AgentCommand.sendPrompt
.userTurn(text:)
  ↓  AgentEvent.userTurn   (server-confirmed; client renders bubble)
.thinking
  ↓  AgentEvent.thinkingChunk*  (streams into a ThinkingBlock)
  ↓  AgentEvent.thinkingComplete(duration:)
.runningTool(name:, id:, startedAt:)  ← may iterate over several tools
  ↓  AgentEvent.toolStart, toolProgress*, toolEnd
.awaitingPermission(prompt:)            ← if a tool needs approval
  ↓  AgentCommand.respondToPermission(decision:)
.runningTool(...)
  ↓  AgentEvent.assistantText(isFinal: true)
.idle
```

### Reducers

`AgentEngine` and each client (Mac UI, mobile client) hold a reducer instance. The reducer is pure — `(AgentState, AgentEvent) → AgentState` — and lives in `AgentCore`. UIs derive their view models from the result, but the canonical state lives in the engine.

### Optimistic send + echo reconciliation

To keep sending instant, `EngineViewModel.sendPrompt` appends the user bubble and flips to a working state on the main actor *before* the engine round-trip, then reconciles when the real `.userTurn` arrives. Two subtleties make this safe:

- The engine publishes `.userTurn` + starts the heartbeat **before** the awaited PTY write, so every surface — GUI and remote clients — reflects the turn at the same instant rather than after the write + bus fan-out. A failed write still throws, so the caller surfaces the error. `AgentEngineCommandTests` pins the publish-before-write invariant with an injected failing PTY; `RemoteControlE2ETests` pins the wire-visible ordering (`.userTurn` event before the failing command result).
- Claude double-emits the turn (engine echo + the `UserPromptSubmit` hook). The view model arms a short dedup window (`ActivityTiming.userTurnEchoWindow`): the first matching echo adopts the engine's id onto the optimistic bubble; the second is dropped. If the send throws, the optimistic bubble rolls back and the status resets. Genuinely different turns always append.

### PTY write-failure contract

Every command that writes to the pty uses the same `AgentEngineCommandPort`
path whether it originated from SwiftUI, the daemon API, or a remote client.
The tested contract is:

- If command encoding succeeds, the engine attempts exactly the adapter-produced
  bytes at the `AgentPTY.write` boundary.
- If the write throws, `engine.send(_:)` throws the same error. Remote clients
  receive a failed `ServerFrame.result`; the UI command port rolls back any
  optimistic local state.
- `.sendPrompt` is the only write command that publishes a user-visible event
  before the write. That ordering is intentional and pinned: all subscribers
  see `.userTurn` before a write failure is reported.
- `.cancelCurrentTurn` writes the adapter cancel sequence first and calls
  `interrupt()` only after the write succeeds. A failed cancel write must not
  send SIGINT.
- `editAndResubmitLast` has two separate pty failure points: the pre-restart
  cancel write and the post-restart revised prompt write. Tests use a scripted
  pty factory so the restarted session receives a fresh pty.
- `respondToPermission` covers all adapter delivery modes:
  `.writePTY`, `.both`, and `.respondToHookProcess`. Hook-only delivery must
  not touch the pty; pty-backed delivery propagates pty write failures.

### Cancel paths

- `cancelCurrentTurn` → adapter's `cancelSequence()` written to PTY → adapter emits `toolEnd(success: false, output: .cancelled)` or `assistantText(isFinal: true, text: <partial>)` → state returns to `.idle`.
- App quit / engine `shutdown` → `engine.shutdown(reason: .userCancel)` → published `.stopped(reason:)` → state `.shutdown`.

---

## 18. Permissions subsystem

Permissions are the most multi-party flow in the system. Their architecture:

```
agent (TUI)
   │
   │ "Allow Bash to run `git push`?"
   ▼
hook (Notification or PreToolUse)  ───► HookServer  ───► adapter
                                                          │
                                                          │ AgentEvent.permissionRequest
                                                          ▼
                                                MulticastEventBus
                                                          │
                       ┌──────────────────────────────────┼───────────────────────────────┐
                       ▼                                  ▼                               ▼
              Mac UI (PermissionCard)         iPhone Codemixer Remote          (other subscribers)
                       │                                  │
                       └─── any one responds ─── AgentCommand.respondToPermission ────────┐
                                                                                          ▼
                                                                              engine.send(_:)
                                                                                          │
                                                                          adapter.encodePermissionResponse(_:for:)
                                                                                          │
                                              ┌──────────────────────────────────────┐    │
                                              │ .writePTY(bytes) → PTYHost.write     │    │
                                              │ .respondToHookProcess(jsonStdout) →  │    │
                                              │   HookServer writes to the hook's    │    │
                                              │   stdout connection                  │    │
                                              │ .both(…)                             │    │
                                              └──────────────────────────────────────┘    │
                                                                                          │
                                                              ┌───────────────────────────┘
                                                              ▼
                                           success → agent resumes
                                           failure → command throws / remote result fails
```

### Properties

- **First responder wins.** Multiple clients may show the same prompt; the engine accepts the first valid `respondToPermission(id:, decision:)` and drops further responses for the same prompt id because the prompt has already been removed from `pendingPermissions`.
- **Timeout cleanup.** If no client responds before `permissionTimeout`, the engine auto-denies and publishes `permissionAlreadyResolved(id, byDevice: "timeout")` so stale cards collapse consistently.
- **Auto-approval rules** are a higher-level service that consumes `permissionRequest` events and synthesizes `respondToPermission` commands; rules are user-editable per project.
- **Headless timeout.** With no client connected, the engine waits `permissionTimeout` (default 5 min) then synthesizes `.deny`.
- **Delivery modes are adapter-owned.** Some agents accept permission answers by pty bytes, some by hook stdout, and Claude can need both. The engine preserves adapter intent and propagates pty write failures for `.writePTY` and `.both`.
- **Stale-edit guard.** `editAndResubmitLast` requires the target bubble UUID to match `lastUserBubbleID`. If it doesn't (because another client already resubmitted), the engine throws `AgentError.staleEditTarget`.

---

## 19. Git diff subsystem

The diff panel is driven by two cooperating sources:

```
FSEventsWatcher  ──────────► (workspace path changes, .gitignore-filtered)
                                      │
                                      ▼
                              GitDiffEngine (actor)
                                      │
                                      │  on change: re-run
                                      │
                                      ▼
                              git status --porcelain=v1 -z
                              git diff --no-color --unified=3 -- <path>
                                      │
                                      ▼
                              [ChangedFile] + [DiffHunk]
                                      │
                                      ▼
                              published via AgentEvent.fileTouched + DiffPanelViewModel
                                      │
                                      ▼
                              Mac UI DiffPanelView
                              iPhone DiffPanelView (via wire)
```

### Properties

- All git invocations go through `agent_posix_spawn`, **never** through Swift's `Process`. Same fork-safety story as the agent itself.
- FSEvents triggers a 50ms-debounced re-scan. Debounce avoids storms during big `git checkout` operations.
- `.gitignore` filtering uses `git check-ignore --stdin`; one round-trip per batch.
- `revert(path:)` runs `git restore -- <path>`; `revertHunk(...)` writes a patch to stdin of `git apply -R --unidiff-zero`.
- The diff engine never reads or modifies files; only `git` does. This keeps the engine's blast radius tiny.

---

## 20. Persistence model

Codemixer persists almost nothing itself. The agent writes JSONL transcripts; the user's `.git` directory carries diff state; the system Keychain carries pairing secrets. The small remainder lives in:

```
~/Library/Application Support/com.codecave.Codemixer/
├── recent.json          # recent projects
├── sessions.json        # last session id per (agentID, projectURL)
├── workspaces.json      # per-workspace project list (navigator model)
├── prefs.json           # appearance, voice, permissions, remote, debug
└── auto-approval/<projectHash>.json
~/Library/Caches/Codemixer/uploads/<sessionID>/<uuid>   # 24h-TTL attachments
~/Library/LaunchAgents/com.codecave.Codemixer.daemon.plist  # if enabled
```

### `SessionStore`

```swift
public actor SessionStore {
    public init(fileSystem: any FileSystem, baseURL: URL)
    public func recentProjects() async -> [RecentProject]
    public func rememberProject(_ url: URL, lastSessionID: String?) async throws
    public func sessionID(for agent: AgentID, project: URL) async -> String?
    public func loadPrefs() async -> Prefs
    public func savePrefs(_ prefs: Prefs) async throws
}
```

### `WorkspaceProjectsStore`

The agent-agnostic model behind the GUI session navigator. A *workspace* is the loaded folder (one window); each workspace owns an ordered list of `ProjectRef`s (path, display name, optional `AgentID`). The workspace root is seeded as the default project; further projects are created as subfolders or added from anywhere on disk.

```swift
public actor WorkspaceProjectsStore {
    public func projects(for workspace: URL) async -> [ProjectRef]          // seeds root
    public func createProject(name:in:) async throws -> ProjectRef          // subfolder
    public func addExistingProject(url:in:) async throws -> ProjectRef      // any path
    public func renameProject(path:to:in:) async throws -> ProjectRef       // label only
    public func removeProject(path:in:) async throws -> RemovedProject?     // never the root
    public func restoreProject(_:in:) async throws                          // undo
}
```

It contains **no** Claude/terminal specifics — sessions are not modelled here; they flow through `AgentAdapter.listResumableSessions`, so the navigator works for direct-API/ACP agents (which simply declare no `.resumableSessions` capability and show *New Chat only*). Navigation actions in `EngineViewModel` (`newChat`, `openSession`) route through the wire `AgentCommand`s `.newSession` / `.openProject`, so the GUI, remote clients, and CLI all reach the same behavior. Sidebar visibility is GUI chrome persisted through `AppearancePrefs` (never on the wire, never `UserDefaults`).

### Atomic writes

Every persisted file uses the temp + `rename(2)` pattern in `SystemFileSystem.writeAtomically`. Power-loss or crash never leaves a half-written file.

### Schemas are versioned

Each file embeds a `"schemaVersion": Int`. Migration is forward-only; older Codemixer versions ignore unknown fields (`Codable` with `decodeIfPresent`); a higher version refuses to write a lower version.

---

## 21. Remote control architecture

`AgentRemoteControl` (macOS-only target) turns the engine into a network service.

### Topology

```
NWListener (WebSocket, :8421 — see RemoteDefaults.webSocketPort)
   │
   ├── WebSocket upgrade handler  (path: /v1/ws)
   │       │
   │       ▼
   │   ClientConnection (actor, one per client)
   │       │   ◀── inbound JSON frames ──── decode → AgentCommand → engine.send(_:)
   │       │   ──── outbound JSON frames ───▶ MulticastEventBus subscription → AgentEventWire
   │       │
   │       └── pairing handshake (PIN) or bearer-token auth
   │
HTTPSidecarServer (:8422 — see RemoteDefaults.sidecarPort)
   │
   ├── HTTP handler for POST /v1/attachments (multipart)
   │       │
   │       └── stage to ~/Library/Caches/Codemixer/uploads/<sessionID>/<uuid>
   │           return {ref: "attachment://<uuid>"}
   │
   └── GET /v1/health
           returns {version, engineState, clientCount, uptime}
```

### Wire frames

```swift
public enum ClientFrame: Codable, Sendable {
    case subscribe(lastSeenEventID: UUID?)
    case command(AgentCommand)
    case ping
}

public enum ServerFrame: Codable, Sendable {
    case event(AgentEventWire)
    case ack(commandID: UUID)
    case error(WireError)
    case pong
}

public let wireProtocolVersion: Int = 1   // bumped only on breaking changes
```

Every frame carries `"v": wireProtocolVersion` and a `correlationID` for command/ack pairing.

### Pairing

- **First-time pairing**: Mac UI shows a 6-digit PIN plus a QR (`codemixer://pair?host=...&port=...&fingerprint=<sha256>`). Phone scans, sends `{type: "pair", pin: "...", deviceName: "..."}`. Service verifies with constant-time compare, issues a bearer token (32 random bytes, base64), persists `{deviceName, tokenHash, createdAt, lastSeen}` in Keychain.
- **Lockout**: 5 wrong PIN attempts → 60-second timeout, doubled on each subsequent failure (60 → 120 → 240 → …).
- **TLS cert** is self-signed RSA-2048, valid 5 years, stored in Keychain with `kSecAttrAccessibleAfterFirstUnlock`. Fingerprint pinning on the client.

### Binding rules

- Default bind: loopback (`127.0.0.1`).
- LAN bind only when `Settings → Remote → Allow LAN connections` is on.
- Toggling the LAN switch rebinds the listener within 100ms (`NWListener.cancel` + new listener with new params).

### Bonjour

`_codemixer._tcp.local.` advertised when remote access is on, with `TXTRecord` `{v=1, device=<host>, pairingState=open|paired}`. Start / stop in lockstep with the listener.

### Multicast coherence and parity

The Mac UI in Mode B is *also* a WebSocket client (on loopback). The same wire codec, the same handshake. **`RemoteParityTests`** is the canary for protocol shape: generated `AgentEvent` streams round-trip through `WireCodec`, and every `AgentCommand` case dispatches through the remote server. **`AgentEngineCommandTests`** own exact PTY bytes and write-failure propagation at the engine seam. **`RemoteControlE2ETests`** then prove those failures surface as failed WebSocket command results, including stateful permission and edit-resubmit paths.

---

## 22. Headless daemon (`codemixerd`)

The daemon is a thin `@main` over `AgentEngine + AgentRemoteControl + ClaudeCode`.

### Properties

- **No SwiftUI.** CI greps the binary's symbol table for `SwiftUI.` — any match fails the build.
- **Idle exit.** With 0 connected clients and `AgentState == .idle` for 10 minutes, the daemon `_exit(0)`s. LaunchAgent's `KeepAlive = {SuccessfulExit: false}` won't restart it. Next GUI launch spawns it again via `launchctl bootstrap`.
- **Crash recovery.** `KeepAlive = {SuccessfulExit: false}` *does* restart on unexpected exits.
- **No GUI bleed.** The daemon never opens windows, never makes alerts, never calls `NSAlert`/`UNNotificationCenter` (notifications are the client's concern).

### Install / uninstall

- **Install**: `Settings → Remote → Enable on login` writes `~/Library/LaunchAgents/com.codecave.Codemixer.daemon.plist` and `launchctl bootstrap gui/$UID <plist>`. The GUI now connects via loopback.
- **Uninstall**: toggle off → `launchctl bootout gui/$UID/com.codecave.Codemixer.daemon` → remove the plist. GUI falls back to in-process Mode A.

### Loopback bridging

When the daemon is running and the GUI launches:

1. GUI's `EngineConnection` actor probes `GET http://127.0.0.1:8422/v1/health`.
2. If healthy, GUI opens a WebSocket connection to `ws://127.0.0.1:8421/v1/ws` (daemon default) or `wss://…` when TLS is enabled, sends `subscribe(lastSeenEventID: nil)`, and treats the daemon's engine as authoritative.
3. If unhealthy / not running and Mode A is the user's preference, GUI starts an in-process engine instead.

The user never sees the seam; the activity state, conversation, and pairing list are the same.

---

## 23. Security model

A native Mac app that spawns child processes, opens TTYs, watches arbitrary files, and exposes a network service requires care.

### App-level

- **App Sandbox disabled.** We spawn `claude` from arbitrary paths, attach to arbitrary working directories, run git on them. The sandbox cannot accommodate this.
- **Hardened Runtime enabled.** No `com.apple.security.cs.*` exemptions are needed because we do not load third-party dylibs.
- **TCC purpose strings**: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, `NSAppleEventsUsageDescription` (only if we ever script Finder; not in v1), `NSLocalNetworkUsageDescription` (when LAN bind is on).
- **Notarization** at release time via `xcrun notarytool`.

### Process spawning

- `posix_spawn` only — never `Process`, never `fork() + exec()` from Swift.
- `POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT` — child can't inherit our open file descriptors.
- `signal(SIGPIPE, SIG_IGN)` at startup so PTY closes don't kill us.

### Remote-control auth

- **PIN**: 6 random decimal digits from `SecRandomCopyBytes`. 90-second expiry. Constant-time compare via `CryptoKit.SymmetricKey.timingSafeCompare`.
- **Lockout**: 5 attempts → exponential backoff.
- **Bearer tokens**: 32 random bytes, base64-encoded, stored as SHA-256 hash in Keychain (we compare the hash, never the token). Per-device, revocable.
- **TLS certificate**: self-signed RSA-2048, 5-year validity, in Keychain with `kSecAttrAccessibleAfterFirstUnlock`. Fingerprint shown in the pairing QR for client-side pinning. TLS is controlled by `RemoteControlServer.Configuration.useTLS`: the GUI embedded server defaults to TLS on; `codemixerd` defaults to plain WebSocket on loopback for local development.
- **Port ownership**: `RemoteDefaults.webSocketPort` (8421) and `RemoteDefaults.sidecarPort` (8422) are the single source of truth — do not hardcode ports elsewhere.

### Logging

- `os.Logger` everywhere; prompt text and file paths are tagged `.private`, PIDs and durations are `.public`, errors are `.public` with the actionable line only. Console.app shows public fields; full payloads require a sysdiagnose.

### What we never do

- Store user prompts on disk outside the JSONL transcripts the agent itself writes.
- Send any telemetry of any kind.
- Embed an analytics SDK.
- Use third-party crash reporters.

---

## 24. Error model

Every layer defines a typed `Error` enum carrying rich context. Examples:

```swift
public enum PTYError: Error, Sendable {
    case openpty(errno: Int32)
    case nonBlocking(errno: Int32, fd: Int32)
    case spawn(errno: Int32, executable: URL)
    case write(errno: Int32, bytes: Int)
    case alreadyClosed
}

public enum AgentError: Error, Codable, Sendable {
    case binaryNotFound(agentID: AgentID, hint: String)
    case spawnFailed(errno: Int32, detail: String)
    case authenticationRequired(loginURL: URL?)
    case staleEditTarget(targetID: UUID)
    case permissionTimeout(promptID: UUID, action: PermissionDecision)
    case internalInvariant(detail: String)
    case adapter(domain: String, code: String, message: String)
}

public enum RemoteControlError: Error, Codable, Sendable {
    case tlsHandshake(detail: String)
    case unauthorized
    case pinExpired
    case lockedOut(retryAfter: Duration)
    case versionMismatch(server: Int, client: Int)
    case malformedFrame(detail: String)
    case sizeLimitExceeded(limit: Int)
}
```

### Rules

- **Errors are typed at the throwing site.** Swift 6.2 typed throws (`throws(PTYError)`) is used at function signatures that have a closed error set.
- **Errors that cross the wire are `Codable`.** Remote clients see the same case the engine raised, complete with associated values.
- **`localizedDescription`** is implemented per case with actionable phrasing — *"binary not found at /usr/local/bin/claude — install with `npm i -g @anthropic-ai/claude-code`"* — not opaque enum names.
- **No `fatalError` outside of `Logger.fatal` shims**, which assert in debug and `os_log_fault` in release.

---

## 25. Performance model

The engine is not bandwidth-bound; user perception is. Latency budgets:

| From → To | Budget | Mechanism |
| --- | --- | --- |
| User keystroke → composer character | < 16 ms | `@MainActor` direct binding |
| Send button → first PTY byte | < 30 ms | One `await pty.write` |
| First PTY byte → first transcript event | 100 – 1000 ms | Agent-bound; out of our control |
| Adapter event → bus publish | < 1 ms | Pure async stream |
| Bus publish → Mac UI render | < 16 ms | One hop through `EngineViewModel` |
| Bus publish → remote client byte on wire | < 5 ms | One WSS frame |
| PTY byte → diff panel refresh | ≤ 50 ms | FSEvents debounce |
| `cancelCurrentTurn` → child SIGTERM observed | < 100 ms | Direct `killpg` |
| Daemon idle → `_exit(0)` | 10 min | Idle timer |

### Throughput

- PTY read is `DispatchIO`-backed; tested to 4 MiB/s without backpressure.
- Bus fan-out is N-subscriber tested at 1000 events/sec × 50 subscribers without drops.
- Transcript tail is one `read(2)` per FSEvents tick; constant per-event cost.

### Memory caps

- Bus ring buffer: 500 events × ~2KB each ≈ 1 MB.
- Per-client outbound queue: 1024 events × ~2KB ≈ 2 MB / client. With 50 clients that's 100 MB; we cap simultaneous clients at 16 in v1.
- Transcript tail buffer: 64 KB rolling window.
- Snapshot ring inside `TerminalEngine`: 5 snapshots × 120×40 cells ≈ 240 KB.

### Reduce-Motion / low-power

When the system reports Reduce Motion or low-power mode, ShimmerDots become static, `noEventGap` emission slows from 500ms to 1s, and bus fan-out batches per 100ms window.

---

## 26. Testing topology

```
┌─────────────────────────────────────────────────────────────┐
│ AgentCoreTests              (engine, PTY, bus, heartbeat,   │
│                              git diff, fsevents, hook server)│
│   uses AgentTestSupport      (MockAdapter, FakeClock, etc.)  │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│ AgentTestSupportTests       (FakeClock virtual sleep, etc.)  │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│ ClaudeAdapterTests          (hook decode, transcript schema, │
│                              TUI fallback parser, slash cmd) │
│   inline JSONL + hook payloads in test sources              │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│ ClaudeCodeTwinTests         (digital-twin contract, engine   │
│                              E2E via ClaudeCodeTwin)         │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│ AgentProtocolTests          (Codable round-trip per case,    │
│                              version negotiation, frames)    │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│ AgentRemoteControlTests     (NWListener handshake, pairing,  │
│                              lockout, bearer token revoke,   │
│                              TLS cert lifecycle)             │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│ AgentUITests                (view-model state machines,      │
│                              composer, diff panel, slash UI) │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│ RemoteParityTests           (the canary — every AgentCommand │
│                              from the Mac UI produces the    │
│                              same bytes as from the wire)    │
└─────────────────────────────────────────────────────────────┘
```

### Patterns

- **Swift Testing** throughout (`@Test`, `#expect`, `#require`). No XCTest.
- **Golden fixtures** for the TUI parser, hook decoder, transcript decoder, and `WireCodec`. Diffs are reviewed at PR time; regenerating a golden requires explicit approval.
- **Property tests** for `WireCodec` round-trips, state-machine fold associativity, and bus replay determinism.
- **Deterministic time** via `FakeClock`; avoid wall-clock sleeps except for
  short async-stream drain points and real-PTY integration coverage.
- **Scripted PTY seam tests** in `AgentEngineCommandTests` inject `AgentPTY`
  doubles to cover exact bytes and failure propagation for every pty-writing
  command: `.sendPrompt`, `.cancelCurrentTurn`, `.respondToInlinePrompt`, all
  typed slash commands, `.editAndResubmitLast`, and every
  `respondToPermission` delivery mode.
- **Remote PTY failure E2E tests** in `Remote/AgentRemoteControlTests/RemoteControlE2ETests` use the same seam
  behind an in-memory WebSocket server to prove command failures become failed
  wire results and `.sendPrompt` preserves event-before-error ordering.
- **Real-PTY suite** (`tests-pty-integration`) runs a `sleep 1` child end-to-end,
  asserting the read pipeline, reap, and graceful shutdown work against the
  real kernel. Gated by an env var so CI on Linux skips it.

---

## 27. Tooling and enforcement

Architecture is only useful if it survives the next pull request. The enforcement chain:

| Tool | What it enforces |
| --- | --- |
| `SwiftFormat` (checked-in `.swiftformat`) | Style. Pre-commit + CI. |
| `SwiftLint` (checked-in `.swiftlint.yml`) | `force_unwrapping` / `force_try` / `large_tuple` as errors; `file_length=400`, `function_body_length=60`, `function_parameter_count=5`; custom rules rejecting `Date()` / `Int.random` / `ProcessInfo.processInfo.environment` / `FileManager.default` outside `Live*` files; `print(`; bare `// TODO`. |
| Custom import-graph linter | Rejects forbidden cross-target imports (e.g. SwiftUI in `AgentCore`). |
| `swift build -Xswiftc -warnings-as-errors` | All warnings are errors in CI. |
| `swift test --warnings-as-errors` | Tests must be warning-free too. |
| CI symbol-table check on `codemixerd` | `nm codemixerd | grep SwiftUI.` fails the job. |
| CI entitlements check on `Codemixer.app` | Asserts `com.apple.security.app-sandbox` key is absent. |
| `RemoteParityTests` in CI | Mac UI / wire parity. |
| Pre-merge review checklist (PR template) | The checklist from `code-style.md` §13 in copy-pastable form. |
| `CODEOWNERS` | Style-conscious reviewer required on every PR. |

The combined effect: the architecture rules above are mostly self-enforcing. If a PR breaks one, CI rejects it before a human reviews.

---

## 28. End-to-end data flows

Three canonical walkthroughs. Reading them in order is the fastest way to internalize the architecture.

### 28.1 Sending a prompt

```
1. User types "fix the test failure" in ComposerView, hits Cmd-Return.
2. ComposerModel constructs:
     AgentCommand.sendPrompt(text: "fix the test failure", attachments: [])
3. ComposerModel calls: await engine.send(.sendPrompt(...))
   (where `engine` is either an in-process AgentEngine actor OR a
    loopback EngineRemoteProxy that wraps a WSS connection — either way,
    the same AgentEngineCommandPort.)
4. AgentEngine actor receives the command:
     - lastUserBubbleID = seams.random.uuid()
     - bytes = adapter.encodeUserPrompt("fix the test failure")  // for Claude: text + "\r"
     - await bus.publish(.userTurn(id: ..., text: ...))
     - currentTurnID = lastUserBubbleID
     - heartbeat.startTurn(...)
     - await pty.write(bytes)
5. PTYHost writes bytes to the master FD.
6. The kernel delivers them to Claude's slave PTY; Ink TUI displays them.
7. Claude begins processing, emits "user_prompt_submit" hook to our UDS.
8. ClaudeAdapter decodes the hook envelope, ignores it (already published).
9. Claude streams the assistant's thinking, then chat blocks, into its
   transcript JSONL. ClaudeTranscriptTailer reads new lines.
10. Tailer emits AgentEvent.thinkingChunk(...) per delta.
11. AgentEngine.ingest forwards each event to bus.publish.
12. Each subscriber (Mac UI EngineViewModel + 0..N remote clients) gets
    the AsyncStream tick and renders.
13. Final chat block: tailer emits assistantText(isFinal: true).
14. heartbeat.endTurn() → activityStateChanged(.idle).
```

### 28.2 A tool call with permission

```
1. Claude wants to run `git push`. It emits a "pre_tool_use" hook.
2. HookServer receives the envelope; ClaudeAdapter decodes:
     - toolName = "Bash", input = "git push"
     - PermissionPrompt(id: UUID, tool: "Bash", input: ..., risk: .write)
3. Adapter emits AgentEvent.permissionRequest(prompt).
4. Engine ingests; pendingPermissions[id] = prompt; bus.publish.
5. Mac UI's ConversationViewModel inserts an inline PermissionCard.
6. iPhone Codemixer Remote (if connected) gets the same event via WSS,
   renders the same card.
7. User taps "Approve" on the phone. Phone sends:
     ServerFrame? No — ClientFrame.command(.respondToPermission(id, .allow))
8. RemoteControlServer decodes, calls engine.send(.respondToPermission(...)).
9. AgentEngine:
     - prompt = pendingPermissions.removeValue(forKey: id)
     - delivery = adapter.encodePermissionResponse(.allow, for: prompt)
     - switch delivery:
         .writePTY(d) → pty.write(d)                 (TUI prompts accept "y\n")
         .respondToHookProcess(json) → hookServer.respond(id, json)
         .both(p, h) → pty.write(p), then hookServer.respond(id, h)
10. If the pty write fails, the same error propagates through `engine.send`;
    remote clients receive a failed command result. If delivery succeeds,
    Claude proceeds with the tool; toolStart/toolProgress/toolEnd flow as usual.
11. A second client responding after the prompt was removed is a no-op; timeout
    auto-denial publishes `permissionAlreadyResolved(id, byDevice: "timeout")`
    so stale cards can collapse.
```

### 28.3 Mid-session file revert from the diff panel

```
1. User clicks "Revert" on a hunk in DiffPanelView.
2. DiffPanelViewModel: engine.send(.revertHunk(url, hunkID: ...))
3. AgentEngine recognises this as out-of-band: routes to GitDiffEngine.
4. GitDiffEngine.revert(hunk:):
     - locate hunk in the cached unified diff
     - construct a unified-diff patch with leading "-/+" inverted
     - agent_posix_spawn `git apply -R --unidiff-zero` with patch on stdin
5. FSEventsWatcher fires on the workspace path (debounced 50ms).
6. GitDiffEngine re-runs status/diff, publishes new ChangedFile list.
7. DiffPanelViewModel updates. Mac UI redraws. Phone (subscribed) too.
```

These three flows touch every joint in the system. Reviewers should be able to reproduce them on a whiteboard.

---

## 29. Failure modes and recovery

| Failure | Detection | Recovery |
| --- | --- | --- |
| Agent process crashes mid-turn | `ChildReaper` observes `SIGCHLD`, `waitpid` returns abnormal status | Engine publishes `.stopped(reason: .crashed)` + `.error(.adapter(...))`. UI shows recovery sheet ("Restart session"). One click → fresh engine, `--resume` if adapter supports it. |
| PTY write fails | `AgentPTY.write` throws `PTYError` | The command throws. Remote callers receive a failed command result; GUI callers roll back optimistic state where applicable. `.sendPrompt` has already published `.userTurn` by design. |
| Transcript file missing | Tailer's `open(2)` fails | Adapter emits `error(.adapter("transcript", "missing"))`. UI shows banner ("Live updates unavailable; using TUI fallback only"). |
| Hook UDS socket conflict | `NWListener.start` fails with EADDRINUSE | Engine tries `${TMPDIR}/codemixer-<pid>.sock`; retries up to 3 times with fresh paths. |
| Remote client falls behind | Subscriber's outbound queue exceeds 1024 | Drop-oldest + emit `eventDropped(count:)` signal. Client receives this and asks for `requestSnapshot(.conversation)`. |
| Daemon crash | LaunchAgent restarts via `KeepAlive` | GUI's `EngineConnection` reconnects on `/v1/health` becoming 200 again; sends `subscribe(lastSeenEventID:)`; bus replays. |
| TLS cert expired | Client cert validation fails | UI shows "Refresh TLS cert" in Settings → Remote; one click regenerates and re-shares fingerprint. All paired clients must re-pair. |
| Pairing PIN brute-force | 5 failed attempts in 90s window | Exponential lockout starting 60s. Logged with `pin_lockout_started` to Console. |
| FSEvents storm | > 1000 events / sec | Debounce widens from 50ms → 250ms automatically; `GitDiffEngine` runs at most once per debounce window. |
| Network drop on mobile | WSS heartbeat (15s) misses | Server marks subscriber `.stale`, keeps queue alive 60s. Client reconnect within 60s gets replay; later gets `engineRestarted` + full snapshot. |

The general principle: **every failure produces a typed event the user can observe.** No silent retries, no spinning forever.

---

## 30. Versioning and wire-protocol evolution

The wire protocol is the most rigid part of the system because clients we don't control will speak it.

### Version field

Every frame carries `"v": Int`. Current version is 1. The version is read **before** decoding the rest, so a future version can be detected and rejected with a clean `versionMismatch` error.

### Compatibility policy

- **Additive change** (new event case, new command case, new optional field): minor — clients on v1 can ignore unknown cases via `Codable`'s lenient decoding (we use `decodeIfPresent` + a `case unknown(String)` fallback on every wire enum).
- **Breaking change** (renamed case, removed field, semantic shift): major — `v` bumps from 1 to 2; the server speaks both for a release; old clients are warned.
- **Removed features** stay in the protocol as deprecated cases until the version bump.

### Migration

Every persisted file (prefs, sessions, recent) has a `schemaVersion`. The reader migrates forward; the writer always writes the latest. Downgrade is unsupported — a user who downgrades Codemixer must accept losing newer-format files (the migration code refuses to write older versions).

### Telemetry on protocol mismatch

When a client sends `v != 1`, the server logs `wire_version_mismatch { client: <n>, server: 1 }` once per connection and returns `WireError.versionMismatch(server: 1, client: n)`. Phones with stale builds see a clear in-app message and a deep link to App Store.

---

## 31. Extension recipes

The architecture is designed for additions. Five common cases:

### 31.1 Adding a new agent adapter

1. Scaffold `src/AgenticCLIs/<AgentName>/` with `Adapter/`, `Common/`, optional `digital-twin/`, and contract `README.md` — see [`src/AgenticCLIs/README.md`](../src/AgenticCLIs/README.md).
2. Add an SPM library target + product under that path; top-level type conforming to `AgentAdapter`.
3. Declare capabilities: e.g. `[.streamJSONStdio, .permissionPrompts]`.
4. Implement `makeEventStream(inputs:)` — parse the agent's NDJSON / proprietary stream from `inputs.ptyOutput`, emit `AgentEvent`s.
5. Register at startup: `await AdapterRegistry.shared.register(CodexAdapter())` in `CodemixerApp` / `CodemixerDaemon` only.
6. Add agent-specific tests in `tests/AgenticCLIs/<AgentName>/<Agent>AdapterTests/` (optional `<Agent>TwinTests/`) — see [`tests/AgenticCLIs/README.md`](../tests/AgenticCLIs/README.md).

No edits to `AgentCore`, `AgentUI`, `AgentProtocol`, or `AgentRemoteControl`. If the new agent needs a new capability flag, that's a one-line addition to `AgentCapabilities` and a corresponding wiring branch in `AgentEngine.start`.

### 31.2 Adding a new tool renderer

1. Add a case to `ToolRenderHint` if the existing ones don't fit.
2. Extend `ToolCallCardView` with the new rendering branch.
3. Keep renderer-specific state private to that view.
4. Update relevant adapters' `toolRenderHint(toolName:, input:)` to return the new case.
5. Add `RemoteParityTests` coverage if the new hint round-trips over the wire.

### 31.3 Adding a new `AgentCommand`

1. Add a case to `AgentCommand` in `AgentProtocol`.
2. Add handling in `AgentEngine.send(_:)`.
3. If it writes to the pty, add exact-byte and write-failure coverage in
   `AgentEngineCommandTests`; multi-step commands cover each write point.
4. Update `RemoteParityTests` to cover the new case.
5. Add `RemoteControlE2ETests` coverage when remote clients need a specific
   command-result or event-ordering guarantee.
6. Add a Mac UI surface (button, menu item, voice phrase).
7. Update remote-control docs.

### 31.4 Adding a new `AgentEvent`

1. Add a case to `AgentEvent` in `AgentCore`.
2. Add the parallel case to `AgentEventWire` in `AgentProtocol`.
3. Extend `WireCodec` to convert both directions.
4. Update `RemoteParityTests` with a round-trip case.
5. Add at least one consumer in the Mac UI (or document why none is wanted).
6. Update the conversation reducer if the event affects state.

### 31.5 Adding a new wire frame

Rare. Bumps the wire version unless purely additive. Requires a checklist sign-off: protocol owner, security reviewer, mobile-client (when it ships) compatibility lead.

---

## 32. Trade-offs and rejected alternatives

| Considered | Why rejected |
| --- | --- |
| **`Process` (`NSTask`) instead of `posix_spawn`** | `Process` doesn't expose PTY allocation; we'd need to subclass / FFI anyway. Doing `posix_spawn` directly is cleaner and avoids Swift runtime fork-safety issues. |
| **Anthropic SDK / `--print` / stream-json** | Routes to the API billing pool, violating the interactive-subscription constraint after June 15, 2026. |
| **Embed `claude` as a sub-binary in our bundle** | Licensing + update cadence mismatch. We always run the user's installed `claude`. |
| **Mirror transcripts into SQLite for fast search** | Duplicate state, eventually-divergent. Claude's JSONL is the canonical source; we tail it. Full-text search is a roadmap item using ripgrep over the JSONL files, not a parallel DB. |
| **Express/Node UI shared with web** | Inconsistent with native macOS feel and the no-terminal constraint. We do ship a WSS server, but the primary GUI is native SwiftUI. |
| **`@MainActor`-isolated `AgentEngine`** | Breaks Mode B (daemon has no main thread in the SwiftUI sense). Engine must be a plain `actor`. |
| **Bus = `Combine` `PassthroughSubject`** | Combine's back-pressure model is poor for N-subscriber fan-out and replay; an actor-based bus is more straightforward and Sendable-correct. |
| **WebSocket over plain HTTP** | LAN exposure with no encryption is unacceptable. TLS only. |
| **Tor / mesh fallback for remote control** | Out of scope. The intended use is one phone on the same Wi-Fi as the Mac. |
| **OAuth / external IdP for pairing** | Overkill for a local-network app. PIN + bearer token + Keychain is enough and keeps Codemixer offline-first. |
| **Persistent per-event id schema** | Engine-issued UUIDs at publish time are enough; persisting them in the bus ring is sufficient for reconnect-with-replay. |
| **In-place transcript rewrite for edits** | Claude appends to JSONL; rewriting is corrupting. Edits work by sending a new `userTurn` and letting Claude reprocess. |
| **`OperationQueue` for child waitpid** | Signal handling on `OperationQueue` is fragile; `DispatchSource.signal` is the system-blessed path. |
| **Two separate Xcode projects for GUI and daemon** | Sharing source via SPM in one xcodeproj is simpler. The two targets share everything except the executable entry. |
| **Use `URLSession` WebSocket task** | Server-side is `NWListener` for control over the TLS identity and binding interface; client-side is the same so behaviour is symmetric and testable. |

---

## 33. Glossary

| Term | Meaning |
| --- | --- |
| **Adapter** | A module conforming to `AgentAdapter` that knows one specific CLI agent. `ClaudeCode` in v1 (ships `ClaudeAdapter`). |
| **AgentCommand** | The typed input alphabet sent into the engine. |
| **AgentEvent** | The typed output alphabet emitted by the engine. |
| **AgentEventWire** | Codable mirror of `AgentEvent` in `AgentProtocol`. |
| **AgentEngineCommandPort** | The single inbound protocol the engine implements: `send(_ command: AgentCommand)`. |
| **Bus** | `MulticastEventBus` — the fan-out actor. |
| **Capability** | A bit in `AgentCapabilities` indicating which signal sources an adapter wants. |
| **Daemon** | The `codemixerd` binary running headless in the background. |
| **Engine** | `AgentEngine` — the orchestrator actor. |
| **Headless** | Running without a UI process. The engine + remote-control server, no SwiftUI. |
| **Hook** | A small JSON payload Claude sends to a sidecar process at lifecycle points. We receive them via our UDS hook server. |
| **JSONL transcript** | Newline-delimited JSON file Claude writes during a session, at `~/.claude/projects/<slug>/<id>.jsonl`. |
| **Loopback bridging** | The Mac GUI talks to the daemon via `127.0.0.1` WSS, same wire as remote clients. |
| **Mode A / Mode B** | In-process / daemon-backed deployment shapes. |
| **MockAdapter** | Test-only adapter that replays scripted `AgentEvent` sequences. |
| **PIN** | Six-digit pairing code for first-time device association. |
| **Port** | An inbound or outbound boundary protocol. `AgentEngineCommandPort` is one. |
| **PTY** | Pseudo-terminal — a kernel-level "fake terminal" used to keep `claude` in interactive mode while hiding it from the user. |
| **PTYHost** | Actor owning the master FD. |
| **Reaper** | `ChildReaper` — the SIGCHLD handler. |
| **Remote client** | A WSS-connected consumer of the engine — Mac GUI in Mode B, iOS app, scripts. |
| **Ring buffer** | Bounded queue of last-N events for replay on reconnect. 500 events in v1. |
| **Seam** | A protocol-typed dependency injection point. `Clock`, `RandomSource`, `Environment`, `FileSystem`. |
| **TerminalEngine** | Actor wrapping `SwiftTerm.Terminal` headless. |
| **TUI fallback** | Last-resort signal source — scraping the SwiftTerm headless snapshot when nothing else has the information. |
| **WireCodec** | The single converter between `AgentEvent` and `AgentEventWire`. |

---

## 34. When in doubt

- **When in doubt about where a piece of code goes**, ask the dependency arrow (§6). Code lands in the lowest layer that can express it.
- **When in doubt about whether something is event or state**, prefer event. State is a fold; events are the truth.
- **When in doubt about whether to add a command or a service**, ask "would a mobile-only user need this?" If yes, it's a command.
- **When in doubt about a new event case**, ask "would two different clients need to agree on this exact moment?" If yes, it's an event.
- **When in doubt about a `@MainActor` annotation**, you almost certainly don't want one. The seam lives in `AgentUI`.
- **When in doubt about test determinism**, route through a seam.
- **When in doubt about a wire change**, write the `RemoteParityTests` case first.
- **When in doubt about security**, default closed: loopback bind, lockout on retries, hash-not-plaintext in Keychain, `.private` log fields.
- **When in doubt about novelty**, prefer the boring shape. Codemixer's complexity is in its constraints, not its cleverness.

If after all this you still cannot decide, propose the decision in the PR description with the trade-offs made explicit; the reviewer's job is to lock the direction for future readers.

---

*Last revised alongside [docs/style/code-style.md](style/code-style.md) and [docs/style/visual-style.md](style/visual-style.md). When this file and `code-style.md` disagree on how code reads, `code-style.md` wins; when this file and `visual-style.md` disagree on how the product appears, `visual-style.md` wins. To propose changes, follow the same process as `code-style.md` §29.*
