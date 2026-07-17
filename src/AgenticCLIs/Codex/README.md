# Codex adapter contract

The `Codex` target integrates OpenAI Codex through `codex app-server --stdio`.
It vendors the small protocol layer needed by Codemixer; no Codex SDK package is
linked.

## Launch and bootstrap

- Binary lookup order: `CODEX_BIN`, resolved shell `PATH`, `~/.local/bin`,
  `~/.npm-global/bin`, `~/.bun/bin`, `/opt/homebrew/bin`, `/usr/local/bin`.
- Launch argv is always `codex app-server --stdio`. Resume IDs never appear in
  argv.
- The first JSONL frames are `initialize`, `initialized`, and exactly one of
  `thread/start` or `thread/resume`.
- Fresh threads send `cwd`, `approvalPolicy`, and `sandbox`. The adapter does
  not send the experimental `permissions` field alongside `sandbox`.

## Input and lifecycle

- Prompts use `turn/start` with typed `text`, `image`, `localImage`, `skill`,
  and `mention` input items.
- Thread and turn identities come from response payloads at
  `result.thread.id` and `result.turn.id`.
- Cancellation sends `turn/interrupt` only while the session state has an
  active thread and turn.
- Permission requests become `AgentEvent.permissionRequest`; responses carry
  the original JSON-RPC request ID.

## Events

- Agent-message deltas become non-final `assistantText` updates; completed
  messages become final `assistantText`.
- Tool-shaped `item/started` and `item/completed` notifications become
  `toolStart` and `toolEnd`.
- Unknown notifications are recorded in `SilentDiagnostics`.
- Unknown server requests emit an adapter-boundary error and receive JSON-RPC
  error `-32601`.

## Sessions

Codex owns transcripts. Codemixer persists only `codex-threads.json` under its
Application Support directory for session navigation. Editing a prior turn
supersedes the indexed thread and falls back to a fresh thread because Codemixer
does not rewrite Codex rollout files.

`digital-twin/Twin/CodexTwin.swift` is the in-process executable specification.
No fake Codex binary is included.

## Digital twin and live harness

- In-process: `CodexTwin` (`digital-twin/Twin/`) — fast projection tests in `CodexTwinTests`.
- Scripted transport: fixture bytes in `CodexAdapterTests` — no live login.
- Live account: `LiveCodexHarness` in `CodexAdapterTests` (`CODEMIXER_LIVE_CODEX=1`).
- Test catalog: [`tests/AgenticCLIs/README.md`](../../../tests/AgenticCLIs/README.md).
