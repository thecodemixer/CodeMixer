# Claude Code digital twin

Executable specification and offline test double for Codemixer. See [`../CONTRACT.md`](../CONTRACT.md) for the full contract.

## Components

| Component | Role |
| --- | --- |
| `Twin/` | Shared scenario runtime, hook emitter, transcript builder, PTY scripts |
| `fake-claude` | PTY-aware CLI substitute for integration tests |

## Supported (`L0`–`L3`)

Derived from behavior matrices in `CONTRACT.md`:

- Hook events: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Notification, Stop, SubagentStop
- Transcript: assistant text/thinking/tool_use, user text, tool_result, usage fields
- Scenarios: `textOnly`, `thinkingThenReply`, `withBash`, `withEdit`, `permissionPrompt`, `needsAuth`, `usageOnly`, `crash`, `workspaceTrust`, `resumeLatePrompt`, `resumeStalled`, `swallowedEnter`, `sequence`
- CLI: `auth status --json`, `--permission-mode`, `--resume`, scenario env vars
- TUI frames: prompt readiness, auth URL, workspace trust, status working

## Not supported (gap ledger)

- Private model reasoning — scripted text only
- Real billing/metering — synthetic usage
- Anthropic backend outages
- Exact TUI cursor choreography — parser subset only
- `--print` non-interactive mode
- Deep subagent recursion (>1 level)
- Undocumented transcript internals — hooks supply `transcript_path` / `last_assistant_message`; live harness verifies fusion policy
- Real interactive billing path — use live harness / spikes, not the twin

## Verified against

| Fixture set | Claude version | Status |
| --- | --- | --- |
| hooks-synthetic | N/A (L3) | CI default |
| transcripts-synthetic | N/A (L3) | CI default |
| live-harness | 2.1.x | Opt-in: `CODEMIXER_LIVE_CLAUDE=1` (see [`tests/AgenticCLIs/README.md`](../../../tests/AgenticCLIs/README.md)) |

## How to drive

```bash
swift build --product fake-claude
export CLAUDE_BIN="$(pwd)/.build/debug/fake-claude"
export CODEMIXER_TWIN_SCENARIO=text
# or: CODEMIXER_TWIN_SCENARIO=bash|permission|workspace-trust|resume-late
export CODEMIXER_TWIN_AUTH=0   # unauthenticated auth status
```

Fixtures: `tests/AgenticCLIs/ClaudeCode/ClaudeAdapterTests/Fixtures/`

## Cross-links

- Contract spec: [`../CONTRACT.md`](../CONTRACT.md)
- Conformance: `TwinDecoderParityTests`, `ConformanceFixturesTests`, `FakeClaudeIntegrationTests`
- Live account (not twin): `LiveClaudeHarness` / `LiveClaudeIntegrationTests` in `ClaudeCodeTwinTests`
