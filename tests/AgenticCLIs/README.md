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

