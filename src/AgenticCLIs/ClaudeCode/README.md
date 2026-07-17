# Claude Code — Codemixer contract

Canonical specification: [`CONTRACT.md`](CONTRACT.md) (matrices, gap ledger, version policy).

This module implements the Claude Code adapter (`Adapter/`), shared contract logic
(`Common/`), and the digital twin (`digital-twin/`).

## Model catalog

Composer models come from `claude -p '/model'` (plus `/effort` for thinking
levels). Print mode can consume agent credits, so Codemixer:

1. Stores the catalog in `<workspace>/.codemixer/workspace.json` (`adapterModelCaches`)
2. Runs the probe once when that cache is empty
3. Re-runs only when the user clicks **Refresh models** under Settings → Workspace

Codex and Cursor keep automatic discovery; their Workspace refresh controls stay disabled.

## Process model

Codemixer spawns `claude` under a hidden PTY. Semantics flow through:

| Channel | Carrier | Purpose |
| --- | --- | --- |
| Hooks | `.claude/settings.local.json` → command → UDS | Low-latency lifecycle events |
| Transcript | `~/.claude/projects/<slug>/<session-id>.jsonl` | Canonical assistant text, tools, usage |
| PTY | stdin/stdout bytes | Prompts, permissions, TUI fallback scrape |

## Hook envelope (`L0`)

Every hook payload includes: `session_id`, `transcript_path`, `cwd`, `hook_event_name`,
optional `permission_mode`, optional `effort`.

Field names: `hook_event_name`, `tool_input`, `tool_response`, `tool_use_id`, `tool_name`.
Do **not** use legacy `type`/`input`/`output`.

Installed events: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
`Notification`, `Stop`, `SubagentStop`.

`Stop` may include `last_assistant_message`. The adapter binds `transcript_path` from hooks.

### Assistant-text authority (no double replies)

| Channel | Role |
| --- | --- |
| Transcript JSONL | **Canonical** final `assistantText` |
| Stop `last_assistant_message` | **Fallback** only if the tailer has not yet emitted for the session |

On Stop/SubagentStop, `ClaudeAdapter` drains the transcript first, then drops hook
`assistantText` when `ClaudeTranscriptTailer.hasEmittedAssistantText()` is true.
Without this, every turn would paint two assistant bubbles (transcript + Stop).

### Interactive billing path (avoid Agent Credits)

`buildLaunchArgv` launches bare `claude` under a PTY — never `--print` / `-p` /
stream-json. This keeps Codemixer off the Agent Credits path used by
third-party / SDK-style Claude Code invocations. Live transcript markers should
show `entrypoint: "cli"` and `promptSource: "typed"` (not `sdk-cli` / `sdk`).
Opt-in validation:
[`tests/AgenticCLIs/README.md`](../../../tests/AgenticCLIs/README.md#live-claude-harness-claudecodetwintests).

## Settings

Project-local `.claude/settings.local.json` (see `ClaudeHookSettings.swift`). Not global
`hooks_socket_path`.

## Transcript slug

`ClaudeProjectPaths.projectSlug`: preserve case; replace non-alphanumeric with `-`;
keep leading dash from absolute paths.

## Permission bytes

PTY: `1\r` allow, `2\r` allow-always, `3\r` deny. Workspace trust: `1\r` trust, `2\r` exit.

## Digital twin and live harness

- In-process: `ClaudeCodeTwin` (`digital-twin/Twin/`) — fast projection tests.
- Executable: `fake-claude` — integration authority (`CODEMIXER_FAKE_CLAUDE=1`).
- Live account: `LiveClaudeHarness` in `ClaudeAdapterTests` (`CODEMIXER_LIVE_CLAUDE=1`).
- Coverage statement: [`digital-twin/README.md`](digital-twin/README.md).
- Test catalog: [`tests/AgenticCLIs/README.md`](../../../tests/AgenticCLIs/README.md).

## Change policy

Claude behavior change → update `CONTRACT.md`, twin, adapter, fixtures, tests in one PR.
