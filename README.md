# Codemixer

> A native macOS workspace for agentic CLI coding agents — Claude Code through a hidden interactive terminal transport, Codex through App Server stdio JSON-RPC, and custom ACP agents over the same stdio JSON-RPC host. Everything you see is SwiftUI driven by a typed event stream. No terminal pane, no Electron, and no accidental Agent Credits usage from third-party / SDK-style Claude Code invocations. The same engine also runs **headless** as `codemixerd` so a future mobile client (or your own scripts) can drive it over a typed WebSocket protocol.

---

## Table of contents

- [Why Codemixer](#why-codemixer)
- [Status](#status)
- [Quick start](#quick-start)
- [Scripts guide](#scripts-guide)
- [Architecture at a glance](#architecture-at-a-glance)
- [Repository tour](#repository-tour)
- [Build and run](#build-and-run)
- [Headless mode](#headless-mode)
- [Adding a new agent](#adding-a-new-agent)
- [Testing](#testing)
- [Documentation map](#documentation-map)
- [Design pillars](#design-pillars)
- [Contributing](#contributing)
- [Roadmap](#roadmap)
- [License](#license)

---

## Why Codemixer

The constraint set was unusual enough that none of the off-the-shelf wrappers fit:

1. **Keep Claude Code on the interactive billing path.** When third-party clients or SDK-style entrypoints invoke Claude Code, they can route usage through Agent Credits. Codemixer runs `claude` as a real interactive terminal session instead, so Claude usage stays on the interactive subscription path rather than the Agent Credits path.
2. **Hide the transport entirely.** TUI panes with ANSI flicker, cursor jumps, and spinner artifacts are not the experience anyone wants in 2026. Terminal transports stay invisible, and stdio transports are direct protocol peers; both become typed `AgentEvent`s rendered by native SwiftUI components.
3. **Run with or without the UI.** The same engine has to power the GUI app, a headless daemon, and (one day soon) an iOS client connecting over Wi-Fi. There can be no UI-only feature and no API-only feature.
4. **Stay agent-agnostic.** Claude, Codex, and custom ACP ship as sibling adapters behind a single `AgentAdapter` protocol. The engine selects an `AgentTransport` from the adapter descriptor — terminal for Claude, stdio JSON-RPC for Codex and ACP — and the UI never grows per-agent branches.
5. **Mouse, keyboard, voice, and remote API are peer interaction surfaces.** Every UI affordance maps to exactly one `AgentCommand` case; a parity test refuses merges that add a button without wiring its case across the WebSocket protocol.

That combination is what `Codemixer` solves.

---

## Status

**v0.1+ (current)** — the foundational pipeline is in place and green, and most of the v0.2/v0.3 surface has landed on top of it:

Engine + protocol spine:

- ✅ Generic transport pipeline: `AgentTransport` → interactive terminal (`PTYHost` + `TerminalEngine`) or stdio JSON-RPC (`StdioJSONRPCTransport`, including ACP) → adapter event stream → `MulticastEventBus` → SwiftUI.
- ✅ Typed `AgentCommand` ↔ `AgentEvent` alphabets with a `WireCodec` boundary and parity/dispatch tests that refuse drift.
- ✅ `AgentAdapter` protocol with Claude, Codex, and custom ACP adapters (binary lookup, transport descriptor, bootstrap bytes, command encoding, event decoding, session listing).
- ✅ Server-side `HeartbeatActivityMonitor` + `StatusPhraseResolver` so every connected client sees identical "still working" escalation.
- ✅ `SnapshotService`, `EngineViewModel` event reduction, and a `GitReverter` for file/hunk-level revert.
- ✅ `SilentDiagnostics` ring buffer with opt-in UI and `GET /v1/diagnostics/silent` sidecar.
- ✅ FSEvents diff monitor in `AgentEngine` with `ChangedFilesReconciler`.
- ✅ Model picker via `AgentAdapter.availableModels()` (Claude: Sonnet / Opus / Haiku).

Workspace + UX surface:

- ✅ Conversation rendering: markdown prose, code blocks with syntax highlighting, thinking blocks, inline tool-call cards, permission prompts, streaming motion.
- ✅ Session navigator (projects → sessions), Cmd+K command palette, project picker, conversation search, settings pane, diff panel.
- ✅ Attachments, voice input + TTS, session export, system notifications, cost badge, auth gate + install-Claude flow, debug terminal / event-log inspectors.
- ✅ Atomic persistence for prefs, sessions, and the Workspace→Projects model.

Remote + distribution:

- ✅ WebSocket remote-control server with PIN pairing, bearer tokens, paired-device store, and Bonjour advertisement.
- ✅ TLS via `CertificateManager` + fingerprint pinning, an HTTP sidecar (port 8422) for health checks + attachment upload, and a `RemoteEngineClient` so a remote peer can drive the engine through the same WebSocket protocol.
- ✅ LaunchAgent installer + daemon plist for running `codemixerd` at login.
- ✅ Headless daemon (`codemixerd`), GUI app (`codemixer`), and digital twin (`fake-claude`) build via SPM.

Quality gates (local — no checked-in CI workflow):

- ✅ Policy scripts enforce package layout, no-SwiftUI-in-core, no-direct-framework-calls, a11y labels, public-API coverage, and per-suite runtime budgets.
- ✅ `scripts/pre-commit.swift` runs build + serial tests + SwiftFormat/SwiftLint (narrow gate; full checklist in `AGENTS.md`).

**Coming up** (tracked in the architecture doc):

- Golden-fixture tests against real Claude transcript JSONL.
- Code-signed + notarized `.app` distribution via the Xcode shell.
- Additional adapters (Cursor CLI / Gemini CLI / OpenCode) and an iOS client over the remote-control API.

---

## Quick start

Requirements: **macOS 14+**, Xcode 16+ for the GUI app, Swift 6.0+ from SPM.

The SPM package declares **macOS only** (`Package.swift`). There is no iOS target today.

```bash
swift build                   # build all libraries + executables
swift test --no-parallel      # run the entire test suite

swift run codemixerd          # start the headless daemon on 127.0.0.1:8421
# GUI: use the Xcode project — see Build and run below (not `swift run codemixer`)
```

> **`--no-parallel` is required for the test suite.** Several tests own
> kernel-level resources (PTYs, signal sources, `NWListener`s) that race when
> the test runner shares them across parallel workers. Running serially keeps
> the suite under two seconds while remaining deterministic.

The GUI app expects `claude` on your `PATH`. Install with:

```bash
npm install -g @anthropic-ai/claude-code
```

If `claude` is unavailable (CI runners, fresh boxes, contributors without
Anthropic credentials), set `CODEMIXER_FAKE_CLAUDE=1` to launch the digital
twin `fake-claude` binary instead. The twin is documented in
[`src/AgenticCLIs/ClaudeCode/README.md`](src/AgenticCLIs/ClaudeCode/README.md)
and serves as both a test harness and an executable specification of the
contract Codemixer expects from Claude Code.

To validate the **real** interactive PTY path (interactive billing, avoiding
Agent Credits / `claude -p`), opt in with:

```bash
CODEMIXER_LIVE_CLAUDE=1 swift test --no-parallel --filter LiveClaudeIntegrationTests
```

To validate the **real** Codex App Server stdio path (`codex app-server --stdio`):

```bash
CODEMIXER_LIVE_CODEX=1 swift test --no-parallel --filter LiveCodexIntegrationTests
```

Full harness docs: [`tests/AgenticCLIs/README.md`](tests/AgenticCLIs/README.md).

### Spike-script prerequisites

The live validation spikes in `scripts/` have extra runtime dependencies:

```bash
brew install socat jq
npm install -g @anthropic-ai/claude-code
```

- `scripts/spike-billing.swift` requires `claude` and a logged-in account. It
  launches Claude through an interactive PTY and reads usage from the
  transcript.
- `scripts/spike-events.swift` requires `claude`, `socat`, and `jq`.

Both spikes are manual validation tools and are intentionally not run in automated CI (no workflow checked in).

### Scripts guide

For a complete list of local automation and validation scripts (including usage
examples), see [`scripts/README.md`](scripts/README.md).

---

## Architecture at a glance

Codemixer has two deployment shapes. Both use the same `AgentCommand` / `AgentEvent`
alphabets and the same `AgentEngineCommandPort` abstraction at the UI boundary.

**Mode A (default)** — engine in the GUI process. Optional remote access lets
*external* peers connect; the Mac UI does not go over the wire.

```
┌─────────────────────────────────────────────────────────────────────┐
│  Codemixer.app (Mode A)                                              │
│                                                                      │
│   EngineViewModel ──► AgentEngine (in-process) ──► MulticastEventBus │
│                              ▲                                       │
│   RemoteControlServer ───────┘  (optional; Settings → Remote)        │
│         ▲                                                            │
│         │ WSS                                                        │
│   external remote clients (iOS, CLI, …)                              │
└─────────────────────────────────────────────────────────────────────┘
```

**Mode B** — engine in `codemixerd`. The Mac GUI is a loopback WebSocket
client (`RemoteEngineClient`) — no in-process engine, no GUI fast path.

```
┌──────────────────────────┐         ┌──────────────────────────────────┐
│  Codemixer.app (Mode B)  │  WSS    │  codemixerd                       │
│                          │ loopback│                                   │
│  EngineViewModel         ├────────►│  RemoteControlServer              │
│       ▲                  │         │       └─► AgentEngine             │
│       │                  │         │       └─► MulticastEventBus         │
│  RemoteEngineClient      │         │  connectedClientCount = N         │
│  (Bootstrap.remoteClient)│         │    (includes this GUI + others)   │
└──────────────────────────┘         └──────────────────────────────────┘
                                              ▲
                                              │ WSS (LAN + TLS + pairing)
                                         phone, scripts, …
```

Every UI affordance — keyboard, mouse, voice, remote phone — maps to one
`AgentCommand` case. Every byte the agent produces is normalised to one
`AgentEvent` case. Both alphabets are typed Swift enums; the wire codec
(`WireCodec`) translates the domain `AgentEvent` to its portable `AgentEventWire`
mirror at the network boundary, and a parity test refuses to let them drift.

**Terminology:** *remote client* is used in two related senses — client role
(`RemoteEngineClient`) vs connected-peer count (`connectedRemoteClients`). See
[`docs/architecture.md` §4.1](docs/architecture.md) and
[`src/Remote/AgentRemoteControl/README.md`](src/Remote/AgentRemoteControl/README.md).

Full treatment in [`docs/architecture.md`](docs/architecture.md).

---

## Repository tour

```
Codemixer/
├── README.md                        # this file
├── AGENTS.md                        # AI-agent companion (read first if you're an LLM)
├── docs/
│   ├── architecture.md              # the source of truth for how the system thinks
│   ├── LOGGING.md                   # structured-logging conventions + privacy
│   ├── style/
│   │   ├── code-style.md            # how code reads (merge gate in §26)
│   │   └── visual-style.md          # color, type, spacing, motion, components
│   └── reference/                   # portable patterns + templates for new projects
│       ├── patterns/                # the building blocks, written to stand alone
│       └── templates/               # skeletons (code-style, architecture, ADR, PR)
```

The SPM package and Xcode shell live at the repository root:

```
Package.swift
src/
├── Core/            # agent-agnostic engine + portable wire protocol + POSIX shim
│   ├── CPosixBridge/    # C shim: openpty, posix_spawn, FD_CLOEXEC
│   ├── AgentProtocol/   # pure Foundation Codable DTOs — portable wire alphabet
│   └── AgentCore/       # AgentTransport, PTY/reaper, stdio transport, terminal engine, event bus,
│                        # engine actor + commands, snapshot, git diff/revert,
│                        # hooks, FSEvents, attachments, status, activity,
│                        # network transport, persistence, paths, DI seams
├── AgenticCLIs/     # one folder per agent CLI — see AgenticCLIs/README.md
│   ├── ClaudeCode/  # Adapter/, Common/, digital-twin/, contract README
│   ├── Codex/       # App Server stdio adapter, Common/, digital-twin/, contract README
│   └── AgentClientProtocol/  # ACP client for custom agent servers
├── Remote/          # headless daemon + WebSocket remote-control library
│   ├── AgentRemoteControl/  # WSS server, pairing, RemoteEngineClient — README.md
│   └── CodemixerDaemon/     # headless daemon executable
├── AgentUI/         # SwiftUI views, Theme tokens, IntentReveal, EngineViewModel,
│                    # conversation, composer, sidebar, palette, diff, settings,
│                    # voice, export, search, notifications, debug
├── CodemixerApp/    # GUI app — sources + Project.swift + generated Codemixer.xcodeproj
tests/
├── TestSupport/
│   ├── AgentTestSupport/    # FakeClock, FakeRandom, FakeEnvironment,
│   │                        # InMemoryFileSystem, (Recording)MockAdapter
│   └── AgentTestSupportTests/
├── Core/
│   ├── AgentProtocolTests/
│   └── AgentCoreTests/
├── Remote/
│   ├── AgentRemoteControlTests/
│   └── RemoteParityTests/    # asserts wire codec + command dispatch parity
├── AgenticCLIs/                    # per-agent adapter + twin suites — see tests/AgenticCLIs/README.md
│   ├── ClaudeCode/
│   │   ├── ClaudeAdapterTests/
│   │   └── ClaudeCodeTwinTests/
│   ├── Codex/
│   │   ├── CodexAdapterTests/
│   │   └── CodexTwinTests/
│   └── AgentClientProtocol/
│       ├── ACPAdapterTests/
│       └── ACPTwinTests/
├── AgentUITests/
```

### Module responsibility map

| Module | Sources | Knows about | Imports |
| --- | --- | --- | --- |
| `CPosixBridge` | `src/Core/CPosixBridge/` | `openpty`, `posix_spawn`, `winsize`, `killpg`, `fcntl`. Nothing Swift-side. | — |
| `AgentProtocol` | `src/Core/AgentProtocol/` | Pure value types. Wire DTOs, `AgentCommand`, `AgentEventWire`, frames, prefs, decisions, attachment refs. | Foundation only. |
| `AgentCore` | `src/Core/AgentCore/` | `AgentTransport` seam, interactive terminal transport, stdio JSON-RPC transport, PTY + reaper, terminal, hooks, FSEvents, git diff/revert, attachments, events, engine, snapshot, bus, status, activity, network transport, persistence, paths, seams. **The agent-agnostic engine.** | `CPosixBridge`, `AgentProtocol`, `SwiftTerm`. |
| `ClaudeCode` | `src/AgenticCLIs/ClaudeCode/` (`Adapter/`, `Common/`, `digital-twin/`) | `claude` binary lookup, hooks, transcript JSONL, slash commands, TUI fallback, shared path/input helpers, and the `ClaudeCodeTwin` digital twin. | `AgentCore`, `AgentProtocol`. |
| `Codex` | `src/AgenticCLIs/Codex/` (`Adapter/`, `Common/`, `digital-twin/`) | `codex app-server --stdio` lookup/bootstrap, JSON-RPC framing, event decoding, input encoding, thread index, model/command catalogs, and `CodexTwin`. | `AgentCore`, `AgentProtocol`. |
| `AgentClientProtocol` | `src/AgenticCLIs/AgentClientProtocol/` (`Adapter/`, `Common/`, `External/`, `digital-twin/`) | ACP client for user-configured agent servers: initialize/session framing, reverse FS/terminal, session index, `ACPTwin`. | `AgentCore`, `AgentProtocol`. |
| `AgentRemoteControl` | `src/Remote/AgentRemoteControl/` | WebSocket server, pairing PIN + bearer tokens, paired-device store, TLS/cert manager, HTTP sidecar, Bonjour, remote engine client. | `AgentCore`, `AgentProtocol`. |
| `AgentUI` | `src/AgentUI/` | SwiftUI views, theme tokens, `EngineViewModel`, `IntentReveal`, conversation/composer/sidebar/palette/diff/settings/voice/export/search/notifications/debug surfaces. **Agent-agnostic.** | `AgentCore`. |
| `AgentTestSupport` | `tests/TestSupport/AgentTestSupport/` | Deterministic fakes for all four seams + `MockAdapter`. | `AgentCore`, `AgentProtocol`. |
| `CodemixerApp` | `src/CodemixerApp/` | `@main`, root scene, bootstrap, adapter registration. Tiny. | `AgentCore`, `AgentUI`, `ClaudeCode`, `Codex`, `AgentClientProtocol`, `AgentRemoteControl`. |
| `CodemixerDaemon` | `src/Remote/CodemixerDaemon/` | `@main`, signal handling, server wiring. Tinier. | `AgentCore`, `ClaudeCode`, `Codex`, `AgentClientProtocol`, `AgentRemoteControl`. |

The arrows go strictly downward — `AgentUI` never imports `ClaudeCode`, `AgentCore` never imports SwiftUI, `AgentProtocol` imports only Foundation. This is what keeps the headless daemon truly headless and a future iOS client truly portable.

---

## Build and run

### From the command line

```bash
swift build              # everything
swift build --product codemixerd
swift build --product codemixer

swift test --no-parallel # full suite (~2s)
swift test --filter PTYHostTests

swift run codemixerd
swift run codemixer
```

### GUI app (Xcode)

The GUI is **not** validated via `swift run codemixer`. Use the Tuist-generated Xcode project instead. `Codemixer.xcodeproj`, `Codemixer.xcworkspace`, and `Derived/` under `src/CodemixerApp/` are gitignored — regenerate after clone or when `Project.swift` changes:

```bash
scripts/generate-xcodeproj.swift --no-open

cd src/CodemixerApp
xcodebuild -project Codemixer.xcodeproj -scheme Codemixer -configuration Debug build
open "$(xcodebuild -project Codemixer.xcodeproj -scheme Codemixer -configuration Debug -showBuildSettings | awk -F'= ' '/TARGET_BUILD_DIR/ { dir=$2 } /WRAPPER_NAME/ { app=$2 } END { print dir "/" app }')"
```

Tuist manifest: `src/CodemixerApp/Project.swift`. App Sandbox is off (we spawn arbitrary CLI agents under a pty); Hardened Runtime stays on for distribution builds.

### Building a signed `.app` bundle

For notarization and entitlement debugging, use the Xcode project above. The daemon (`codemixerd`) builds via SPM only (`swift build --product codemixerd`).

---

## Headless mode

`codemixerd` runs the engine without any SwiftUI dependency. By default it binds a WebSocket on loopback only; flipping a setting opens it to the LAN behind PIN pairing. Port numbers, hosts, and paths have a single owner in `RemoteDefaults` (`AgentCore`).

```bash
swift run codemixerd
# → WebSocket    ws://127.0.0.1:8421/v1/ws   (RemoteDefaults.webSocketPort)
# → HTTP sidecar       127.0.0.1:8422         (RemoteDefaults.sidecarPort)
#     GET  /v1/health              → { ok, version, uptime, clients }
#     GET  /v1/diagnostics/silent  → JSON array of SilentDiagnostics records
#     POST /v1/attachments         → stages an upload, returns { id, path }
```

LAN exposure adds TLS through `CertificateManager` (self-signed EC identity + fingerprint pinning) and authenticated pairing via `PairingService` + `PairedDeviceStore`. External peers drive the engine through the same WebSocket protocol the Mode B GUI uses (`RemoteEngineClient` on the client side, `RemoteControlServer` on the daemon). Install the daemon as a login `LaunchAgent` using the template at `src/CodemixerApp/Resources/com.codecave.Codemixer.daemon.plist`.

See [`src/Remote/AgentRemoteControl/README.md`](src/Remote/AgentRemoteControl/README.md) for client-role vs connected-peer terminology.

### The wire protocol in one screen

```jsonc
// client → server (ClientFrame)
{ "v": 1, "type": "command",   "id": "<uuid>", "command": { "type": "sendPrompt", "text": "...", "attachments": [] } }
{ "v": 1, "type": "subscribe", "lastSeenEventID": "<uuid?>" }
{ "v": 1, "type": "snapshot",  "kind": "conversation" }   // also: diff, sessions, workspaceTree, prefs
{ "v": 1, "type": "ping",      "id": "<uuid>" }
{ "v": 1, "type": "pair",      "pin": "123456", "clientName": "Codemixer Mobile" }
{ "v": 1, "type": "auth",      "token": "<bearer token>" }

// server → client (ServerFrame)
{ "v": 1, "type": "event",            "id": "<bus-uuid>", "event": { ... AgentEventWire ... } }
{ "v": 1, "type": "result",           "for": "<uuid>", "ok": true, "error": null }
{ "v": 1, "type": "snapshot",         "kind": "conversation", "payload": "<base64 JSON>" }
{ "v": 1, "type": "pong",             "for": "<uuid>" }
{ "v": 1, "type": "subscribed",       "latestEventID": "<uuid?>", "outcome": "fresh|resumed|checkpointExpired" }
{ "v": 1, "type": "paired",           "token": "<bearer token>" }
{ "v": 1, "type": "pairFailed",       "reason": "invalidPIN" }       // also: expiredPIN, rateLimited, lockedOut
{ "v": 1, "type": "versionMismatch",  "supported": [1] }
```

Sidecar (port 8422): `GET /v1/health`, `POST /v1/attachments`, `GET /v1/diagnostics/silent`.

Reconnecting clients store the `subscribed.latestEventID` (and each event's id) and pass it back as `subscribe.lastSeenEventID` so the server replays only what was missed instead of the whole ring buffer.

The full schema lives in `src/Core/AgentProtocol/`:

- [`AgentCommand.swift`](src/Core/AgentProtocol/AgentCommand.swift) — every typed input.
- [`AgentEventWire.swift`](src/Core/AgentProtocol/AgentEventWire.swift) — every typed output.
- [`WireFrames.swift`](src/Core/AgentProtocol/WireFrames.swift) — top-level envelopes with hand-rolled tagged-union encoding so the JSON shape matches the schema above exactly.

A `RemoteParityTests` suite asserts that every `AgentEvent` case round-trips through the wire codec without losing identity. Adding a new event requires that the test continues to pass — drift is impossible by construction.

---

## Adding a new agent

The shape of the work for any new CLI agent (Cursor CLI, Gemini CLI, OpenCode, …) is:

```swift
public final class CodexAdapter: AgentAdapter, @unchecked Sendable {
    public let id: AgentID = .codex
    public let displayName = "Codex"
    public let iconSymbol  = "sparkle.magnifyingglass"
    public var transportDescriptor: AgentTransportDescriptor { .stdioJSONRPC }

    public var capabilities: AgentCapabilities {
        [.permissionPrompts, .resumableSessions]   // declare adapter features
    }

    public func locateBinary(env: ResolvedEnvironment) async throws -> URL { … }
    public func defaultEnvOverrides() -> [String: String] { … }
    public func buildLaunchArgv(context: LaunchContext) -> [String] { … }
    public func sessionBootstrapBytes(context: LaunchContext) -> Data { … }

    public func makeEventStream(inputs: AgentInputs) -> AsyncStream<AgentEvent> {
        // Parse Codex JSON-RPC bytes from inputs.outputBytes, emit AgentEvent values.
    }

    public func encodeUserPrompt(_ text: String) -> Data { … }
    public func encodeCommand(_ command: AgentCommand) -> Data? { … }
    public func cancelSequence() -> Data { … }
    public func encodePermissionResponse(_ decision: PermissionDecision,
                                         for prompt: PermissionPrompt) -> PermissionResponseDelivery { … }

    // …slash commands, sessions, tool render hints…
}
```

Register at startup:

```swift
await AdapterRegistry.shared.register(CodexAdapter())
```

`AgentCore` and `AgentUI` never import any specific adapter. UI surfaces resolve adapters through `AdapterRegistry`. The engine selects the process/connection shape from `transportDescriptor` and wires up only the signal sources the adapter requested via `capabilities` — no hook server unless `.hooksOverUDS`, no TUI scrape unless `.ptyTUIFallback`, etc.

Full recipe in [`docs/reference/patterns/plugin-adapter-protocol.md`](docs/reference/patterns/plugin-adapter-protocol.md).

---

## Testing

Test framework: **Swift Testing** (`import Testing`).

```bash
swift test --no-parallel              # everything (~2s, required flag)
swift test --filter PTYHostTests      # one suite
swift test --filter "WireCodec"       # any matching suite
```

### What's covered today

Full per-suite index: [`AGENTS.md`](AGENTS.md) (Inside `tests/` → suites).

| Suite | What it asserts |
| --- | --- |
| `AgentProtocolTests / WireFrameRoundTripTests` | Every `ClientFrame` / `ServerFrame` case encodes → decodes → re-encodes identically. |
| `AgentProtocolTests / PrefsAndDecisionsCodableTests` | Prefs and permission-decision DTOs round-trip through `Codable`. |
| `AgentCoreTests / PTYHostTests` | Spawning `/bin/echo` under a real pty emits the printed text and exits cleanly; writes after `close()` throw `.alreadyClosed`. |
| `AgentCoreTests / AgentEngineCommandTests` | Every transport-writing command emits exact bytes at the `AgentTransport.write` boundary; write failures propagate, including `sendPrompt`, cancel, slash commands, edit/resubmit, and permission delivery modes. |
| `AgentCoreTests / EngineIntegrationTests` | End-to-end engine lifecycle with a mock adapter and injected seams. |
| `AgentCoreTests / TerminalEngineTests` | Fed bytes appear in the headless snapshot; BEL is latched and consumed once. |
| `AgentCoreTests / MulticastEventBusTests` | Late subscribers receive the replay history first, then live events. |
| `AgentCoreTests / GitDiffEngineTests` | Unified diffs parse with correct line-kind sequencing and hunk splitting. |
| `AgentCoreTests / ChangedFilesReconcilerTests` | FSEvents/git path delta reconciles added and removed changed files. |
| `AgentCoreTests / SilentDiagnosticsTests` | Ring buffer capacity, recording, and clear. |
| `AgentCoreTests / ShellEnvResolverTests` | `env -0` NUL-separated output parses into key→value pairs, including values containing `=`. |
| `AgentCoreTests / ResolvedEnvironmentTests` | `ResolvedEnvironment` PATH lookup, variable helpers, and equality. |
| `AgentCoreTests / AgentErrorTests` | Every `AgentError` case is `Codable` and compares equal across copies. |
| `AgentCoreTests / StatusPhraseResolverTests` | Higher-priority sources override lower; removing the winner falls back to the next. |
| `AgentCoreTests / ChildReaperTests` | The global child reaper installs idempotently and reaps posix-spawned children. |
| `AgentCoreTests / SnapshotServiceTests` | Every `SnapshotKind` (conversation, diff, sessions, workspaceTree, prefs) serializes to valid JSON a late client can rebuild from. |
| `AgentCoreTests / GitRevertIntegrationTests` | A hunk patch is built as exact unified diff and reverse-applies in a real git repo. |
| `AgentCoreTests / AttachmentResolverTests` | Attachment refs resolve to staged upload files (exact id and sidecar `id-filename` prefix). |
| `AgentCoreTests / HookServerTests` | Hook UDS server accepts framed payloads and fans out to subscribers. |
| `AgentCoreTests / FSEventsWatcherTests` / `FSEventsStreamTests` | FSEvents watcher debouncing and stream wrapper lifecycle. |
| `AgentCoreTests / ProcessRunnerTests` / `KeychainStoreTests` | Framework wrappers for `Process` and Keychain round-trip happy paths. |
| `AgentCoreTests / HeartbeatActivityMonitorTests` | Activity heartbeat escalates through idle → working → stalled thresholds. |
| `AgentCoreTests / PrefsStoreTests` / `SessionStoreTests` / `AppearancePrefsTests` | Prefs, sessions, and appearance persistence reload atomically. |
| `AgentCoreTests / WorkspaceProjectsStoreTests` | The Workspace→Projects model persists atomically and reloads. |
| `AgentCoreTests / UnixSocketTransportTests` | Unix-domain socket transport connects and exchanges bytes in-process. |
| `AgentCoreTests / PublicAPITests` / `CoverageManifest` | Public API surface matches the checked-in coverage manifest. |
| `AgentTestSupportTests / FakeClockTests` | `FakeClock` virtual sleep advances time without wall-clock delays. |
| `ClaudeAdapterTests / HookInstallerTests` | Hook settings are written idempotently; managed entries exist for every Claude lifecycle event. |
| `ClaudeAdapterTests / ClaudeHookDecoderTests` / `TranscriptTailerTests` / `TranscriptTruncationTests` | Hook JSON decode, transcript tailing, and JSONL truncation at turn boundaries. |
| `ClaudeAdapterTests / ClaudeAdapterEventStreamTests` / `ClaudeBinaryLocatorTests` | Adapter event stream wiring, `claude` binary discovery, and Stop/`last_assistant_message` dedup when the transcript already emitted. |
| `ClaudeAdapterTests / ClaudeSlashCommandsTests` / `ClaudeSessionListerTests` | Slash-command catalog and resumable-session listing. |
| `ClaudeAdapterTests / TUIFallbackTests` / `TUIFallbackGateTests` | TUI scrape parsing and gating for terminal fallback. |
| `ClaudeAdapterTests / TwinDecoderParityTests` | Hook decoder output matches the digital-twin emitter contract. |
| `ClaudeAdapterTests / FakeClaudeIntegrationTests` | Production adapter + spawned `fake-claude` emits `assistantText` end-to-end. |
| `ClaudeAdapterTests / LiveClaudeIntegrationTests` | Opt-in live PTY path (`CODEMIXER_LIVE_CLAUDE=1`): one `assistantText`, billing markers `entrypoint: cli`. See [`tests/AgenticCLIs/README.md`](tests/AgenticCLIs/README.md). |
| `ClaudeCodeTwinTests / EngineDigitalTwinTests` | `ClaudeCodeTwin` drives the real engine end-to-end without a live Claude login. |
| `ClaudeCodeTwinTests / TwinDecoderParityTests` | Twin hook payloads stay decodable by the production hook decoder. |
| `CodexAdapterTests / CodexAdapterTests` | Codex App Server framing, RPC, input encoding, policy mapping, catalog/index surfaces, and no-silent-failure behavior. |
| `CodexAdapterTests / LiveCodexIntegrationTests` | Opt-in live App Server stdio path (`CODEMIXER_LIVE_CODEX=1`): one `assistantText` through `CodexAdapter`. See [`tests/AgenticCLIs/README.md`](tests/AgenticCLIs/README.md). |
| `CodexTwinTests / CodexTwinTests` | `CodexTwin` drives fixture-backed App Server events without a live Codex login. |
| `ACPAdapterTests / ACPAdapterTests` | ACP framing, auth-required gate, custom factory, FS sandbox, session index, transport factory. |
| `ACPAdapterTests / LiveACPIntegrationTests` | Opt-in live ACP stdio path (`CODEMIXER_LIVE_ACP=1` + `CODEMIXER_LIVE_ACP_BIN`): one `assistantText` through `ACPAdapter`. See [`tests/AgenticCLIs/README.md`](tests/AgenticCLIs/README.md). |
| `ACPTwinTests / ACPTwinTests` | `ACPTwin` emits session + assistant text, or `authenticationRequired` when auth is required. |
| `AgentRemoteControlTests / PairingServiceTests` | Correct PIN yields a token; five wrong PINs trigger lockout. |
| `AgentRemoteControlTests / PairedDeviceStoreTests` | Paired-device persistence survives reload. |
| `AgentRemoteControlTests / RemoteControlE2ETests` | In-memory WebSocket clients receive replay, command results, and PTY write failures consistently; `sendPrompt` publishes `.userTurn` before a failing command result. |
| `AgentRemoteControlTests / LiveTLSTransportTests` | A fingerprint-pinned client exchanges bytes with a TLS server over loopback. |
| `AgentRemoteControlTests / CertificateManagerTests` | Self-signed TLS identity generation and fingerprint pinning. |
| `AgentRemoteControlTests / HTTPSidecarParsingTests` / `HTTPSidecarServerTests` | Sidecar route parsing; `/v1/health` and `/v1/attachments` staging. |
| `AgentRemoteControlTests / RemoteEngineClientTests` / `BonjourAdvertiserTests` / `BonjourBroadcasterTests` | Remote engine client handshake and Bonjour advertisement. |
| `RemoteParityTests / WireCodecParityTests` | Every `AgentEvent` shape survives `WireCodec.encode → decode` round-trip. |
| `RemoteParityTests / CommandDispatchParityTests` | Every `AgentCommand` case decodes and dispatches through the remote server to the command port. |
| `AgentUITests / EngineViewModelTests` | The reducer appends messages correctly and resets the status line on `.idle`. |
| `AgentUITests / EngineViewModelNavigatorTests` | Optimistic send and session-navigator actions reduce correctly. |
| `AgentUITests / InteractionCoverageTests` | Every `AgentCommand` shape is surfaced in the Mac UI or listed as an explicit remote-only exception. |
| `AgentUITests / SessionExporterTests` | A conversation exports to markdown, JSONL, and HTML, escaping text and skipping thinking blocks. |
| `AgentUITests / VoiceInputServiceTests` / `TTSStripMarkdownTests` / `SpeechCaptureTests` / `SpeechSynthesisTests` | Speech capture, TTS markdown stripping, and speech framework wrappers. |
| `AgentUITests / QRCodeRendererTests` / `SystemNotificationsTests` | QR rendering and system notification bridge. |

### Test conventions

- One **suite per behaviour**, not per file. Names are sentences (`"Late subscribers receive the replay history first"`).
- Production code never reads `Date()` or `getenv` directly — it asks one of the four DI seams (`Clock`, `RandomSource`, `Environment`, `FileSystem`). Tests inject the fakes from `AgentTestSupport`.
- Transport command failures use the internal `AgentTransport` seam, not timing-sensitive real-process crashes, so exact bytes and thrown errors are deterministic.
- Anything that needs a real binary (`/bin/echo`, `/bin/cat`) uses the system tool; we don't ship test fixtures for shell utilities.

Full treatment in `docs/style/code-style.md` §7 (Test aesthetic).

---

## Documentation map

The project intentionally over-documents the parts that other readers (you in three months, an LLM in three minutes, a new contributor in three days) will need to navigate.

| Document | Read when |
| --- | --- |
| [`README.md`](README.md) | First contact with the project. |
| [`AGENTS.md`](AGENTS.md) | You're an AI agent (or onboarding a new contributor) and want the high-signal pointers in one page. |
| [`docs/architecture.md`](docs/architecture.md) | Before touching `AgentEngine`, `MulticastEventBus`, `AgentAdapter`, the wire protocol, or any module boundary. |
| [`docs/style/code-style.md`](docs/style/code-style.md) | Before writing or reviewing any Swift file. |
| [`docs/style/visual-style.md`](docs/style/visual-style.md) | Before writing or reviewing any SwiftUI view. |
| [`docs/reference/`](docs/reference/) | When extracting a pattern into a different project, or authoring a new ADR or doc from scratch. |

Precedence when documents disagree: `architecture.md` wins on *structural decisions*; `code-style.md` wins on *how code reads*; `visual-style.md` wins on *visuals*; this README is a navigation aid, not a tiebreaker.

---

## Design pillars

If you only remember five things:

1. **The pty is invisible.** No terminal pane. Ever. SwiftTerm is used *headlessly* — we feed it bytes, we read snapshots, we never render its view.
2. **One typed input alphabet (`AgentCommand`), one typed output alphabet (`AgentEvent`).** Both the in-process UI and the remote WebSocket speak them. There is no second code path that can drift.
3. **The core is agent-agnostic; adapters carry per-vendor knowledge.** `AgentCore` and `AgentUI` never import any specific adapter; a new agent is a new module that conforms to `AgentAdapter`.
4. **Strict concurrency, deliberate isolation.** Engines are `actor`s. The bus is an `actor`. `@MainActor` is reserved for the UI seam. `@unchecked Sendable` is quarantined to two places (the SwiftTerm delegate bridge and the `NWConnection` callback box) and explicitly justified in a comment.
5. **Every behaviour is testable because every dependency is injected.** Four seams (`Clock`, `RandomSource`, `Environment`, `FileSystem`) plus the adapter protocol and internal `AgentTransport` seam mean the full engine runs in a unit test in milliseconds with no network, no filesystem, no real clock, and no flaky child-process failure timing.

The first file you should read to *feel* this aesthetic is [`PTYHost.swift`](src/Core/AgentCore/PTY/PTYHost.swift) — the reference exemplar. When something feels wrong, open `PTYHost` side-by-side; the contrast usually surfaces the answer.

---

## Contributing

Before opening a pull request:

1. **Read `AGENTS.md`** if you're new (or if you're an AI agent).
2. **Read `docs/style/code-style.md` once, fully.** §26 (Pre-merge review checklist) is the gate for every PR.
3. **`swift build && swift test --no-parallel`** both pass locally.
4. **Add tests for new behaviour.** Reducer changes, parser changes, and adapter changes always come with a test.
5. **One `AgentCommand` case per feature.** If your feature adds a UI button, it adds an enum case too. `RemoteParityTests` guard wire/dispatch parity; PTY-writing commands also need `AgentEngineCommandTests` byte and failure coverage.
6. **PR body** follows the template in `docs/reference/templates/pr.template.md`.
7. **No emojis in source.** Comments explain non-obvious intent; they don't narrate the code.

The reference exemplar for "how a file should read" is `src/Core/AgentCore/PTY/PTYHost.swift`. If your file feels harder to skim than that one, refactor before review.

---

## Roadmap

Tracked in detail in [`docs/architecture.md`](docs/architecture.md); the headline path:

- **Landed** — attachments, voice input + TTS, project picker, auth gate + install-Claude flow, settings pane, conversation search, session export, system notifications, git file/hunk revert, TLS + cert pinning, HTTP pairing sidecar, paired-device store, remote engine client, LaunchAgent install.
- **Next** — golden-fixture transcript tests against real Claude JSONL; signed + notarized `.app` release via the Xcode shell.
- **v1.0** — additional adapters (Cursor CLI / Gemini CLI / OpenCode), iOS client v0.1 over the remote-control API.
- **v1.1+** — Gemini CLI, OpenCode, Copilot, MCP tool surfacing in the renderer, automation scripts via SDK examples.

---

## License

MIT License — see [LICENSE](LICENSE) for the full text.

Codemixer is an independent project and is not affiliated with, endorsed by,
or sponsored by Anthropic. Claude and Claude Code are referenced only to
describe the compatible CLI adapter.
