# Claude Code — Codemixer contract

Canonical specification: [`CONTRACT.md`](CONTRACT.md) (matrices, gap ledger, version policy).

This module implements the Claude Code adapter (`Adapter/`), shared contract logic
(`Common/`), and the digital twin (`digital-twin/`).

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

## Settings

Project-local `.claude/settings.local.json` (see `ClaudeHookSettings.swift`). Not global
`hooks_socket_path`.

## Transcript slug

`ClaudeProjectPaths.projectSlug`: preserve case; replace non-alphanumeric with `-`;
keep leading dash from absolute paths.

## Permission bytes

PTY: `1\r` allow, `2\r` allow-always, `3\r` deny. Workspace trust: `1\r` trust, `2\r` exit.

## Digital twin

- In-process: `ClaudeCodeTwin` (`digital-twin/Twin/`) — fast projection tests.
- Executable: `fake-claude` — integration authority (`CODEMIXER_FAKE_CLAUDE=1`).
- Coverage statement: [`digital-twin/README.md`](digital-twin/README.md).

## Change policy

Claude behavior change → update `CONTRACT.md`, twin, adapter, fixtures, tests in one PR.
