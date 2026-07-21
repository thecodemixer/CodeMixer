# ACP CLIs

Vendor-specific and generic Agent Client Protocol adapters. Framing, codec,
reverse RPC, and the shared session index live in
[`../AgentClientProtocol`](../AgentClientProtocol). This target owns
**shipping** ACP-backed CLIs (Cursor) and the **generic Custom** wrapper used
for `ProjectType.custom` ACP projects.

## Layout

```
ACPCLIs/
├── README.md
├── Cursor/
│   ├── Adapter/CursorACPAdapter.swift
│   └── Common/
│       ├── CursorBinaryLocator.swift
│       ├── CursorModeCommand.swift
│       └── CursorModelCatalog.swift
└── Custom/
    ├── Adapter/
    │   ├── CustomACPAdapter.swift
    │   └── CustomACPAdapterFactory.swift
    ├── Common/
    │   ├── CustomACPBinaryLocator.swift
    │   └── CustomACPModeMapping.swift
    └── digital-twin/fake-custom-acp/   # `swift build --product fake-custom-acp`
```

## Cursor ACP contract snapshot

Probed against `cursor-agent` `2026.04.15-dccdccd` (`cursor-agent acp`):

| Concern | Behavior |
| --- | --- |
| Launch | `cursor-agent acp` over `.agentClientProtocol` / stdio JSON-RPC |
| Auth | `initialize` advertises `cursor_login`; call `authenticate` then `initialized` + `session/new` |
| Modes | `session/new` returns `modes.availableModes`: `agent`, `plan`, `ask` (default `agent`) |
| Mode switch | ACP `session/set_mode` with `modeId`; agent emits `current_mode_update` |
| Slash `/agent` `/plan` `/ask` | Treated as ordinary prompts — **not** mode switches |
| `/debug` | **Not** an ACP chat mode. Slash `/debug` only starts a conversational debug help turn. CLI `--mode` has no `debug` choice. Documented as diagnostic-only. |
| Models | `session/new` may include `models.availableModels` |
| Sessions | App-support `ACPSessionIndex` (turn cache for empty `session/load`) |

Codemixer therefore encodes Cursor mode changes via `session/set_mode`, not
slash text. `/debug` is listed in the catalog as diagnostic-only and is not
mapped to `session/set_mode`.

## Custom ACP contract

`CustomACPAdapter` wraps `ACPAdapter` for any user-configured ACP binary
(`ProjectType.custom` + transport Agent Client Protocol). Bootstrap/daemon
register `CustomACPAdapterFactory` (caches by `CustomAgentRef`).

| Concern | Behavior |
| --- | --- |
| Launch | Resolved executable + `CustomAgentRef.arguments` (`CODEMIXER_CUSTOM_ACP_BIN` override for tests) |
| Auth / handshake | Inherited from `ACPAdapter` (`.sessionHandshakeGate`) |
| Modes | Dynamic from `session/new` `availableModes` (id + name + description); composer lists them; slash `/<id>` remaps to `session/set_mode` |
| Models | From ACP session (`availableModels`) |
| Sessions | Project-local store under `<project>/.codemixer/acp/<customAgentID>/` |
| Twin | `fake-custom-acp` advertises `migrate` / `document` / `agent` (not Cursor’s plan/ask) |

### Project store layout

```
<project>/.codemixer/acp/<customAgentID>/
  sessions-index.json
  transcripts/<session-id>.jsonl
```

- Index holds metadata + embedded turns (same turn-cache roles as Cursor:
  `user` / `thinking` / `tool` / `assistant`) for `localHistoryEvents` on empty
  `session/load`.
- JSONL is dual-written on each append (portable transcript; same 200-turn cap).
- One-time migrate copies matching rows from app-support `acp-sessions.json`.
- Resume still uses ACP `session/load` / `session/resume`; JSONL is not a
  substitute for agent state.

This Codemixer-owned transcript is an intentional exception for custom CLIs
that do not write a vendor JSONL of their own (see `docs/architecture.md`).

### Dashboard URL, reverse session/new, archive & attention

Custom ACP agents may advertise extensions via `_meta` (additive; unknown keys are ignored):

| Key | Direction | Effect |
| --- | --- | --- |
| `codemixer.dev/dashboardUrl` | agent → client on `initialize` | Emits `AgentEvent.agentDashboard`. Adapters with `.overviewDashboard` show that page when the **project** is selected (no Chat/Dashboard tab). File sessions stay chat-only. |
| `codemixer.dev/dashboardTitle` | agent → client on `initialize` | Agent-owned visible title for the sidebar overview row; never hardcoded by Codemixer |
| `codemixer.dev/overviewSession` | `session/new` reverse RPC or `session_info_update` `_meta` | Marks a session as the project overview/control session (`SessionSummary.isOverview`) |
| `codemixer.dev/sessionNew` | client → agent on `initialize` | Agent may reverse-RPC `session/new` to register sidebar sessions |
| `_meta.archived` | `session_info_update` | Session hidden from sidebar summaries |
| `_meta.needsAttention` | `session_info_update` | Per-session sidebar badge; project-row attention count rollup; `sessionAttentionChanged` → macOS notification (`Migration Tool` / `"<title> needs human review"`) |

Streaming `session/update` chunks are scoped to the foreground `sessionId`; background permission prompts are parked per-session (not in `pendingApprovals`, which is cleared on switch) and re-emitted after `session/load`.

Reference product using this contract: top-level [`migration-tool/`](../../../migration-tool/) (SQL Server / API → MongoDB migrator).
