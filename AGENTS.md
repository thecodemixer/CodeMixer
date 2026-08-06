# AGENTS.md

Companion file for AI coding agents (and fast-onboarding humans). Read this once, end-to-end, before editing anything. It is intentionally short — links carry the weight.

If you only have time for four sections: **[Read in this order](#read-in-this-order)**, **[Where things live](#where-things-live)**, **[Validate via the API path (not the GUI)](#validate-via-the-api-path-not-the-gui)**, **[Tripwires](#tripwires)**.

---

## What this project is

Codemixer is a native macOS workspace that drives agentic CLI agents behind a typed transport boundary. Claude Code runs under a **hidden** pseudo-terminal so it stays on Claude's interactive billing path and avoids the Agent Credits path used by third-party / SDK-style Claude Code invocations; Codex runs through App Server stdio JSON-RPC. The UI is pure SwiftUI driven by a typed `AgentEvent` stream. The same engine runs **headless** as `codemixerd` and exposes a typed WebSocket protocol so the GUI, a future iOS client, and CLI automation are all peer interaction surfaces.

The pillars:

1. Transports are invisible — no terminal pane, ever. PTY is Claude's transport implementation, not the engine model.
2. One typed input alphabet (`AgentCommand`), one typed output alphabet (`AgentEvent`). Every UI affordance maps to one `AgentCommand` case; every adapter byte maps to one `AgentEvent` case.
3. `AgentCore` and `AgentUI` are agent-agnostic. Per-vendor knowledge lives in adapter modules behind `AgentAdapter`.
4. Strict Swift 6 concurrency. Engines are `actor`s. `@MainActor` is the UI seam only. `@unchecked Sendable` is rare and always justified inline.
5. All side-effects route through four DI seams (`AgentClock`, `RandomSource`, `AgentEnvironment`, `FileSystem`). Tests inject fakes; production code never reads `Date()` or `getenv` directly.

---

## Read in this order

| # | File | Why |
| --- | --- | --- |
| 1 | [`README.md`](README.md) | Product surface + module map + build/run. |
| 2 | This file | High-signal pointers for editing. |
| 3 | [`scripts/README.md`](scripts/README.md) | Script catalog + usage. Read before creating or editing anything in `scripts/`. |
| 4 | [`docs/architecture.md`](docs/architecture.md) | The canonical *how-and-where*. **Required reading before touching `AgentEngine`, `MulticastEventBus`, `AgentAdapter`, the wire protocol, or any module boundary.** |
| 4b | [`src/AgenticCLIs/README.md`](src/AgenticCLIs/README.md) | **Required before adding or restructuring an agent CLI adapter** (`Adapter/` + `Common/` + `digital-twin/`). |
| 4c | [`src/Remote/AgentRemoteControl/README.md`](src/Remote/AgentRemoteControl/README.md) | **Required before touching remote control** — client role vs connected-peer count, server/client paths, GUI wiring. |
| 5 | [`docs/style/code-style.md`](docs/style/code-style.md) | The canonical *how code reads*. **Required reading before opening your editor.** §26 (Pre-merge review checklist) is the merge gate. |
| 6 | [`docs/style/visual-style.md`](docs/style/visual-style.md) | The canonical *how the product looks*. Required reading before any SwiftUI change. |
| 7 | [`src/Core/AgentCore/PTY/PTYHost.swift`](src/Core/AgentCore/PTY/PTYHost.swift) | **The reference exemplar.** When something feels wrong, open this file side-by-side. |

When documents disagree: plan > `architecture.md` (on structure) > `code-style.md` (on how code reads) > `visual-style.md` (on visuals) > README (navigation only).

---

## Where things live

### Top-level

```
Codemixer/
├── README.md, AGENTS.md
├── scripts/                                 local automation + validation helpers — [`scripts/README.md`](scripts/README.md)
├── docs/                                    architecture + style + reference patterns
├── Package.swift, src/, tests/               the SPM package (repo root)

```

### Inside `src/`

| You want to change… | Open… |
| --- | --- |
| The transport pipeline (spawn, read, write, close, test seam) | `Core/AgentCore/Transport/{AgentTransport,InteractiveTerminalTransport}.swift`, `Core/AgentCore/External/StdioJSONRPCTransport.swift` |
| The Claude PTY host (private to interactive terminal transport) | `Core/AgentCore/PTY/PTYHost.swift` |
| Child-process reaping | `Core/AgentCore/PTY/ChildReaper.swift` |
| Wrap a new Apple/system framework call (`Process`, `SecItem*`, `FSEventStream*`, etc.) | `Core/AgentCore/External/*.swift`, `AgentUI/External/*.swift`, `Remote/AgentRemoteControl/External/*.swift` — see `docs/reference/wrappers.md` |
| The C shim around `openpty` / `posix_spawn` | `Core/CPosixBridge/CPosixBridge.{h,c}` |
| The interactive-shell environment resolver | `Core/AgentCore/PTY/ShellEnvironmentResolver.swift` |
| Headless terminal emulation (SwiftTerm) | `Core/AgentCore/Terminal/TerminalEngine.swift` |
| The typed event alphabet | `Core/AgentCore/Events/AgentEvent.swift` |
| Client-owned conversation markers (mode / model / slash / permission / session) | `Core/AgentProtocol/ClientAction.swift` (`AgentCommand.recordClientAction` / `AgentEvent.clientAction`) |
| The adapter protocol or supporting types | `Core/AgentCore/Events/AgentAdapter.swift`, `SupportingTypes.swift`, `AgentID.swift`, `Core/AgentCore/Transport/AgentTransport.swift` |
| The error model | `Core/AgentCore/Events/AgentError.swift` |
| Wire codec (domain ↔ wire) | `Core/AgentCore/Events/WireCodec.swift` |
| The event bus / ring buffer | `Core/AgentCore/Bus/MulticastEventBus.swift` |
| The orchestrator | `Core/AgentCore/Engine/AgentEngine.swift`, `AgentEngine+Commands.swift` |
| Engine state reduction | `Core/AgentCore/Engine/AgentEngine.swift` (`EngineState`), `AgentUI/ViewModel/EngineViewModel.swift` |
| Conversation/diff snapshots for late clients | `Core/AgentCore/Engine/SnapshotService.swift` |
| Durable project-local conversation domain + listing | `Core/AgentCore/Conversation/{SessionTranscript,TranscriptEntry,TranscriptMutation,SessionTranscriptRepository}*.swift` |
| Transcript JSONL/index persistence | `Core/AgentCore/Persistence/{ProjectSessionTranscriptStore,StoredSessionRecord}*.swift` |
| Git file/hunk revert | `Core/AgentCore/Engine/GitReverter.swift` |
| Hook UDS server | `Core/AgentCore/Hooks/HookServer.swift` |
| FSEvents watcher | `Core/AgentCore/FS/FSEventsWatcher.swift` |
| Git diff engine | `Core/AgentCore/Diff/GitDiffEngine.swift`, `DiffModels.swift` |
| Attachment resolution + persistence | `Core/AgentCore/Attachments/AttachmentResolver.swift` |
| Network transport abstraction (live / in-memory / logging) | `Core/AgentCore/Network/{NetworkTransport,LiveNetworkTransport,InMemoryNetworkTransport,LoggingNetworkTransport}.swift` |
| Status phrase priority | `Core/AgentCore/Status/StatusPhraseResolver.swift` |
| Activity heartbeat | `Core/AgentCore/Activity/HeartbeatActivityMonitor.swift` |
| Prefs / sessions / appearance persistence | `Core/AgentCore/Persistence/{PrefsStore,SessionStore,AppearancePrefs}.swift` |
| Agent-agnostic Workspace→Projects model + persistence | `Core/AgentCore/Persistence/{WorkspaceProjectsStore,ProjectType,ProjectAgentRouter,ProjectLocalState,WorkspaceLocalState,WorkspaceAdapterLocalState}.swift` (per-adapter model caches in `workspace-<AgentID>.json`) |
| Core framework wrappers (Process, process liveness, Keychain, FSEvents) | `Core/AgentCore/External/{ProcessRunner,ProcessInspector,KeychainStore,FSEventsStream}.swift` |
| Product constants (ports, identity, timing, buffers, paths) | `Core/AgentCore/{RemoteDefaults,RemoteAuthTiming,DaemonDefaults,AppIdentity,ActivityTiming,StreamBufferDefaults}.swift`, `Core/AgentCore/Paths/{AppSupportPaths,SystemPaths,ProjectPaths}.swift` |
| DI seams | `Core/AgentCore/Seams/{Clock,RandomSource,Environment,FileSystem,Seams}.swift` |
| Claude binary lookup | `AgenticCLIs/ClaudeCode/Adapter/ClaudeBinaryLocator.swift` |
| Shared Claude path/input/catalog helpers | `AgenticCLIs/ClaudeCode/Common/*.swift` |
| Claude hook installer | `AgenticCLIs/ClaudeCode/Adapter/ClaudeHookSettings.swift` |
| Claude hook decoder | `AgenticCLIs/ClaudeCode/Adapter/ClaudeHookDecoder.swift` |
| Claude transcript tailer | `AgenticCLIs/ClaudeCode/Adapter/ClaudeTranscriptTailer.swift` |
| Claude one-shot session catalog importer | `AgenticCLIs/ClaudeCode/Common/ClaudeSessionCatalogImporter.swift` |
| Claude slash commands | `AgenticCLIs/ClaudeCode/Adapter/ClaudeSlashCommands.swift` |
| Claude TUI scrape fallback | `AgenticCLIs/ClaudeCode/Adapter/ClaudeTUIFallback.swift` |
| Claude adapter top-level | `AgenticCLIs/ClaudeCode/Adapter/ClaudeAdapter.swift` |
| Claude digital twin | `AgenticCLIs/ClaudeCode/digital-twin/Twin/` |
| Live Claude harness (opt-in tests) | `tests/AgenticCLIs/ClaudeCode/ClaudeAdapterTests/LiveClaudeHarness.swift` — docs in `tests/AgenticCLIs/README.md` |
| Codex binary lookup | `AgenticCLIs/Codex/Adapter/CodexBinaryLocator.swift` |
| Codex adapter top-level | `AgenticCLIs/Codex/Adapter/CodexAdapter.swift` |
| Codex App Server protocol helpers | `AgenticCLIs/Codex/Common/*.swift` |
| Codex one-shot session catalog importer | `AgenticCLIs/Codex/Common/CodexSessionCatalogImporter.swift` |
| Codex digital twin | `AgenticCLIs/Codex/digital-twin/Twin/CodexTwin.swift` |
| Live Codex harness (opt-in tests) | `tests/AgenticCLIs/Codex/CodexAdapterTests/LiveCodexHarness.swift` — docs in `tests/AgenticCLIs/README.md` |
| ACP adapter top-level | `AgenticCLIs/AgentClientProtocol/Adapter/ACPAdapter.swift` |
| ACP framing / codec / catalog import / reverse FS+terminal | `AgenticCLIs/AgentClientProtocol/Common/*.swift` |
| ACP dashboard / attention / parked permissions | `ACPEventDecoder` (`agentDashboard`, `sessionAttentionChanged`); background `session/request_permission` parks until `session/load` |
| ACP reverse-terminal process wrapper | `AgenticCLIs/AgentClientProtocol/External/ACPTerminalProcess.swift` |
| ACP digital twin | `AgenticCLIs/AgentClientProtocol/digital-twin/Twin/ACPTwin.swift` |
| A2UI wire DTOs (schema profile, typed component body + per-component props, dynamic/action/resolved value types, opaque unknown replay, function name, theme, server message shapes, batch/interaction/action/client-error envelopes) | `Core/AgentProtocol/A2UI/{A2UISchemaProfile,A2UIComponent,A2UIDynamicValue,A2UIAction,A2UIResolvedValue,A2UIOpaqueJSON,A2UIFunctionName,A2UIServerMessage,A2UIServerBatch}.swift` — the public A2UI boundary is fully typed: `A2UIComponentBody` (associated per-component `*Props`), `A2UIDynamic{Value,String,Number,Boolean,StringList}`, `A2UIAction`, `A2UIResolvedValue` / `A2UIDataDocument` / `A2UILocalOverlay`, `A2UIJSONPointerPath`, `A2UIFunctionName`. **Zero `JSONValue` on the public surface** — no bare `JSONValue`, no `[String: JSONValue]` property bag, and no public wire-JSON accessor. Unknown catalogs/kinds are preserved losslessly via `A2UIOpaqueComponent`/`A2UIOpaqueJSON`; every wire seam (`A2UIComponent.decodeKnown(json:)`, `A2UIActionEnvelope.contextWireJSON`, the opaque raw accessors) is `package`, so public callers only ever see `Codable` plus typed values. See `docs/architecture.md` §36.1a |
| A2UI core logic (limits, catalog descriptor, JSON Pointer, canonical surface state, validator, reducer, evaluator, text summary, action resolver) | `Core/A2UICore/*.swift` |
| A2UI engine command handling (`submitA2UIInteraction`/`reportA2UIClientError`, the client→server trust boundary) | `Core/AgentCore/Engine/AgentEngine+A2UI.swift` |
| A2UI durable transcript entry/mutation | `Core/AgentCore/Conversation/{TranscriptEntry,TranscriptMutation,SessionTranscript,SessionTranscriptRepository}.swift` (`.a2uiSurface` case, `applyA2UIBatch`) |
| A2UI ACP decode (MIME-typed `EmbeddedResource` → typed batch) | `AgenticCLIs/AgentClientProtocol/Common/ACPEventDecoder+A2UI.swift`, hooked from `ACPEventDecoder+Streaming.swift` |
| A2UI ACP encode (capability advertisement, action, client-error) | `AgenticCLIs/AgentClientProtocol/Common/ACPInputEncoding.swift` (`bootstrap`, `a2uiAction`, `a2uiClientError`) |
| A2UI `EngineViewModel` bridge (submits a rendered interaction as a command) | `AgentUI/ViewModel/EngineViewModel+A2UI.swift` |
| A2UI native SwiftUI Basic Catalog renderer | `AgentUI/Conversation/A2UISurfaceView.swift` |
| Shipping ACP CLIs (Cursor) | `AgenticCLIs/ACPCLIs/Cursor/` — `CursorACPAdapter`, binary locator, mode commands |
| Cursor catalog import + SQLite wrapper | `AgenticCLIs/ACPCLIs/Cursor/{Common,External}/` |
| Custom ACP CLIs | `AgenticCLIs/ACPCLIs/Custom/` — `CustomACPAdapter` + `CustomACPAdapterFactory`; project `.codemixer/acp/<id>/` |
| Custom ACP factory registration | `CustomACPAdapterFactory` (Bootstrap/daemon); bare `ACPCustomAgentAdapterFactory` for unit tests |
| Live ACP harness (opt-in tests) | `tests/AgenticCLIs/AgentClientProtocol/ACPAdapterTests/LiveACPHarness.swift` — docs in `tests/AgenticCLIs/README.md` |
| Live Cursor ACP harness (opt-in) | `tests/AgenticCLIs/ACPCLIs/CursorACPCLITests/LiveCursorACPHarness.swift` |
| Live Custom ACP harness (opt-in) | `tests/AgenticCLIs/ACPCLIs/CustomACPCLITests/LiveCustomACPHarness.swift` |
| Fake Custom ACP twin | `swift build --product fake-custom-acp` — `ACPCLIs/Custom/digital-twin/fake-custom-acp/` |
| Agentic CLI layout convention | `AgenticCLIs/README.md` |
| The wire DTOs (Foundation-only) | `Core/AgentProtocol/{AgentCommand,AgentEventWire,WireFrames,Decisions,Prefs,AttachmentRef,WireVersion}.swift` |
| WebSocket server | `Remote/AgentRemoteControl/RemoteControlServer.swift`, `ClientConnection.swift` |
| Pairing PIN + bearer tokens | `Remote/AgentRemoteControl/PairingService.swift` |
| Paired-device persistence | `Remote/AgentRemoteControl/PairedDeviceStore.swift` |
| TLS identity + cert pinning | `Remote/AgentRemoteControl/CertificateManager.swift`, `External/CertificateIdentityImporter.swift` |
| HTTP sidecar (`/v1/health`, `/v1/attachments`) | `Remote/AgentRemoteControl/HTTPSidecarServer.swift` |
| Remote module contract + terminology | `Remote/AgentRemoteControl/README.md` |
| Client-role wire consumer (`AgentEngineCommandPort`) | `Remote/AgentRemoteControl/RemoteEngineClient.swift` — `Bootstrap.remoteClient` in Mode B |
| WebSocket server + connected-peer count | `Remote/AgentRemoteControl/RemoteControlServer.swift` — `observeClientCount`, `connectedClientCount` |
| Shared daemon/GUI remote bootstrap | `Remote/AgentRemoteControl/RemoteRuntimeCoordinator.swift` |
| Bonjour advertisement | `Remote/AgentRemoteControl/BonjourAdvertiser.swift`, `External/BonjourBroadcaster.swift` |
| Theme tokens (color, type, spacing, motion) | `AgentUI/Theme/Theme.swift` |
| Progressive disclosure modifier | `AgentUI/Theme/IntentReveal.swift` |
| The observable view model | `AgentUI/ViewModel/EngineViewModel.swift` |
| Chat workbench turn/phase projection (`ConversationTurn`, rail badges, recap, peripheral progress) | `AgentUI/ViewModel/EngineViewModel+Turns.swift` |
| Activity primitives (`ShimmerDots`, `InlineStatusTicker`, `StatusPill`) | `AgentUI/Activity/ActivityViews.swift` |
| Conversation views (bubbles, prose, thinking blocks) | `AgentUI/Conversation/MessageViews.swift` |
| Markdown block parsing + prose/code rendering | `AgentUI/Conversation/{MarkdownBlock,MarkdownProseView,CodeBlockView,CodeSyntaxHighlighter}.swift` |
| Conversation motion (arriving rows, turn spine, streaming caret, empty-state hero) | `AgentUI/Conversation/ConversationMotion.swift` |
| Tool-call card (rendered inline in turn order) | `AgentUI/Conversation/ToolCallCardView.swift` |
| Live/selected turn's prominent thinking card (deviates from collapsed-by-default; see `docs/style/visual-style.md` §13.3) | `AgentUI/Conversation/ThinkingFocusView.swift` |
| Permission prompt | `AgentUI/Conversation/PermissionPromptView.swift` |
| Agent dashboard WebView (Custom ACP overview) | `AgentUI/Dashboard/AgentDashboardView.swift` |
| WKWebView wrapper | `AgentUI/External/WebViewRepresentable.swift` |
| Chat workbench root (3-lane layout, `ViewThatFits` breakpoints, Focus mode) | `AgentUI/Workbench/ConversationWorkbenchView.swift` |
| Index rail (turn list, phase groups, round/ETA/attention badges, jump-to-live) | `AgentUI/Workbench/IndexRailView.swift` |
| Transcript lane (prose/thinking only — tool calls excluded, see Work lane) | `AgentUI/Workbench/TranscriptLaneView.swift` |
| Work lane (live tool calls, changed files, diff hunks) | `AgentUI/Workbench/WorkLaneView.swift` |
| Per-session phase mini-map / scrubber (rendered by the rail when `hasPhaseData`) | `AgentUI/Workbench/SessionScrubber.swift` |
| "While-you-were-away" recap banner | `AgentUI/Workbench/AwayRecapBanner.swift` |
| Session navigator (projects → sessions, icon-rail focus mode; attention rollup badge) | `AgentUI/Sidebar/SessionSidebarView.swift` |
| Cmd+K command palette | `AgentUI/Palette/CommandPaletteView.swift` |
| Composer (prompt input, modes, mic, send/cancel) | `AgentUI/Composer/{PromptComposerView,PromptComposerSupportViews,PromptComposerDraftLogic,ComposerAttachmentHandling}.swift` |
| Silent diagnostics (opt-in) | `AgentUI/Debug/SilentDiagnosticsView.swift`, `Core/AgentCore/Diagnostics/SilentDiagnostics.swift` |
| Changed-files reconcile | `Core/AgentCore/Engine/ChangedFilesReconciler.swift` |
| Appearance at root | `AgentUI/Theme/AppearanceModifiers.swift`, applied from `CodemixerApp/RootView.swift` |
| Bootstrap (Mode B probe, notifications) | `CodemixerApp/Bootstrap.swift`, `Bootstrap+Remote.swift` |
| Diff panel | `AgentUI/Diff/DiffPanelView.swift` |
| Settings pane | `AgentUI/Settings/SettingsView.swift` |
| Project picker | `AgentUI/Pickers/ProjectPickerView.swift` |
| Conversation search | `AgentUI/Search/ConversationSearchBar.swift` |
| Session export | `AgentUI/Export/SessionExporter.swift` |
| Voice input + TTS | `AgentUI/Voice/{VoiceInputService,TTSService}.swift` |
| Auth / install errors (CLI guidance, no in-app auth sheets) | Adapters emit `authenticationRequired` / `binaryNotFound`; Bootstrap surfaces `startupError` |
| Notifications bridge | `AgentUI/Notifications/UserNotificationBridge.swift` |
| Cost badge + shared primitives | `AgentUI/Components/{CostBadgeView,Primitives}.swift` |
| Debug terminal / event-log inspectors | `AgentUI/Debug/{DebugTerminalSheet,EventLogView}.swift` |
| UI framework wrappers (desktop, speech, QR, notifications) | `AgentUI/External/{DesktopActions,SpeechCapture,SpeechSynthesis,QRCodeRenderer,SystemNotifications}.swift` |
| Command/event interaction coverage map | `AgentUI/Interaction/InteractionCoverage.swift` |
| Root scene (split view) | `AgentUI/Workspace/WorkspaceScene.swift` |
| Shared create/open workspace paths (catalog warm) | `AgentUI/Workspace/WorkspaceLifecycle.swift` |
| Per-adapter catalog failures / Not loaded projects | `EngineViewModel.modelCatalogLoadFailures`, `loadedProjects` / `unloadedProjects` (`EngineViewModel+NavigatorModels.swift`); sidebar in `SessionSidebarView` |
| GUI app entry point | `CodemixerApp/CodemixerApp.swift`, `RootView.swift` |
| LaunchAgent installer | `CodemixerApp/External/LaunchAgentInstaller.swift` |
| Daemon entry point | `Remote/CodemixerDaemon/main.swift` |

### Remote client terminology

**Remote client** names a *role*, not one type. Two symbols trip people up:

| You mean… | Open… | Property / API |
| --- | --- | --- |
| A process driving the engine over WSS (Mode B GUI, phone, script) | `Remote/AgentRemoteControl/RemoteEngineClient.swift` | `Bootstrap.remoteClient` |
| How many peers are attached to the server | `Remote/AgentRemoteControl/RemoteControlServer.swift` | `connectedClientCount` → `EngineViewModel.connectedRemoteClients` → `ConnectedClientsChip` |

- **Mode A (default):** GUI uses in-process `AgentEngine`. Connected count is external peers only (after enabling remote access).
- **Mode B:** GUI uses `RemoteEngineClient` on loopback and **is** counted as one connected peer on the daemon.

Canonical write-up: [`docs/architecture.md` §4.1](docs/architecture.md). Module map: [`src/Remote/AgentRemoteControl/README.md`](src/Remote/AgentRemoteControl/README.md).

### Inside `tests/`

```
tests/
├── TestSupport/
│   ├── AgentTestSupport/           # shared fakes (Clock, FS, MockAdapter)
│   └── AgentTestSupportTests/
├── Core/                           # AgentProtocolTests, AgentCoreTests, A2UICoreTests
├── Remote/                         # AgentRemoteControlTests, RemoteParityTests
├── AgenticCLIs/                    # per-agent adapter + twin suites — see AgenticCLIs/README.md
│   └── ClaudeCode/
│       ├── ClaudeAdapterTests/
│       └── ClaudeCodeTwinTests/
└── AgentUITests/
```

| Shared test library | Lives in |
| --- | --- |
| Test fakes (Clock, Random, Env, FS) + (Recording)MockAdapter | `TestSupport/AgentTestSupport/*.swift` |
| Fake seam self-tests | `TestSupport/AgentTestSupportTests/*.swift` |

### Inside `tests/` (suites)

| Suite | Lives in |
| --- | --- |
| Wire frame round-trip | `Core/AgentProtocolTests/WireFrameRoundTripTests.swift` |
| A2UI schema/limits/catalog/pointer/state/validator/reducer/evaluator/text-summary/action-resolver | `Core/A2UICoreTests/*.swift` |
| Prefs + decisions Codable | `Core/AgentProtocolTests/PrefsAndDecisionsCodableTests.swift` |
| PTY lifecycle | `Core/AgentCoreTests/PTYHostTests.swift` |
| Child reaping | `Core/AgentCoreTests/ChildReaperTests.swift` |
| AgentCommand dispatch, transport bytes, write-failure propagation | `Core/AgentCoreTests/AgentEngineCommandTests.swift` |
| Engine integration (end-to-end) | `Core/AgentCoreTests/EngineIntegrationTests.swift` |
| Local transcript aggregation, repository, store, and activation | `Core/AgentCoreTests/{SessionTranscriptTests,SessionTranscriptRepositoryTests,ProjectSessionTranscriptStoreTests,AgentEngineSessionHistoryTests}.swift` |
| Conversation/diff snapshots | `Core/AgentCoreTests/SnapshotServiceTests.swift` |
| Terminal engine snapshots | `Core/AgentCoreTests/TerminalEngineTests.swift` |
| Multicast bus replay + live fan-out | `Core/AgentCoreTests/MulticastEventBusTests.swift` |
| Git diff parsing | `Core/AgentCoreTests/GitDiffEngineTests.swift` |
| Git file/hunk revert integration | `Core/AgentCoreTests/GitRevertIntegrationTests.swift` |
| Attachment resolution | `Core/AgentCoreTests/AttachmentResolverTests.swift` |
| Hook UDS server | `Core/AgentCoreTests/HookServerTests.swift` |
| FSEvents watcher + stream wrapper | `Core/AgentCoreTests/{FSEventsWatcherTests,FSEventsStreamTests}.swift` |
| Process / Keychain wrappers | `Core/AgentCoreTests/{ProcessRunnerTests,KeychainStoreTests}.swift` |
| Shell env NUL parsing | `Core/AgentCoreTests/ShellEnvResolverTests.swift` |
| ResolvedEnvironment PATH/helpers | `Core/AgentCoreTests/ResolvedEnvironmentTests.swift` |
| AgentError Codable + equality | `Core/AgentCoreTests/AgentErrorTests.swift` |
| Git changed-files porcelain parsing | `Core/AgentCoreTests/{ChangedFilesParsingTests,ChangedFilesReconcilerTests}.swift` |
| Silent diagnostics ring | `Core/AgentCoreTests/SilentDiagnosticsTests.swift` |
| Status phrase priority | `Core/AgentCoreTests/StatusPhraseResolverTests.swift` |
| Activity heartbeat escalation | `Core/AgentCoreTests/HeartbeatActivityMonitorTests.swift` |
| Prefs / sessions persistence | `Core/AgentCoreTests/{PrefsStoreTests,SessionStoreTests,AppearancePrefsTests}.swift` |
| Workspace→Projects model + persistence | `Core/AgentCoreTests/WorkspaceProjectsStoreTests.swift` |
| Unix-socket transport | `Core/AgentCoreTests/UnixSocketTransportTests.swift` |
| Public-API coverage manifest | `Core/AgentCoreTests/{CoverageManifest,PublicAPITests}.swift` |
| Hook installer idempotence | `AgenticCLIs/ClaudeCode/ClaudeAdapterTests/HookInstallerTests.swift` |
| Hook decoder + transcript tailer | `AgenticCLIs/ClaudeCode/ClaudeAdapterTests/{ClaudeHookDecoderTests,TranscriptTailerTests,TranscriptTruncationTests}.swift` |
| Adapter event stream + binary locator | `AgenticCLIs/ClaudeCode/ClaudeAdapterTests/{ClaudeAdapterEventStreamTests,ClaudeBinaryLocatorTests}.swift` |
| Slash commands + catalog import | `AgenticCLIs/ClaudeCode/ClaudeAdapterTests/{ClaudeSlashCommandsTests,ClaudeSessionCatalogImporterTests}.swift` |
| TUI fallback gating | `AgenticCLIs/ClaudeCode/ClaudeAdapterTests/{TUIFallbackTests,TUIFallbackGateTests}.swift` |
| Twin decoder parity (adapter + twin) | `AgenticCLIs/ClaudeCode/{ClaudeAdapterTests,ClaudeCodeTwinTests}/TwinDecoderParityTests.swift` |
| Fake-claude spawned integration | `AgenticCLIs/ClaudeCode/ClaudeAdapterTests/FakeClaudeIntegrationTests.swift` |
| Live Claude harness (opt-in) | `AgenticCLIs/ClaudeCode/ClaudeAdapterTests/{LiveClaudeHarness,LiveClaudeIntegrationTests}.swift` — see [`tests/AgenticCLIs/README.md`](tests/AgenticCLIs/README.md) |
| Claude digital twin + engine E2E | `AgenticCLIs/ClaudeCode/ClaudeCodeTwinTests/{EngineDigitalTwinTests,TwinDecoderParityTests}.swift` |
| Codex adapter protocol + live harness | `AgenticCLIs/Codex/CodexAdapterTests/{CodexAdapterTests,LiveCodexHarness,LiveCodexIntegrationTests}.swift` — see [`tests/AgenticCLIs/README.md`](tests/AgenticCLIs/README.md) |
| Codex digital twin | `AgenticCLIs/Codex/CodexTwinTests/CodexTwinTests.swift` |
| ACP adapter + factory + framing | `AgenticCLIs/AgentClientProtocol/ACPAdapterTests/ACPAdapterTests.swift` |
| Live ACP harness (opt-in) | `AgenticCLIs/AgentClientProtocol/ACPAdapterTests/{LiveACPHarness,LiveACPIntegrationTests}.swift` — see [`tests/AgenticCLIs/README.md`](tests/AgenticCLIs/README.md) |
| ACP digital twin | `AgenticCLIs/AgentClientProtocol/ACPTwinTests/ACPTwinTests.swift` |
| Cursor ACP adapter + fake/live harness | `AgenticCLIs/ACPCLIs/CursorACPCLITests/` — see [`tests/AgenticCLIs/README.md`](tests/AgenticCLIs/README.md) |
| Custom ACP adapter + project store + fake/live | `AgenticCLIs/ACPCLIs/CustomACPCLITests/` — see [`tests/AgenticCLIs/README.md`](tests/AgenticCLIs/README.md) |
| FakeClock virtual sleep | `TestSupport/AgentTestSupportTests/FakeClockTests.swift` |
| Pairing PIN + lockout | `Remote/AgentRemoteControlTests/PairingServiceTests.swift` |
| Paired-device store | `Remote/AgentRemoteControlTests/PairedDeviceStoreTests.swift` |
| Remote-control E2E, replay, command errors, PTY write failures | `Remote/AgentRemoteControlTests/RemoteControlE2ETests.swift` |
| Live TLS transport handshake | `Remote/AgentRemoteControlTests/LiveTLSTransportTests.swift` |
| Certificate manager | `Remote/AgentRemoteControlTests/CertificateManagerTests.swift` |
| HTTP sidecar parsing + server | `Remote/AgentRemoteControlTests/{HTTPSidecarParsingTests,HTTPSidecarServerTests}.swift` (includes `/v1/diagnostics/silent`) |
| Remote engine client + Bonjour | `Remote/AgentRemoteControlTests/{RemoteEngineClientTests,BonjourAdvertiserTests,BonjourBroadcasterTests}.swift` |
| Wire-codec parity | `Remote/RemoteParityTests/WireCodecParityTests.swift` |
| Command dispatch parity | `Remote/RemoteParityTests/CommandDispatchParityTests.swift` |
| View-model reduction | `AgentUITests/EngineViewModelTests.swift` |
| Optimistic send + navigator actions | `AgentUITests/EngineViewModelNavigatorTests.swift` |
| Chat workbench turns/phases (`conversationTurns`, `sessionPhaseChanged`, rail badges, recap, peripheral progress) | `AgentUITests/EngineViewModelTurnsTests.swift` |
| Density-mode spacing scale (`.comfortable`/`.compact`/`.focus`) | `AgentUITests/AppearanceModifiersTests.swift` |
| Chat workbench lane visibility (rail/work-lane per density, `WorkLaneView.hasContent`) | `AgentUITests/ConversationWorkbenchLaneVisibilityTests.swift` |
| Workspace create/open model-catalog warm | `AgentUITests/WorkspaceLifecycleTests.swift` |
| Interaction coverage (every command/event surfaced) | `AgentUITests/InteractionCoverageTests.swift` |
| Session export | `AgentUITests/SessionExporterTests.swift` |
| Voice + TTS + speech wrappers | `AgentUITests/{VoiceInputServiceTests,TTSStripMarkdownTests,SpeechCaptureTests,SpeechSynthesisTests}.swift` |
| QR + system notifications | `AgentUITests/{QRCodeRendererTests,SystemNotificationsTests}.swift` |

---

## Common tasks

### Add a new `AgentCommand` case

1. Add the case to `Core/AgentProtocol/AgentCommand.swift`.
2. Handle it in `Core/AgentCore/Engine/AgentEngine.swift` (`send(_:)`).
3. Wire a UI affordance in `AgentUI/` (typically in the composer, a context menu, or a settings pane).
4. If the command writes to the transport, add/extend `AgentEngineCommandTests` with
 exact `AgentTransport.write` bytes and write-failure propagation. For multi-step
   lifecycle commands, cover each write point separately.
5. Update `Remote/RemoteParityTests` if a new wire round-trip needs coverage, and add
   `Remote/AgentRemoteControlTests/RemoteControlE2ETests` coverage when remote clients need a specific result
   or event ordering guarantee.
6. Confirm `scripts/swift-test.swift` is green.

### Add a new `AgentEvent` case

1. Add the case to `Core/AgentCore/Events/AgentEvent.swift`.
2. Add the mirror to `Core/AgentProtocol/AgentEventWire.swift`.
3. Add both `encode`/`decode` arms to `Core/AgentCore/Events/WireCodec.swift`.
4. Add a case to `Remote/RemoteParityTests/WireCodecParityTests.swift`.
5. Reduce it in `AgentUI/ViewModel/EngineViewModel.swift` (or document why it's intentionally not reduced).
6. Update exhaustive consumers (`EventLogView`, exporters) and regenerate the coverage manifest.

### Make an agent-affecting UI action visible in chat

Use `ClientAction` + `AgentCommand.recordClientAction` (see `Core/AgentProtocol/ClientAction.swift`). Prefer `EngineViewModel.selectAgentMode` / `selectModel` / `setPermissionMode` / `activateSlashCommand` / `respondToPermission` / `startNewSession` / `compactContext` / `recordAndSend` rather than inventing a second local-only history store.

**Do not** write markers into Claude/Codex/Cursor session files. Action rows are
persisted in Codemixer's project-local `SessionTranscript`, so they reappear on
reopen/resume without mutating vendor history.

### Give a custom ACP tool richer UI than markdown prose

Use A2UI instead of hand-rolled text-sniffing in `AgentUI` — see
`docs/architecture.md` §36 for the full wire/trust-boundary walkthrough.

1. In the custom ACP server, require the client to have advertised
   `A2UISchemaProfile.clientCapabilitiesMetaKey` at `initialize` and **fail the
   handshake** when it has not. Do **not** add a plain-text fallback: a silent
   degrade surfaces later as raw JSON in chat and hides the real cause (a stale
   client) for hours. Fail at the handshake, where the message can name the
   missing capability.
2. Emit `createSurface` + `updateComponents` (+ `updateDataModel` if needed)
   as one `session/update`/`tool_call` content block: `{ type: "resource",
   resource: { uri, mimeType: "application/a2ui+json", text } }` using the
   Basic Catalog subset (`Card`/`Column`/`Row`/`Text`/`Divider`/`Button`).
3. For a server-bound decision, give the relevant `Button` component an
   `action: { event: { name, context } }` and correlate the returned
   `clientAction` back to your pending state — add a nonce to `context` if the
   action must not be replayable.
4. Delete-then-recreate a surface id when its content structurally changes;
   CodeMixer bumps the surface's generation on `deleteSurface`, so a stale
   client-side interaction against the old generation is rejected rather
   than silently misapplied.
5. **Do not** add a new heuristic to `AgentUI` for your tool's structured
   output — `A2UISurfaceView` renders any Basic Catalog surface generically.
   If it needs a component the Basic Catalog doesn't have, that's a
   catalog/spec gap, not a reason to special-case text in `AgentUI`.

### Add a new adapter (e.g. CursorCLI)

1. Scaffold `src/AgenticCLIs/<AgentName>/` with `Adapter/`, `Common/`, `digital-twin/`, and contract `README.md` — see [`src/AgenticCLIs/README.md`](src/AgenticCLIs/README.md).
2. New SPM library target + product under that path; top-level type conforming to `AgentAdapter`.
3. Declare `transportDescriptor` (`.interactiveTerminal`, `.stdioJSONRPC`, or a real future ACP descriptor) and the relevant `AgentCapabilities`.
4. Implement `sessionBootstrapBytes(context:)` and `encodeCommand(_:)` when the agent is not Claude slash-text compatible.
5. If the CLI has selectable chat modes (Claude Think/Review, Cursor agent/plan/ask, …), override `availableAgentModes()` returning `[AgentModeOption]` — never hardcode the vendor's modes in `AgentUI`; the composer bottom-bar dropdown renders whatever the active adapter publishes.
6. Override `availableModels()` / `refreshModelCatalog()` as needed. Prefer `.automatic` (daily disk cache via `WorkspaceLifecycle` + `workspace-<AgentID>.json`) unless discovery is expensive — then use `.manual(detail:)` so that adapter's catalog is persisted without a daily TTL (Claude Code pattern).
7. Register at startup: `await AdapterRegistry.shared.register(CodexAdapter())`.
8. Add a test target under `tests/AgenticCLIs/<AgentName>/` with at least a smoke test that the adapter constructs — see [`tests/AgenticCLIs/README.md`](tests/AgenticCLIs/README.md).
9. **Do not** add any import of the new adapter inside `AgentCore` or `AgentUI`.

Full recipe in `docs/reference/patterns/plugin-adapter-protocol.md`. Canonical model-catalog rules: [`docs/architecture.md` § Model catalogs](docs/architecture.md#model-catalogs).

### Add a new SwiftUI view

1. Place it under the right subfolder of `AgentUI/`.
2. Use `Theme.*` tokens. **Never** use literal colors, fonts, or magic spacing numbers.
3. Use `IntentReveal` for secondary actions instead of always-on toolbars.
4. Add an `accessibilityLabel` on every interactive element.
5. Keep `@MainActor` to the view itself; never put it on engine/adapter/core types.

### Add a new test

- Use Swift Testing (`import Testing`).
- One `@Suite` per behaviour; suite name reads like a sentence.
- `@Test` names also read like sentences.
- Inject fakes from `AgentTestSupport` — never read the real clock, random, env, or filesystem.
- Cover behaviour on the **API path** (`AgentCommand` / `AgentEvent` / adapter encode-decode / engine harness) — see [Validate via the API path (not the GUI)](#validate-via-the-api-path-not-the-gui). Do not treat a SwiftUI click path as sufficient coverage.
- **Live/opt-in probes** (`Live*Harness`, `LiveGUIPathProbeTests`, `LiveRuntimePoolProbeTests`) must take workspace/project paths from env vars (`CODEMIXER_LIVE_*`) or neutral placeholders (`/path/to/…`, `$HOME/…`, `/workspace/…` fixtures). Never commit a real macOS home-directory path. After adding or editing paths in tests or docs, run `swift scripts/check-no-personal-paths.swift`.

### Validate via the API path (not the GUI)

The product surface is the typed alphabet — `AgentCommand` in, `AgentEvent` out — plus the adapter wire that carries those into CLIs. The GUI is one consumer of that alphabet, not the system under test.

**Rule:** nothing required for correctness may depend on a GUI-only path. Unit, integration, and live validation all drive Codemixer through the API (in-process `AgentEngine.send`, ACP encode/decode, or the remote WebSocket command port). When a human asks an AI agent to “run live and test”, use that API path — not Codemixer.app click-through, screenshots, or computer-use against SwiftUI.

| Do | Don’t |
| --- | --- |
| `scripts/swift-test.swift` (and `--filter …`) for unit/integration; `--allow-live` only for intentional live harnesses | Raw `swift test` while leftover `CODEMIXER_LIVE_*=1` / `MIGRATION_LIVE=1` are exported (looks like a hang) |
| `AgentEngine.send(.submitA2UIInteraction(…))` / `.reportA2UIClientError(…)` / other commands | Click `A2UISurfaceView` buttons in the GUI to prove the trust boundary |
| Assert adapter encode bytes / bus events / `SilentDiagnostics` / transport writes | Treat a screenshot or manual GUI smoke as the pass criterion |
| Live harnesses under `tests/AgenticCLIs/**` (`Live*Harness`, Custom/Cursor ACP, migration ACP) | Launch Xcode GUI and drive the workbench by hand (or via computer-use) as the primary test |
| Cover A2UI decode/encode/resolver/engine in `A2UICoreTests`, `ACP*Tests`, `AgentEngineA2UICommandTests` | Add heuristics or one-off GUI probes that bypass `AgentCommand` |

GUI launch (`Codemixer.xcodeproj`) remains for **visual** checks only — layout, Theme tokens, a11y labels — after the API path already proves behaviour. If a behaviour cannot be exercised via `AgentCommand`/`AgentEvent`, that is a product gap: add the command/event (or adapter encode hook), then test it.

### Add or edit a script in `scripts/`

- Scripts in this repo are Swift (`.swift`) only.
- Do not add new shell scripts (`.sh`); migrate touched shell automation to Swift.
- Read [`scripts/README.md`](scripts/README.md) before creating or changing anything in `scripts/` — the catalog there documents every script (build gates, policy checks, live spikes, local developer setup).

---

## Build, test, run

Package and test commands run from the repository root (SPM targets are **macOS 14+ only**):

```bash
swift build                              # everything
swift build --product codemixerd         # daemon only
swift build --product codemixer          # GUI only
swift build --target AgentCore           # one module

scripts/swift-test.swift                 # preferred full suite (clears live gates + --no-parallel)
scripts/swift-test.swift --filter PTYHostTests
scripts/swift-test.swift --filter "WireCodec"
# Opt-in live harnesses only — keep CODEMIXER_LIVE_* / MIGRATION_LIVE* from the shell:
scripts/swift-test.swift --allow-live --filter LiveCustomACPIntegrationTests

swift run codemixerd                     # start the daemon (127.0.0.1:8421)
```

**Prefer `scripts/swift-test.swift` over raw `swift test`.** It always injects
`--no-parallel` and, by default, strips leftover `CODEMIXER_LIVE_*` /
`MIGRATION_LIVE*` environment gates. Those gates are sticky in agent/developer
shells after a live run; if left set, a plain `swift test --no-parallel` can
silently arm multi-minute live pipelines (especially
`CODEMIXER_LIVE_CUSTOM_ACP` + `CODEMIXER_LIVE_MIGRATION_PIPELINE`) and look like
a hang. Use `--allow-live` only when you intentionally want those harnesses.
See [`scripts/README.md`](scripts/README.md).

GUI app launch is the exception: **do not use `swift run codemixer` for UI
validation.** The real macOS app target is defined in
`src/CodemixerApp/Project.swift` and must be launched from
`src/CodemixerApp/Codemixer.xcodeproj`:

```bash
# from repository root
# Regenerate only when src/CodemixerApp/Project.swift changed or the project is missing.
# Codemixer.xcodeproj, Codemixer.xcworkspace, and Derived/ are gitignored (Tuist output).
scripts/generate-xcodeproj.swift --no-open

cd src/CodemixerApp
xcodebuild -project Codemixer.xcodeproj -scheme Codemixer -configuration Debug build
open "$(xcodebuild -project Codemixer.xcodeproj -scheme Codemixer -configuration Debug -showBuildSettings | awk -F'= ' '/TARGET_BUILD_DIR/ { dir=$2 } /WRAPPER_NAME/ { app=$2 } END { print dir "/" app }')"
```

If `tuist` is needed, it may be installed under mise (for example
`~/.local/share/mise/installs/tuist/latest/bin/tuist`) even when a non-login
shell cannot find it. Do not fall back to the raw SwiftPM executable for UI
validation.

When checking a running UI app, verify the live process path points at the
fresh Xcode build product, not an old DerivedData app and not the raw SwiftPM
`.build/.../codemixer` executable.

For manual live-account spike validation prerequisites (`claude`, `socat`, `jq`),
see the README section
[`Spike-script prerequisites`](README.md#spike-script-prerequisites).

`scripts/swift-test.swift` (or equivalent `swift test --no-parallel` with live
gates cleared) must be green before any commit. The `--no-parallel` flag is
mandatory: a handful of tests own kernel-level resources (PTYs, signal sources,
`NWListener`s) that race when scheduled across parallel workers. Serial
execution finishes the full suite in under a minute when live gates are off.
SwiftFormat (`.swiftformat`) and SwiftLint (`.swiftlint.yml`) configs are
checked locally via `scripts/pre-commit.swift`; treat `docs/style/code-style.md`
as the canonical style reference.

---

## Cleanup invariants (maintainers)

When extending the codebase after the 2026 maintainability pass:

| Constant owner | Owns |
| --- | --- |
| `RemoteDefaults` | WebSocket port (8421), sidecar port (8422), `/v1/ws` path, loopback/LAN hosts, Bonjour service type/name/TXT version |
| `RemoteAuthTiming` | Pairing PIN TTL, lockout duration, attempt interval, max attempts |
| `DaemonDefaults` | Headless idle-check interval and exit threshold |
| `AppIdentity` | Bundle id, log subsystem, LaunchAgent label/plist/log paths/throttle, Keychain service names, queue labels, app-support/caches relative paths |
| `ActivityTiming` | Activity escalation thresholds, status phrases (`idle`/`thinking`/optimistic send), TUI poll interval |
| `ModelCatalogTiming` | Automatic model-catalog max age (24h) before re-probe; probe timeout; retained-empty-catalog and unavailable-project messages |
| `StreamBufferDefaults` | Named `AsyncStream` buffer sizes per layer (event history 500, etc.) |
| `A2UILimits` | A2UI safety ceilings — payload bytes, batch items, JSON depth/nodes, surfaces/components per session, list expansion, expression depth/call-count, pointer/regex/resolved-string length |
| `A2UISchemaProfile` | A2UI version/MIME/catalog-id/`_meta`-key constants and the pinned upstream schema manifest (URL + commit + SHA-256 per file) |
| `SystemPaths` | `/usr/bin/env`, `/usr/bin/git`, `/usr/bin/openssl`, Terminal.app |
| `AppSupportPaths` | `prefs.json`, `sessions.json`, `workspaces.json`, attachments dir, `remote-server.p12` |
| `ProjectPaths` | per-project `.codemixer/project.json`, per-workspace `.codemixer/workspace.json`, per-adapter `workspace-<AgentID>.json` |
| `ClaudeProjectPaths` | Claude transcript/project slug conventions |
| `AgentUI/External/DesktopActions` | Pasteboard, Finder reveal, save panels |
| `Remote/AgentRemoteControl/External/CertificateIdentityImporter` | PKCS#12 import + cert fingerprint extraction |
| `Remote/AgentRemoteControl/CertificateManager` | Self-signed TLS identity generation + cert pinning |
| `Remote/AgentRemoteControl/RemoteRuntimeCoordinator` | Shared daemon/GUI remote bootstrap |

Validation before merge:

```bash
swift build && scripts/swift-test.swift
swift scripts/check-package-layout.swift
swift scripts/check-no-swiftui-imports.swift
swift scripts/check-no-personal-paths.swift
swift scripts/check-direct-framework-calls.swift
swift scripts/check-a11y.swift
swift scripts/regen-coverage-manifest.swift --check
scripts/swift-test.swift 2>&1 | scripts/check-test-runtime.swift   # per-suite runtime budgets
```

`scripts/pre-commit.swift` is a **narrow** local hook (build + `scripts/swift-test.swift` + SwiftFormat/SwiftLint). It does **not** replace the full merge gate below. Install with
`ln -sf ../../scripts/pre-commit.swift .git/hooks/pre-commit`. See
[`scripts/README.md`](scripts/README.md) for the full catalog.

Docs must match `RemoteDefaults` for ports and TLS policy. Do not hardcode paths outside the owners above. Machine-specific home-directory paths in sources or docs are forbidden — live probes use env vars; run `swift scripts/check-no-personal-paths.swift` before merge (also listed in the merge gate below).

---

## Tripwires

These will break the build, the tests, or a future-you's review.

### Build-breaking

- **Importing SwiftUI from `AgentCore`, `ClaudeCode`, `AgentRemoteControl`, or `AgentProtocol`.** Those targets must stay headless-capable. Enforced by `scripts/check-no-swiftui-imports.swift`.
- **Importing `ClaudeCode` (or any specific adapter) from `AgentCore` or `AgentUI`.** Adapters are leaves; the core stays agent-agnostic.
- **Direct calls to any wrapped framework outside `*/External/*.swift`.** `Foundation.Process`, `SecItem*`, `FSEventStream*`, `NWListener`, `NWConnection`, `AVSpeechSynthesizer`, `AVAudioEngine`, `SFSpeechRecognizer`, `UNUserNotificationCenter`, `NetService`, `URLSession`. Use the wrapper from the appropriate `External/` directory (`ProcessRunner`, `KeychainStore`, `FSEventsStream`, `NetworkTransport`, `SpeechSynthesis`, `SpeechCapture`, `SystemNotifications`, `BonjourBroadcaster`); if a wrapper doesn't exist, add one in the same PR. See `docs/style/code-style.md §18.5` and `docs/reference/wrappers.md`. Enforced by `scripts/check-direct-framework-calls.swift` locally (see merge gate in this file). Not wired to GitHub Actions today.
- **Reaching for `forK + execve`, ad hoc `Process` for the agent, or any blocking IO on the main thread.** Use `InteractiveTerminalTransport`/`PTYHost` for terminal agents and `StdioJSONRPCTransport` for stdio agents.
- **Adding a `Sendable` warning suppression.** If a type isn't `Sendable`, fix it; if you need `@unchecked Sendable`, write a one-line comment explaining why it's safe (see `TerminalEngine.DelegateBridge` and `HookServer.DataBox` for examples).
- **Using `posix_spawn` flags casually.** `POSIX_SPAWN_CLOEXEC_DEFAULT` is *not* used here — it caused EPERM under unentitled processes. If you add a flag, test on a clean macOS user account.

### Style-breaking (will get bounced in review)

- Files where the public surface isn't visible in the first 30 lines (§1.1).
- Booleans modelling state that should be an enum (§1.2).
- Magic strings modelling a closed set of values that should be an enum. Prefer typed values (`enum` / typed constants) over string literals for discriminants, catalog kinds, modes, status codes, and similar — e.g. `A2UIComponentBody.text(…)` / `A2UITextVariant.caption`, not `"Text"` / `"caption"`. Wire payloads may still carry strings; decode them into the typed form at the boundary and switch on the type thereafter.
- Generic `JSONValue` (or `[String: JSONValue]` property bags) on a public domain API where a closed, typed model belongs. `JSONValue` is a *wire* type: decode it into typed values (`A2UIComponentBody`/`A2UIDynamicValue`/`A2UIResolvedValue`/…) at the boundary. If a payload is genuinely open-ended or unknown, wrap it in an opaque carrier (see `A2UIOpaqueJSON`/`A2UIOpaqueComponent`) whose `JSONValue` accessor is `package`, not `public` — never re-expose a raw `JSONValue` getter.
- Functions whose name + signature don't tell you what they do without a doc comment (§1.3).
- Magic numbers (durations, sizes, timeouts) that aren't named constants (§1.6).
- Comments that narrate what the code already says (`// increment counter`). Comments explain *why*, *trade-offs*, *constraints* — not *what*.
- Emojis anywhere in source or comments (unless explicitly requested by a human).
- Literal colors, fonts, or spacing values in SwiftUI views — always use `Theme.*` tokens.
- `@MainActor` on non-UI types.
- `Date()`, `UUID()`, `getenv(_:)`, `ProcessInfo.processInfo.environment`, `FileManager.default.url(...)` called directly inside engine/adapter code. Route through the seams.
- `UserDefaults` for app config. Forbidden (§20 of `code-style.md`). System-owned state like window frames is fine.
- Scripts in `scripts/` must be Swift (`.swift`) files. Do not add new shell scripts (`.sh`); migrate existing shell automation to Swift when touched.

### Test-breaking

- Tests that depend on the real clock, real random, real filesystem, or real network unless explicitly justified (PTY spawn against `/bin/echo` is the exception).
- Tests that share state across suites.
- Tests with sleeps longer than a few milliseconds — use `FakeClock.advance(by:)`.
- **Machine-specific paths in tests or docs** — a contributor's macOS home-directory path, leaked workspace fixtures, or hardcoded live-probe fallbacks. Use `CODEMIXER_LIVE_*` env vars or neutral placeholders; enforced by `scripts/check-no-personal-paths.swift`.
- **Leftover live gates in the shell** — `CODEMIXER_LIVE_*=1` / `MIGRATION_LIVE=1` left exported after a live run will arm multi-minute harnesses during a plain suite and look like a hang. Always use `scripts/swift-test.swift` (clears gates by default); pass `--allow-live` only for intentional live harnesses.
- **GUI-path-as-test** — validating product behaviour by clicking Codemixer.app (or computer-use against SwiftUI) instead of `AgentCommand` / engine / ACP / live harness API paths. See [Validate via the API path (not the GUI)](#validate-via-the-api-path-not-the-gui).

---

## Reference exemplar: `PTYHost`

When in doubt, read [`PTYHost.swift`](src/Core/AgentCore/PTY/PTYHost.swift) side-by-side with your work-in-progress. It encodes the project's aesthetic in one file:

- File-level doc comment explains *what this owns* in one paragraph.
- Public surface (`ChildSpec`, `ExitStatus`, the actor's public methods) is the first thing the reader sees.
- Private state, then private helpers, at the bottom.
- Resources are owned symmetrically: every `open` has its `close()`; the read source and the master fd are torn down in lockstep.
- The C shim is called through Swift wrappers that lift `errno` into typed errors.
- Comments explain *trade-offs* (why we don't use `POSIX_SPAWN_CLOEXEC_DEFAULT`, why the master gets `FD_CLOEXEC`, why we drop DSR replies) — not what each line does.
- The actor is the only owner of the mutable state; the bytes go out through an `AsyncStream` so consumers are not coupled to actor isolation.

If your file feels harder to skim than `PTYHost`, refactor before review.

---

## Quick reference: idioms

```swift
// Inject seams. Never reach for system clock / random / env / fs directly.
let now = clock.now()
let id  = random.uuid()
let env = environment.processEnvironment()
let data = try fileSystem.readData(at: url)

// Type-encode state. Don't use booleans.
enum Connection { case idle, connecting(attempt: Int), connected(stream: AsyncStream<Data>), failed(Error) }

// Errors are typed and carry context.
throw PTYError.spawnFailed(errno: rc, executable: exePath)

// Actors hold state. Bus/engine are actors. The bus reference is `nonisolated let`
// so subscribers don't have to cross the actor to subscribe — `MulticastEventBus`
// is itself an actor.
public actor AgentEngine {
    public nonisolated let bus: MulticastEventBus
    // …
}

// AsyncStream is the canonical event channel between modules.
public nonisolated let outboundBytes: AsyncStream<Data>

// Logger is the canonical observability sink.
private let log = Logger(subsystem: "com.codecave.Codemixer", category: "PTYHost")
log.notice("PTY spawned pid=\(pid, privacy: .public)")

// Comments explain trade-offs, not what.
// We deliberately drop DSR replies — the PTY peer is our agent, not a real
// terminal expecting answers.
```

---

## When you're about to commit

Walk the §26 checklist from `code-style.md`. The short version:

- [ ] `swift build` clean (zero warnings on changed files).
- [ ] `scripts/swift-test.swift` green.
- [ ] New behaviour has a test.
- [ ] Public surface has doc comments; non-obvious decisions have rationale comments.
- [ ] No new literal colors / fonts / spacing in SwiftUI views.
- [ ] No new direct calls to `Date()`, `UUID()`, `getenv`, `FileManager.default` from engine/adapter code.
- [ ] No macOS home-directory paths in sources or docs (`swift scripts/check-no-personal-paths.swift`).
- [ ] No new `@MainActor` outside `AgentUI`.
- [ ] No emojis in source.
- [ ] Commit message is imperative, ≤ 72 chars subject line, body explains *why*.
- [ ] If you added an `AgentCommand` or `AgentEvent` case, you wired it everywhere (§7.5 in `architecture.md`).

If any of those isn't true, you aren't ready to merge yet. That's the bar.

---

*Last revised after adding `scripts/swift-test.swift` (clears sticky live gates + `--no-parallel`) and documenting API-path-only validation. Update this file in the same PR as any change to module layout, top-level types, or merge gates.*
