# AGENTS.md

Companion file for AI coding agents (and fast-onboarding humans). Read this once, end-to-end, before editing anything. It is intentionally short — links carry the weight.

If you only have time for three sections: **[Read in this order](#read-in-this-order)**, **[Where things live](#where-things-live)**, **[Tripwires](#tripwires)**.

---

## What this project is

Codemixer is a native macOS workspace that drives an interactive CLI coding agent (Claude Code in v1, more later) under a **hidden** pseudo-terminal. The agent runs in a real pty (required by the interactive billing tier); the UI is pure SwiftUI driven by a typed `AgentEvent` stream. The same engine runs **headless** as `codemixerd` and exposes a typed WebSocket protocol so the GUI, a future iOS client, and CLI automation are all peer interaction surfaces.

The pillars:

1. The pty is invisible — no terminal pane, ever.
2. One typed input alphabet (`AgentCommand`), one typed output alphabet (`AgentEvent`). Every UI affordance maps to one `AgentCommand` case; every adapter byte maps to one `AgentEvent` case.
3. `AgentCore` and `AgentUI` are agent-agnostic. Per-vendor knowledge lives in adapter modules behind `AgentAdapter`.
4. Strict Swift 6 concurrency. Engines are `actor`s. `@MainActor` is the UI seam only. `@unchecked Sendable` is rare and always justified inline.
5. All side-effects route through four DI seams (`Clock`, `RandomSource`, `Environment`, `FileSystem`). Tests inject fakes; production code never reads `Date()` or `getenv` directly.

---

## Read in this order

| # | File | Why |
| --- | --- | --- |
| 1 | [`README.md`](README.md) | Product surface + module map + build/run. |
| 2 | This file | High-signal pointers for editing. |
| 3 | [`scripts/README.md`](scripts/README.md) | Script catalog + usage. Read before creating or editing anything in `scripts/`. |
| 4 | [`docs/architecture.md`](docs/architecture.md) | The canonical *how-and-where*. **Required reading before touching `AgentEngine`, `MulticastEventBus`, `AgentAdapter`, the wire protocol, or any module boundary.** |
| 4b | [`src/AgenticCLIs/README.md`](src/AgenticCLIs/README.md) | **Required before adding or restructuring an agent CLI adapter** (`Adapter/` + `Common/` + `digital-twin/`). |
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
├── scripts/                                 local automation + validation helpers
├── docs/                                    architecture + style + reference patterns
├── Package.swift, src/, tests/               the SPM package (repo root)
```

### Inside `src/`

| You want to change… | Open… |
| --- | --- |
| The pty pipeline (spawn, read, write, close, test seam) | `Core/AgentCore/PTY/{AgentPTY,PTYHost}.swift` |
| Child-process reaping | `Core/AgentCore/PTY/ChildReaper.swift` |
| Wrap a new Apple/system framework call (`Process`, `SecItem*`, `FSEventStream*`, etc.) | `Core/AgentCore/External/*.swift`, `AgentUI/External/*.swift`, `Remote/AgentRemoteControl/External/*.swift` — see `docs/reference/wrappers.md` |
| The C shim around `openpty` / `posix_spawn` | `Core/CPosixBridge/CPosixBridge.{h,c}` |
| The interactive-shell environment resolver | `Core/AgentCore/PTY/ShellEnvironmentResolver.swift` |
| Headless terminal emulation (SwiftTerm) | `Core/AgentCore/Terminal/TerminalEngine.swift` |
| The typed event alphabet | `Core/AgentCore/Events/AgentEvent.swift` |
| The adapter protocol or supporting types | `Core/AgentCore/Events/AgentAdapter.swift`, `SupportingTypes.swift`, `AgentID.swift` |
| The error model | `Core/AgentCore/Events/AgentError.swift` |
| Wire codec (domain ↔ wire) | `Core/AgentCore/Events/WireCodec.swift` |
| The event bus / ring buffer | `Core/AgentCore/Bus/MulticastEventBus.swift` |
| The orchestrator | `Core/AgentCore/Engine/AgentEngine.swift`, `AgentEngine+Commands.swift` |
| Engine state reduction | `Core/AgentCore/Engine/AgentState.swift` |
| Conversation/diff snapshots for late clients | `Core/AgentCore/Engine/SnapshotService.swift` |
| Git file/hunk revert | `Core/AgentCore/Engine/GitReverter.swift` |
| Hook UDS server | `Core/AgentCore/Hooks/HookServer.swift` |
| FSEvents watcher | `Core/AgentCore/FS/FSEventsWatcher.swift` |
| Git diff engine | `Core/AgentCore/Diff/GitDiffEngine.swift`, `DiffModels.swift` |
| Attachment resolution + persistence | `Core/AgentCore/Attachments/AttachmentResolver.swift` |
| Network transport abstraction (live / in-memory / logging) | `Core/AgentCore/Network/{NetworkTransport,LiveNetworkTransport,InMemoryNetworkTransport,LoggingNetworkTransport}.swift` |
| Status phrase priority | `Core/AgentCore/Status/StatusPhraseResolver.swift` |
| Activity heartbeat | `Core/AgentCore/Activity/HeartbeatActivityMonitor.swift` |
| Prefs / sessions / appearance persistence | `Core/AgentCore/Persistence/{PrefsStore,SessionStore,AppearancePrefs}.swift` |
| Agent-agnostic Workspace→Projects model + persistence | `Core/AgentCore/Persistence/WorkspaceProjectsStore.swift` |
| Core framework wrappers (Process, Keychain, FSEvents) | `Core/AgentCore/External/{ProcessRunner,KeychainStore,FSEventsStream}.swift` |
| Product constants (ports, identity, timing, buffers, paths) | `Core/AgentCore/{RemoteDefaults,AppIdentity,ActivityTiming,StreamBufferDefaults}.swift`, `Core/AgentCore/Paths/{AppSupportPaths,SystemPaths}.swift` |
| DI seams | `Core/AgentCore/Seams/{Clock,RandomSource,Environment,FileSystem,Seams}.swift` |
| Claude binary lookup | `AgenticCLIs/ClaudeCode/Adapter/ClaudeBinaryLocator.swift` |
| Shared Claude path/input/catalog helpers | `AgenticCLIs/ClaudeCode/Common/*.swift` |
| Claude hook installer | `AgenticCLIs/ClaudeCode/Adapter/ClaudeHookSettings.swift` |
| Claude hook decoder | `AgenticCLIs/ClaudeCode/Adapter/ClaudeHookDecoder.swift` |
| Claude transcript tailer | `AgenticCLIs/ClaudeCode/Adapter/ClaudeTranscriptTailer.swift` |
| Claude resumable-session lister (title, count, git branch) | `AgenticCLIs/ClaudeCode/Common/ClaudeSessionLister.swift` |
| Claude slash commands | `AgenticCLIs/ClaudeCode/Adapter/ClaudeSlashCommands.swift` |
| Claude TUI scrape fallback | `AgenticCLIs/ClaudeCode/Adapter/ClaudeTUIFallback.swift` |
| Claude adapter top-level | `AgenticCLIs/ClaudeCode/Adapter/ClaudeAdapter.swift` |
| Claude digital twin | `AgenticCLIs/ClaudeCode/digital-twin/Twin/` |
| Agentic CLI layout convention | `AgenticCLIs/README.md` |
| The wire DTOs (Foundation-only) | `Core/AgentProtocol/{AgentCommand,AgentEventWire,WireFrames,Decisions,Prefs,AttachmentRef,WireVersion}.swift` |
| WebSocket server | `Remote/AgentRemoteControl/RemoteControlServer.swift`, `ClientConnection.swift` |
| Pairing PIN + bearer tokens | `Remote/AgentRemoteControl/PairingService.swift` |
| Paired-device persistence | `Remote/AgentRemoteControl/PairedDeviceStore.swift` |
| TLS identity + cert pinning | `Remote/AgentRemoteControl/CertificateManager.swift`, `External/CertificateIdentityImporter.swift` |
| HTTP sidecar (`/v1/health`, `/v1/attachments`) | `Remote/AgentRemoteControl/HTTPSidecarServer.swift` |
| Remote peer that drives the engine | `Remote/AgentRemoteControl/RemoteEngineClient.swift` |
| Shared daemon/GUI remote bootstrap | `Remote/AgentRemoteControl/RemoteRuntimeCoordinator.swift` |
| Bonjour advertisement | `Remote/AgentRemoteControl/BonjourAdvertiser.swift`, `External/BonjourBroadcaster.swift` |
| Theme tokens (color, type, spacing, motion) | `AgentUI/Theme/Theme.swift` |
| Progressive disclosure modifier | `AgentUI/Theme/IntentReveal.swift` |
| The observable view model | `AgentUI/ViewModel/EngineViewModel.swift` |
| Activity primitives (`ShimmerDots`, `InlineStatusTicker`, `StatusPill`) | `AgentUI/Activity/ActivityViews.swift` |
| Conversation views (bubbles, prose, thinking blocks) | `AgentUI/Conversation/MessageViews.swift` |
| Markdown block parsing + prose/code rendering | `AgentUI/Conversation/{MarkdownBlock,MarkdownProseView,CodeBlockView,CodeSyntaxHighlighter}.swift` |
| Conversation motion (arriving rows, turn spine, streaming caret, empty-state hero) | `AgentUI/Conversation/ConversationMotion.swift` |
| Tool-call card (rendered inline in turn order) | `AgentUI/Conversation/ToolCallCardView.swift` |
| Permission prompt | `AgentUI/Conversation/PermissionPromptView.swift` |
| Conversation scroller | `AgentUI/Conversation/ConversationView.swift` |
| Session navigator (projects → sessions, icon-rail focus mode) | `AgentUI/Sidebar/SessionSidebarView.swift` |
| Cmd+K command palette | `AgentUI/Palette/CommandPaletteView.swift` |
| Composer (prompt input, modes, mic, send/cancel) | `AgentUI/Composer/{PromptComposerView,PromptComposerSupportViews,ComposerModelCatalog}.swift` |
| Diff panel | `AgentUI/Diff/DiffPanelView.swift` |
| Settings pane | `AgentUI/Settings/SettingsView.swift` |
| Project picker | `AgentUI/Pickers/ProjectPickerView.swift` |
| Conversation search | `AgentUI/Search/ConversationSearchBar.swift` |
| Session export | `AgentUI/Export/SessionExporter.swift` |
| Voice input + TTS | `AgentUI/Voice/{VoiceInputService,TTSService}.swift` |
| Auth gate + install-Claude flow | `AgentUI/Auth/{AuthGateView,InstallClaudeView}.swift` |
| Notifications bridge | `AgentUI/Notifications/UserNotificationBridge.swift` |
| Cost badge + shared primitives | `AgentUI/Components/{CostBadgeView,Primitives}.swift` |
| Debug terminal / event-log inspectors | `AgentUI/Debug/{DebugTerminalSheet,EventLogView}.swift` |
| UI framework wrappers (desktop, speech, QR, notifications) | `AgentUI/External/{DesktopActions,SpeechCapture,SpeechSynthesis,QRCodeRenderer,SystemNotifications}.swift` |
| Command/event interaction coverage map | `AgentUI/Interaction/InteractionCoverage.swift` |
| Root scene (split view) | `AgentUI/Workspace/WorkspaceScene.swift` |
| GUI app entry point | `CodemixerApp/CodemixerApp.swift`, `RootView.swift` |
| LaunchAgent installer | `CodemixerApp/External/LaunchAgentInstaller.swift` |
| Daemon entry point | `Remote/CodemixerDaemon/main.swift` |

### Inside `tests/`

```
tests/
├── TestSupport/
│   ├── AgentTestSupport/           # shared fakes (Clock, FS, MockAdapter)
│   └── AgentTestSupportTests/
├── Core/                           # AgentProtocolTests, AgentCoreTests
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
| Prefs + decisions Codable | `Core/AgentProtocolTests/PrefsAndDecisionsCodableTests.swift` |
| PTY lifecycle | `Core/AgentCoreTests/PTYHostTests.swift` |
| Child reaping | `Core/AgentCoreTests/ChildReaperTests.swift` |
| AgentCommand dispatch, PTY bytes, write-failure propagation | `Core/AgentCoreTests/AgentEngineCommandTests.swift` |
| Engine integration (end-to-end) | `Core/AgentCoreTests/EngineIntegrationTests.swift` |
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
| Git changed-files porcelain parsing | `Core/AgentCoreTests/ChangedFilesParsingTests.swift` |
| Status phrase priority | `Core/AgentCoreTests/StatusPhraseResolverTests.swift` |
| Activity heartbeat escalation | `Core/AgentCoreTests/HeartbeatActivityMonitorTests.swift` |
| Prefs / sessions persistence | `Core/AgentCoreTests/{PrefsStoreTests,SessionStoreTests,AppearancePrefsTests}.swift` |
| Workspace→Projects model + persistence | `Core/AgentCoreTests/WorkspaceProjectsStoreTests.swift` |
| Unix-socket transport | `Core/AgentCoreTests/UnixSocketTransportTests.swift` |
| Public-API coverage manifest | `Core/AgentCoreTests/{CoverageManifest,PublicAPITests}.swift` |
| Hook installer idempotence | `AgenticCLIs/ClaudeCode/ClaudeAdapterTests/HookInstallerTests.swift` |
| Hook decoder + transcript tailer | `AgenticCLIs/ClaudeCode/ClaudeAdapterTests/{ClaudeHookDecoderTests,TranscriptTailerTests,TranscriptTruncationTests}.swift` |
| Adapter event stream + binary locator | `AgenticCLIs/ClaudeCode/ClaudeAdapterTests/{ClaudeAdapterEventStreamTests,ClaudeBinaryLocatorTests}.swift` |
| Slash commands + session lister | `AgenticCLIs/ClaudeCode/ClaudeAdapterTests/{ClaudeSlashCommandsTests,ClaudeSessionListerTests}.swift` |
| TUI fallback gating | `AgenticCLIs/ClaudeCode/ClaudeAdapterTests/{TUIFallbackTests,TUIFallbackGateTests}.swift` |
| Twin decoder parity (adapter + twin) | `AgenticCLIs/ClaudeCode/{ClaudeAdapterTests,ClaudeCodeTwinTests}/TwinDecoderParityTests.swift` |
| FakeClock virtual sleep | `TestSupport/AgentTestSupportTests/FakeClockTests.swift` |
| Pairing PIN + lockout | `Remote/AgentRemoteControlTests/PairingServiceTests.swift` |
| Paired-device store | `Remote/AgentRemoteControlTests/PairedDeviceStoreTests.swift` |
| Remote-control E2E, replay, command errors, PTY write failures | `Remote/AgentRemoteControlTests/RemoteControlE2ETests.swift` |
| Live TLS transport handshake | `Remote/AgentRemoteControlTests/LiveTLSTransportTests.swift` |
| Certificate manager | `Remote/AgentRemoteControlTests/CertificateManagerTests.swift` |
| HTTP sidecar parsing + server | `Remote/AgentRemoteControlTests/{HTTPSidecarParsingTests,HTTPSidecarServerTests}.swift` |
| Remote engine client + Bonjour | `Remote/AgentRemoteControlTests/{RemoteEngineClientTests,BonjourAdvertiserTests,BonjourBroadcasterTests}.swift` |
| Wire-codec parity | `Remote/RemoteParityTests/WireCodecParityTests.swift` |
| Command dispatch parity | `Remote/RemoteParityTests/CommandDispatchParityTests.swift` |
| View-model reduction | `AgentUITests/EngineViewModelTests.swift` |
| Optimistic send + navigator actions | `AgentUITests/EngineViewModelNavigatorTests.swift` |
| Interaction coverage (every command/event surfaced) | `AgentUITests/InteractionCoverageTests.swift` |
| Session export | `AgentUITests/SessionExporterTests.swift` |
| Voice + TTS + speech wrappers | `AgentUITests/{VoiceInputServiceTests,TTSStripMarkdownTests,SpeechCaptureTests,SpeechSynthesisTests}.swift` |
| QR + system notifications | `AgentUITests/{QRCodeRendererTests,SystemNotificationsTests}.swift` |
| Claude digital twin + engine E2E | `AgenticCLIs/ClaudeCode/ClaudeCodeTwinTests/{EngineDigitalTwinTests,TwinDecoderParityTests}.swift` |

---

## Common tasks

### Add a new `AgentCommand` case

1. Add the case to `Core/AgentProtocol/AgentCommand.swift`.
2. Handle it in `Core/AgentCore/Engine/AgentEngine.swift` (`send(_:)`).
3. Wire a UI affordance in `AgentUI/` (typically in the composer, a context menu, or a settings pane).
4. If the command writes to the PTY, add/extend `AgentEngineCommandTests` with
   exact `AgentPTY.write` bytes and write-failure propagation. For multi-step
   lifecycle commands, cover each write point separately.
5. Update `Remote/RemoteParityTests` if a new wire round-trip needs coverage, and add
   `Remote/AgentRemoteControlTests/RemoteControlE2ETests` coverage when remote clients need a specific result
   or event ordering guarantee.
6. Confirm `swift test --no-parallel` is green.

### Add a new `AgentEvent` case

1. Add the case to `Core/AgentCore/Events/AgentEvent.swift`.
2. Add the mirror to `Core/AgentProtocol/AgentEventWire.swift`.
3. Add both `encode`/`decode` arms to `Core/AgentCore/Events/WireCodec.swift`.
4. Add a case to `Remote/RemoteParityTests/WireCodecParityTests.swift`.
5. Reduce it in `AgentUI/ViewModel/EngineViewModel.swift` (or document why it's intentionally not reduced).

### Add a new adapter (e.g. CodexCLI)

1. Scaffold `src/AgenticCLIs/<AgentName>/` with `Adapter/`, `Common/`, `digital-twin/`, and contract `README.md` — see [`src/AgenticCLIs/README.md`](src/AgenticCLIs/README.md).
2. New SPM library target + product under that path; top-level type conforming to `AgentAdapter`.
3. Declare the relevant `AgentCapabilities`.
4. Register at startup: `await AdapterRegistry.shared.register(CodexAdapter())`.
5. Add a test target under `tests/AgenticCLIs/<AgentName>/` with at least a smoke test that the adapter constructs — see [`tests/AgenticCLIs/README.md`](tests/AgenticCLIs/README.md).
6. **Do not** add any import of the new adapter inside `AgentCore` or `AgentUI`.

Full recipe in `docs/reference/patterns/plugin-adapter-protocol.md`.

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

### Add or edit a script in `scripts/`

- Scripts in this repo are Swift (`.swift`) only.
- Do not add new shell scripts (`.sh`); migrate touched shell automation to Swift.
- Read [`scripts/README.md`](scripts/README.md) before changing script behavior.

---

## Build, test, run

Package and test commands run from the repository root:

```bash
swift build                              # everything
swift build --product codemixerd         # daemon only
swift build --product codemixer          # GUI only
swift build --target AgentCore           # one module

swift test --no-parallel                 # full suite (~2s, required flag)
swift test --filter PTYHostTests         # one suite
swift test --filter "WireCodec"          # any matching suite

swift run codemixerd                     # start the daemon (127.0.0.1:8421)
```

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

`swift test --no-parallel` must be green before any commit. The `--no-parallel` flag is mandatory: a handful of tests own kernel-level resources (PTYs, signal sources, `NWListener`s) that race when scheduled across parallel workers. Serial execution finishes the full suite in under two seconds. Lint and format will land in the toolchain shortly (`SwiftFormat` + `SwiftLint` are listed in `code-style.md` §25); for now treat the style guide as the linter.

---

## Cleanup invariants (maintainers)

When extending the codebase after the 2026 maintainability pass:

| Constant owner | Owns |
| --- | --- |
| `RemoteDefaults` | WebSocket port (8421), sidecar port (8422), `/v1/ws` path, loopback/LAN hosts |
| `AppIdentity` | Bundle id, log subsystem, LaunchAgent label/plist, Keychain service names, queue labels, app-support/caches relative paths |
| `ActivityTiming` | Activity escalation thresholds + status phrases + optimistic-send/undo windows |
| `StreamBufferDefaults` | Named `AsyncStream` buffer sizes per layer (event history 500, etc.) |
| `SystemPaths` | `/usr/bin/env`, `/usr/bin/git`, `/usr/bin/openssl`, Terminal.app |
| `AppSupportPaths` | `prefs.json`, `sessions.json`, `workspaces.json`, attachments dir |
| `ClaudeProjectPaths` | Claude transcript/project slug conventions |
| `AgentUI/External/DesktopActions` | Pasteboard, Finder reveal, save panels |
| `Remote/AgentRemoteControl/External/CertificateIdentityImporter` | PKCS#12 import + cert fingerprint extraction |
| `Remote/AgentRemoteControl/CertificateManager` | Self-signed TLS identity generation + cert pinning |
| `Remote/AgentRemoteControl/RemoteRuntimeCoordinator` | Shared daemon/GUI remote bootstrap |

Validation before merge:

```bash
swift build && swift test --no-parallel
swift scripts/check-package-layout.swift
swift scripts/check-no-swiftui-imports.swift
swift scripts/check-direct-framework-calls.swift
swift scripts/check-a11y.swift
swift scripts/regen-coverage-manifest.swift --check
swift test --no-parallel 2>&1 | scripts/check-test-runtime.swift   # per-suite runtime budgets
```

`scripts/pre-commit.swift` chains the build + test + lint gate; install it with
`ln -sf ../../scripts/pre-commit.swift .git/hooks/pre-commit`. See
[`scripts/README.md`](scripts/README.md) for the full catalog.

Docs must match `RemoteDefaults` for ports and TLS policy. Do not hardcode paths outside the owners above.

---

## Tripwires

These will break the build, the tests, or a future-you's review.

### Build-breaking

- **Importing SwiftUI from `AgentCore`, `ClaudeCode`, `AgentRemoteControl`, or `AgentProtocol`.** Those targets must stay headless-capable. The headless CI matrix would catch it once wired; for now, just don't.
- **Importing `ClaudeCode` (or any specific adapter) from `AgentCore` or `AgentUI`.** Adapters are leaves; the core stays agent-agnostic.
- **Direct calls to any wrapped framework outside `*/External/*.swift`.** `Foundation.Process`, `SecItem*`, `FSEventStream*`, `NWListener`, `NWConnection`, `AVSpeechSynthesizer`, `AVAudioEngine`, `SFSpeechRecognizer`, `UNUserNotificationCenter`, `NetService`, `URLSession`. Use the wrapper from the appropriate `External/` directory (`ProcessRunner`, `KeychainStore`, `FSEventsStream`, `NetworkTransport`, `SpeechSynthesis`, `SpeechCapture`, `SystemNotifications`, `BonjourBroadcaster`); if a wrapper doesn't exist, add one in the same PR. See `docs/style/code-style.md §18.5` and `docs/reference/wrappers.md`. Enforced by `scripts/check-direct-framework-calls.swift` in CI.
- **Reaching for `forK + execve`, `Process` for the agent, or any blocking IO on the main thread.** Use `PTYHost` and the spawn shim.
- **Adding a `Sendable` warning suppression.** If a type isn't `Sendable`, fix it; if you need `@unchecked Sendable`, write a one-line comment explaining why it's safe (see `TerminalEngine.DelegateBridge` and `HookServer.DataBox` for examples).
- **Using `posix_spawn` flags casually.** `POSIX_SPAWN_CLOEXEC_DEFAULT` is *not* used here — it caused EPERM under unentitled processes. If you add a flag, test on a clean macOS user account.

### Style-breaking (will get bounced in review)

- Files where the public surface isn't visible in the first 30 lines (§1.1).
- Booleans modelling state that should be an enum (§1.2).
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
- [ ] `swift test --no-parallel` green.
- [ ] New behaviour has a test.
- [ ] Public surface has doc comments; non-obvious decisions have rationale comments.
- [ ] No new literal colors / fonts / spacing in SwiftUI views.
- [ ] No new direct calls to `Date()`, `UUID()`, `getenv`, `FileManager.default` from engine/adapter code.
- [ ] No new `@MainActor` outside `AgentUI`.
- [ ] No emojis in source.
- [ ] Commit message is imperative, ≤ 72 chars subject line, body explains *why*.
- [ ] If you added an `AgentCommand` or `AgentEvent` case, you wired it everywhere (§7.5 in `architecture.md`).

If any of those isn't true, you aren't ready to merge yet. That's the bar.

---

*Last revised after the v0.1+ surface landed (attachments, voice/TTS, settings, search, export, auth gate, TLS + sidecar, paired devices, remote client, LaunchAgent, git revert). Update this file in the same PR as any change to module layout, top-level types, or merge gates.*
