# Agentic CLI tests

Test suites for adapters under `src/AgenticCLIs/` mirror that layout here:

```
tests/AgenticCLIs/
├── README.md                 # this file
└── <AgentName>/              # one folder per agent (e.g. ClaudeCode)
    ├── <Agent>AdapterTests/  # SPM test target — adapter contract, parsers, production integration
    └── <Agent>TwinTests/     # optional second target — digital-twin + twin engine E2E
```

Claude Code and Codex:

| SPM test target | Path | Concern |
| --- | --- | --- |
| `ClaudeAdapterTests` | `ClaudeCode/ClaudeAdapterTests/` | Production adapter contract, parsers, `fake-claude` + opt-in live harness |
| `ClaudeCodeTwinTests` | `ClaudeCode/ClaudeCodeTwinTests/` | `ClaudeCodeTwin` projection and twin-driven engine E2E |
| `CodexAdapterTests` | `Codex/CodexAdapterTests/` | App Server framing/RPC, scripted transports, opt-in live harness |
| `CodexTwinTests` | `Codex/CodexTwinTests/` | `CodexTwin` projection only |

Target names stay stable; only directory paths move when colocating with `src/AgenticCLIs/<AgentName>/`.

Source layout, twin rules, and the add-agent checklist: [`src/AgenticCLIs/README.md`](../../src/AgenticCLIs/README.md).

---

## Live Claude harness (`ClaudeAdapterTests`)

`ClaudeAdapterTests` includes an **opt-in** live-account harness for the production
interactive PTY path (`AgentEngine` + `ClaudeAdapter` + hooks + transcript tailer).
It does **not** use `claude -p` / `--print` — that path bills against API credits,
not the interactive subscription.

| File | Role |
| --- | --- |
| `ClaudeCode/ClaudeAdapterTests/LiveClaudeHarness.swift` | Reusable driver — spawn, trust auto-approve, prompt, assert |
| `ClaudeCode/ClaudeAdapterTests/LiveClaudeIntegrationTests.swift` | Suite `AgentEngine + ClaudeAdapter live harness` |

### When to use which Claude adapter/twin path

| Path | Binary | Login required | Suite |
| --- | --- | --- | --- |
| `ClaudeCodeTwin` projection | In-process twin | No | `EngineDigitalTwinTests` (`ClaudeCodeTwinTests`) |
| `fake-claude` spawned | `fake-claude` | No | `FakeClaudeIntegrationTests` (`ClaudeAdapterTests`) |
| **Live harness** | Real `claude` on PATH | Yes | `LiveClaudeIntegrationTests` (`ClaudeAdapterTests`) |

### Running

Default `swift test` **skips** the live turn silently (no failure). One fast argv
guard always runs.

```bash
# Fast argv guard only (live turn skipped)
swift test --no-parallel --filter LiveClaude

# Full live validation — logged-in claude, trusted workspace
CODEMIXER_LIVE_CLAUDE=1 swift test --no-parallel --filter LiveClaudeIntegrationTests
```

### Environment variables

| Variable | Required | Purpose |
| --- | --- | --- |
| `CODEMIXER_LIVE_CLAUDE=1` | Yes (for live turn) | Opt in to network + real Claude account |
| `CODEMIXER_LIVE_CLAUDE_RESUME_DIAG=1` | No | Also dump SwiftTerm rows around `--resume` (`resumeHangDiagnostic`) |
| `CODEMIXER_LIVE_WORKSPACE` | No | Trusted workspace directory (defaults to process cwd) |
| `CLAUDE_BIN` | No | Override `claude` executable path |
| `CODEMIXER_FAKE_CLAUDE` | Must be unset | Live harness refuses to run when the fake twin is armed |

Prerequisites: `claude` installed and authenticated (`claude auth status`), and the
chosen workspace already trusted (or the harness will auto-approve the workspace-trust
TUI prompt once).

### What the harness does

1. Starts `AgentEngine` with `Seams.live` and the production `ClaudeAdapter`.
2. Installs hook UDS entries into `<workspace>/.claude/settings.local.json`.
3. Spawns `claude` under a real PTY (no `-p`, `--print`, or stream-json flags).
4. Waits for hook `SessionStart` (non-empty session id + model).
5. Auto-approves `WorkspaceTrust` permission prompts.
6. Pauses for the TUI prompt row, sends one `sendPrompt`, waits for final `assistantText`.
7. Asserts **exactly one** final `assistantText` (see [Assistant-text authority](#assistant-text-authority) below).
8. Parses the session JSONL and asserts billing markers: `entrypoint: cli`,
   `promptSource` ≠ `sdk` (contrast with `claude -p`, which records `sdk-cli` / `sdk`).

Runtime budget override: `scripts/test-runtime-overrides.json` →
`AgentEngine + ClaudeAdapter live harness` (180s when enabled).

Related spikes (manual, not SPM): `scripts/spike-billing.swift`,
`scripts/spike-events.swift` — see [`scripts/README.md`](../../scripts/README.md).

### Assistant-text authority

Claude can surface the same final reply from two channels:

| Source | When |
| --- | --- |
| Transcript JSONL (`ClaudeTranscriptTailer`) | Canonical — polled continuously and drained on Stop |
| Stop hook `last_assistant_message` (`ClaudeHookDecoder`) | Fallback when the transcript has not yet emitted |

`ClaudeAdapter` drains the transcript on Stop, then **drops** Stop/SubagentStop
`assistantText` events when the tailer has already emitted one for the session.
Idle activity from Stop still flows. Covered by
`ClaudeAdapterEventStreamTests` ("Stop last_assistant_message is dropped…") and
asserted live via `TurnResult.finalAssistantTextCount == 1`.

Duplicate **user** turns (engine echo + `UserPromptSubmit` hook) are expected;
`EngineViewModel` dedupes those with `ActivityTiming.userTurnEchoWindow`.

### Reusing `LiveClaudeHarness` in new tests

```swift
guard LiveClaudeHarness.isEnabled() else { return }

let harness = LiveClaudeHarness()
var config = LiveClaudeHarness.defaultConfiguration()
config.prompt = "Reply with exactly: pong"
config.expectedFinalSubstring = "pong"

let result = try await harness.runTurn(config)
// result.events, result.sessionID, result.transcriptURL,
// result.billingMarkers?.isSubscriptionCLIPath,
// result.finalAssistantText, result.finalAssistantTextCount
```

Static helpers for assertions without a full turn:

- `LiveClaudeHarness.launchArgvIsInteractive()` — argv never contains `-p` / `--print`.
- `LiveClaudeHarness.billingMarkers(in:prompt:)` — parse transcript JSONL billing fields.
- `LiveClaudeHarness.runResumeHangDiagnostic(_:)` — seed + `--resume` with per-second
  SwiftTerm row dumps (`CODEMIXER_LIVE_CLAUDE_RESUME_DIAG=1`). Use when a live
  resume stops accepting the first follow-up prompt.

---

## Live Codex harness (`CodexAdapterTests`)

`CodexAdapterTests` includes an **opt-in** live-account harness for the production
App Server stdio path (`AgentEngine` + `CodexAdapter` + `StdioJSONRPCTransport`).
It does **not** use terminal emulation or a PTY.

| File | Role |
| --- | --- |
| `Codex/CodexAdapterTests/LiveCodexHarness.swift` | Reusable driver — spawn, bootstrap, prompt, assert |
| `Codex/CodexAdapterTests/LiveCodexIntegrationTests.swift` | Suite `AgentEngine + CodexAdapter live harness` |

### When to use which Codex adapter/twin path

| Path | Binary | Login required | Suite |
| --- | --- | --- | --- |
| `CodexTwin` projection | In-process twin | No | `CodexTwinTests` |
| Scripted transport | Fixture bytes | No | `CodexAdapterTests` |
| **Live harness** | Real `codex` on PATH | Yes | `LiveCodexIntegrationTests` (`CodexAdapterTests`) |

### Running

Default `swift test` **skips** the live turn silently (no failure). One fast argv
guard always runs.

```bash
# Fast argv guard only (live turn skipped)
swift test --no-parallel --filter LiveCodex

# Full live validation — logged-in codex
CODEMIXER_LIVE_CODEX=1 swift test --no-parallel --filter LiveCodexIntegrationTests
```

### Environment variables

| Variable | Required | Purpose |
| --- | --- | --- |
| `CODEMIXER_LIVE_CODEX=1` | Yes (for live turn) | Opt in to network + real Codex account |
| `CODEMIXER_LIVE_WORKSPACE` | No | Workspace directory (defaults to process cwd) |
| `CODEX_BIN` | No | Override `codex` executable path |

Prerequisites: `codex` installed and authenticated (`codex login status`).

### What the harness does

1. Starts `AgentEngine` with `Seams.live` and the production `CodexAdapter`.
2. Spawns `codex app-server --stdio` and writes the bootstrap sequence
   (`initialize`, `initialized`, `thread/start`).
3. Waits for adapter `sessionStarted` with a non-empty Codex thread id.
4. Sends one `sendPrompt`, auto-approves permission prompts.
5. Waits for final `assistantText` and asserts **exactly one** final reply.

Runtime budget override: `scripts/test-runtime-overrides.json` →
`AgentEngine + CodexAdapter live harness` (180s when enabled).

### Reusing `LiveCodexHarness` in new tests

```swift
guard LiveCodexHarness.isEnabled() else { return }

let harness = LiveCodexHarness()
var config = LiveCodexHarness.defaultConfiguration()
config.prompt = "Reply with exactly: codemixer-codex-pong"
config.expectedFinalSubstring = "codemixer-codex-pong"

let result = try await harness.runTurn(config)
// result.events, result.threadID, result.finalAssistantText,
// result.finalAssistantTextCount
```

Static helpers for assertions without a full turn:

- `LiveCodexHarness.launchArgvIsAppServerStdio()` — argv is `codex app-server --stdio`.
- `LiveCodexHarness.transportIsStdioJSONRPC()` — descriptor matches the stdio JSON-RPC transport.

---

## Agent Client Protocol (ACP)

Tests live under `tests/AgenticCLIs/AgentClientProtocol/`.

| File | Role |
| --- | --- |
| `ACPAdapterTests/ACPAdapterTests.swift` | Adapter surface, factory, transport, permissions |
| `ACPAdapterTests/ACPProtocolTests.swift` | Framing, JSON-RPC codec, incoming decode |
| `ACPAdapterTests/ACPInputEncodingTests.swift` | Bootstrap, session open, prompts, cancel, auth |
| `ACPAdapterTests/ACPEventDecoderTests.swift` | Session lifecycle, streaming, tools, permissions |
| `ACPAdapterTests/ACPReverseRPCTests.swift` | Reverse filesystem + terminal RPC handlers |
| `ACPAdapterTests/ACPAdapterStreamTests.swift` | Adapter `makeEventStream` integration |
| `ACPAdapterTests/FakeACPIntegrationTests.swift` | Suite `AgentEngine + ACPAdapter + fake-acp` (spawned stdio path) |
| `ACPAdapterTests/LiveACPHarness.swift` | Reusable opt-in driver against a real ACP agent server |
| `ACPAdapterTests/LiveACPIntegrationTests.swift` | Suite `AgentEngine + ACPAdapter live harness` |
| `ACPTwinTests/ACPTwinTests.swift` | Deterministic twin (auth + happy path) |

| Kind | Needs real binary? | Network? | Suite |
| --- | --- | --- | --- |
| Unit / twin | No | No | `ACPAdapterTests`, `ACPTwinTests` |
| Spawned twin | `fake-acp` (see below) | No | `FakeACPIntegrationTests` |
| Live harness | Yes (`CODEMIXER_LIVE_ACP_BIN`) | Agent-dependent | `LiveACPIntegrationTests` |

Build `fake-acp` before spawned integration tests (or run `swift build` once):

```bash
swift build --product fake-acp
```

Scenarios are selected with `CODEMIXER_TWIN_SCENARIO` (`text`, `permission`,
`fsRead`, `auth`, `authFail`, `resume`, `dashboard`, `backgroundPermission`,
`degradedNoDashboard`, `degradedArchived`, `echo`).

`echo` replies with `echo:<prompt text>` rather than a canned string. Use it
when a test has to prove *which* prompt reached the agent — edit-and-resubmit
is the motivating case, since its failure mode is a revised prompt that is
written but never arrives.

```bash
# Always-on unit coverage
swift test --no-parallel --filter ACPAdapter

# Full live validation — configured ACP agent server
CODEMIXER_LIVE_ACP=1 CODEMIXER_LIVE_ACP_BIN=/path/to/agent \
  swift test --no-parallel --filter LiveACPIntegrationTests

# Cursor Agent ACP server
CODEMIXER_LIVE_ACP=1 \
  CODEMIXER_LIVE_ACP_BIN=$HOME/.local/bin/cursor-agent \
  CODEMIXER_LIVE_ACP_ARGS=acp \
  swift test --no-parallel --filter LiveACPIntegrationTests
```

| Variable | Required | Purpose |
| --- | --- | --- |
| `CODEMIXER_LIVE_ACP=1` | Yes (for live turn) | Opt in to a real ACP agent process |
| `CODEMIXER_LIVE_ACP_BIN` | Yes (for live turn) | Path to the ACP agent-server executable |
| `CODEMIXER_LIVE_ACP_ARGS` | No | Space-separated argv after the binary |
| `CODEMIXER_LIVE_WORKSPACE` | No | Workspace directory (defaults to process cwd) |

Auth and install remain out-of-band: if the agent requires login, Codemixer surfaces
`authenticationRequired` / `startupError` and does not open an auth sheet.
For Cursor Agent ACP, authenticate the CLI first or provide `CURSOR_API_KEY`;
otherwise the live harness fails fast with `authenticationRequired`.

---

## Cursor ACP CLI (`ACPCLIs` / `CursorACPCLITests`)

Built-in Cursor adapter over ACP (`cursor-agent acp`). Modes use ACP
`session/set_mode` for `agent` / `plan` / `ask`. `/debug` is diagnostic-only.

| File | Role |
| --- | --- |
| `ACPCLIs/CursorACPCLITests/CursorACPAdapterTests.swift` | Identity, locator, mode encoding |
| `ACPCLIs/CursorACPCLITests/FakeCursorACPIntegrationTests.swift` | Engine + Cursor + `fake-acp` mode switches |
| `ACPCLIs/CursorACPCLITests/LiveCursorACPHarness.swift` | Opt-in live driver + mode probe + two-turn warm latency |
| `ACPCLIs/CursorACPCLITests/LiveCursorACPIntegrationTests.swift` | Live suite for prompt and mode behavior |

Same-project Cursor session switches warm-load via `session/load` on the live `cursor-agent` process (no ~20s respawn). Cold open (first spawn / project change) still pays initialize/auth.

Cursor / ACP visible history and sidebar listing come from AgentCore's
project-local `SessionTranscriptRepository`. `session/load` restores agent state;
any vendor history chunks during that handshake are deliberately suppressed.
Cursor's SQLite catalog is parsed once when an existing project is added.

```bash
swift build --product fake-acp
swift test --no-parallel --filter CursorACPCLI

# Live Cursor ACP (authenticated cursor-agent)
CODEMIXER_LIVE_CURSOR_ACP=1 \
  swift test --no-parallel --filter LiveCursorACPIntegrationTests
```

| Variable | Required | Purpose |
| --- | --- | --- |
| `CODEMIXER_LIVE_CURSOR_ACP=1` | Yes (live) | Opt in |
| `CURSOR_BIN` / `CODEMIXER_LIVE_CURSOR_BIN` | No | Override binary (defaults to PATH / `~/.local/bin/cursor-agent`) |
| `CODEMIXER_LIVE_WORKSPACE` | No | Workspace directory |

---

## Custom ACP CLI (`ACPCLIs` / `CustomACPCLITests`)

Generic ACP wrapper for `ProjectType.custom` projects (`CustomACPAdapter` +
`CustomACPAdapterFactory`). Modes come from the live session; sessions and
visible history live under `<project>/.codemixer/history/`.

| File | Role |
| --- | --- |
| `ACPCLIs/CustomACPCLITests/CustomACPAdapterTests.swift` | Identity, locator, modes, factory cache |
| `ACPCLIs/CustomACPCLITests/FakeCustomACPIntegrationTests.swift` | Engine + Custom + `fake-custom-acp` modes + catalog import |
| `ACPCLIs/CustomACPCLITests/LiveCustomACPHarness.swift` | Opt-in live driver |
| `ACPCLIs/CustomACPCLITests/LiveCustomACPIntegrationTests.swift` | Live suite |

```bash
swift build --product fake-custom-acp
swift test --no-parallel --filter CustomACPCLI

# Live Custom ACP (any ACP stdio binary)
CODEMIXER_LIVE_CUSTOM_ACP=1 CODEMIXER_LIVE_ACP_BIN=/path/to/agent \
  swift test --no-parallel --filter LiveCustomACPIntegrationTests

# Live migration-acp through Codemixer Custom ACP (dashboard + file sessions +
# attention + planner/implementer/dual-review/fixer). Requires authenticated
# cursor-agent; takes tens of minutes.
CODEMIXER_LIVE_CUSTOM_ACP=1 \
  CODEMIXER_LIVE_ACP_BIN=$PWD/migration-tool/dist/migration-acp \
  CODEMIXER_LIVE_MIGRATION_PIPELINE=1 \
  swift test --no-parallel --filter liveMigrationReflection

# Cross-language `initialize` only: does the real migration-acp accept the A2UI
# capabilities Codemixer really advertises? Seconds, no agent auth needed.
CODEMIXER_LIVE_CUSTOM_ACP=1 \
  CODEMIXER_LIVE_ACP_BIN=$PWD/migration-tool/dist/migration-acp \
  CODEMIXER_LIVE_MIGRATION_HANDSHAKE=1 \
  swift test --no-parallel --filter liveMigrationHandshake
```

`fake-custom-acp` is a project-tool flavored twin (`migrate` / `document` / `agent`
modes; reply `Hello from fake-custom-acp.`). It is distinct from `fake-acp`
(Cursor-shaped agent/plan/ask).
| Variable | Required | Purpose |
| --- | --- | --- |
| `CODEMIXER_LIVE_CUSTOM_ACP=1` | Yes (live) | Opt in |
| `CODEMIXER_LIVE_ACP_BIN` / `CODEMIXER_CUSTOM_ACP_BIN` | Yes (live) | ACP executable path |
| `CODEMIXER_LIVE_MIGRATION_PIPELINE=1` | For migration reflection | Opt in to the multi-file Codemixer reflection suite |
| `CODEMIXER_LIVE_MIGRATION_HANDSHAKE=1` | For the handshake probe | Opt in to the `initialize`-only A2UI capability check (implied by `…_PIPELINE=1`) |

---

## Edit-and-resubmit coverage

Editing a restored turn (the composer's pencil) is the one flow that exercises
the stale-edit guard across a process boundary: the reopened engine never minted
the turn id, so it has to adopt the `AdapterTurnID` the journal replayed. Every
adapter reaches it through the same `AgentCommand.editAndResubmitLast` path, so
the deterministic ACP test is the regression guard and the live ones confirm the
real CLIs behave.

| Suite | Gate | Proves |
| --- | --- | --- |
| `FakeACPIntegrationTests` (`editAndResubmitAfterRestoreReachesAgent`) | Always on | Guard survives restore; respawned agent receives the **revised** text (via the `echo` scenario) |
| `LiveClaudeIntegrationTests` (`editAndResubmitAfterResume`) | `CODEMIXER_LIVE_CLAUDE=1` | PTY respawn writes the revised prompt after the TUI's input row is live |
| `LiveCodexIntegrationTests` (`editAndResubmitAfterResume`) | `CODEMIXER_LIVE_CODEX=1` | Superseded thread; fresh thread answers the revised prompt |
| `LiveCursorACPIntegrationTests` (`liveEditAndResubmitAfterLoad`) | `CODEMIXER_LIVE_CURSOR_ACP=1` | Same, over Cursor's ACP `session/load` path |

Claude is the only adapter that can truncate its own transcript; Codex and the
ACP CLIs cannot, so the engine supersedes the session and replays the revised
prompt into a fresh one. Both branches are covered above.
