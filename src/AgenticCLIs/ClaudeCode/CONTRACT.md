# Claude Code Contract (Codemixer)

Version: 2026-06-25  
Sources: [Anthropic hooks reference](https://code.claude.com/docs/en/hooks.md), [permissions](https://code.claude.com/docs/en/permissions), Codemixer adapter code, synthetic fixtures (`L3`).

This document is the **executable specification** for what Codemixer expects from the `claude` CLI. The digital twin (`digital-twin/`) implements this contract; `ClaudeAdapter` consumes it.

---

## Compatibility Levels

| Level | Meaning |
| --- | --- |
| `L0` | Official Claude Code docs + mirrored in twin |
| `L1` | Live-captured from real `claude` (manual spike) |
| `L2` | Inferred from adapter/transcript samples; pending live verification |
| `L3` | Synthetic stress case Codemixer must handle |
| `L4` | Out of scope (ledgered below) |

---

## Hook Contract (`L0`)

### Common stdin fields (every event)

`session_id`, `transcript_path`, `cwd`, `hook_event_name`, optional `permission_mode`, optional `effort`.

### Events Codemixer installs hooks for

`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, `SubagentStop`.

### Events documented but not yet decoded

`SessionEnd`, `PreCompact`, `PostCompact`, `PermissionRequest`, `PermissionDenied`, `PostToolUseFailure`, `PostToolBatch`, `UserPromptExpansion`, `SubagentStart`, plus long tail (`MessageDisplay`, `Task*`, `Elicitation*`, `CwdChanged`, `FileChanged`, `ConfigChange`, `Worktree*`, `TeammateIdle`) — triaged in gap ledger or future adapter work.

### Field names (authoritative)

Use `hook_event_name`, `tool_input`, `tool_response`, `tool_use_id`, `tool_name`, `is_error`, `duration_ms`. Do **not** use legacy `type`/`input`/`output`/`exit_code` in new payloads.

### Stop hook extras

`stop_hook_active`, `last_assistant_message`, `background_tasks`, `session_crons`.

### Settings

Project-local `.claude/settings.local.json` with `hooks` object. Precedence: managed policy → CLI → `.claude/settings.local.json` → `.claude/settings.json` → `~/.claude/settings.json`.

---

## Behavior Matrices

Status: `handled` = adapter + twin scenario + test; `unhandled` = triage pending; `ledger` = intentional gap.

### Hook events (`ClaudeHookDecoder`)

| Event | Adapter | Twin | Test |
| --- | --- | --- | --- |
| SessionStart | handled | handled | TwinDecoderParityTests |
| UserPromptSubmit | handled | handled | TwinDecoderParityTests |
| PreToolUse | handled | handled | TwinDecoderParityTests |
| PostToolUse | handled | handled | TwinDecoderParityTests |
| Notification | handled | handled | TwinDecoderParityTests |
| Stop | handled (idle) | handled | TwinDecoderParityTests |
| SubagentStop | handled (idle) | handled | ConformanceFixtures |
| PermissionRequest | unhandled | ledger | — |
| PostToolUseFailure | unhandled | ledger | — |
| PostToolBatch | unhandled | ledger | — |
| SubagentStart | unhandled | ledger | — |

### Transcript record types (`ClaudeTranscriptTailer`)

| Type | Adapter | Twin | Test |
| --- | --- | --- | --- |
| assistant (text/thinking/tool_use/usage) | handled | handled | TranscriptTailerTests |
| user (text + tool_result) | handled | handled | TranscriptTailerTests |
| tool_result (top-level) | handled | handled | TranscriptTailerTests |
| summary | ledger | ledger | — |
| system | ledger | ledger | — |
| file-history-snapshot | ledger | ledger | — |

### TUI fallback (`ClaudeTUIFallback`)

| Surface | Adapter | Twin fake-claude | Test |
| --- | --- | --- | --- |
| auth URL scrape | handled | handled | TUIFallbackTests |
| status phrases | handled | handled | TUIFallbackTests |
| file edit hints | handled | handled | TUIFallbackTests |
| workspace trust screen | handled | handled | TUIFallbackTests |
| resume prompt readiness | engine | handled | FakeClaudeIntegrationTests |
| startup submit recovery | engine | handled | FakeClaudeIntegrationTests |

### Permission modes (`L0`)

`default`, `acceptEdits`, `plan`, `auto`, `dontAsk`, `bypassPermissions`.

PTY permission bytes: `1\r` allow, `2\r` allow-always, `3\r` deny (+ hook stdout for PreToolUse). Workspace trust: `1\r` trust, `2\r` exit.

---

## Version Matrix

| Fixture set | Claude version | Status |
| --- | --- | --- |
| hooks-synthetic | N/A (L3) | CI default |
| transcripts-synthetic | N/A (L3) | CI default |
| live-capture | pending | Manual; requires logged-in `claude` |

Minimum supported: TBD after first live capture. Last verified: synthetic-only (2026-06-25).

When live capture is unavailable, rows stay `L2`/`L3` and are marked `pending live verification` in matrices above.

---

## Gap Ledger (`L4` / deferred)

| Behavior | Why out of scope | Mitigation |
| --- | --- | --- |
| Model reasoning quality | Unobservable | Scripted twin text |
| Real billing/metering | Backend-private | Synthetic usage fields |
| Anthropic backend outages | Not CLI-contract | Surface only via CLI output if present |
| Exact TUI cursor choreography | Only need parser subset | ClaudeTUIFallback patterns |
| `--print` non-interactive mode | Codemixer uses PTY only | Documented |
| Deep subagent recursion (>1) | Twin caps at one level | Extend twin if needed |
| Undocumented transcript internals | No public schema | Hooks supply `transcript_path`, `last_assistant_message` |
| Long-tail hook events | Not Codemixer-critical v1 | Ledger; add when fixtures prove need |

---

## Change Policy

Claude Code behavior change → update this file, twin emitter/runtime, adapter, fixtures, and tests in the same PR.
