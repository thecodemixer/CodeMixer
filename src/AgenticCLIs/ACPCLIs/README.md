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
├── Common/
│   └── ACPBackedAdapter.swift   # shared AgentAdapter forwarding to `inner: ACPAdapter`
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

`CursorACPAdapter` and `CustomACPAdapter` both wrap an `ACPAdapter` and conform to
`ACPBackedAdapter`, which supplies the `AgentAdapter` requirements that are pure
byte-for-byte forwarding to `inner` (`makeEventStream`, `encodeUserPrompt`,
`cancelSequence`, `sessionBootstrapBytes`, `encodeResumeSession`,
`encodePermissionResponse`) plus the two vendors' identical
`defaultEnvOverrides`/`authStatus`/`enumerateProjectCommands`/
`resumeArgvAddition` answers. Identity, launch argv, and mode-mapping
(`encodeCommand`, `availableAgentModes`, `availableModels`,
`importSessionCatalog`) differ per vendor and stay in each adapter.

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
| Sessions | AgentCore project-local transcript/index; Cursor SQLite is read once when an existing project is added |

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
| Auth / readiness | Inherited from `ACPAdapter`; the composer unlocks after the real session open response |
| Modes | Dynamic from `session/new` `availableModes` (id + name + description); composer lists them; slash `/<id>` remaps to `session/set_mode` |
| Models | From ACP session (`availableModels`) |
| Sessions | AgentCore store under `<project>/.codemixer/history/`; old ACP project stores are one-shot import sources |
| Twin | `fake-custom-acp` advertises `implement` / `document` / `agent` (not Cursor’s plan/ask) |

### Retired project store import

```
<project>/.codemixer/acp/<customAgentID>/
  sessions-index.json
  transcripts/<session-id>.jsonl
```

`ACPSessionCatalogImporter` can read this retired format when an existing
project is added. New turns are never dual-written here. Resume still uses ACP
`session/load` for agent state, while visible history and listing always come
from AgentCore's `SessionTranscriptRepository`.

### Dashboard URL, reverse session/new, archive & attention

Custom ACP agents may advertise extensions via `_meta` (additive; unknown keys are ignored).
All CodeMixer-owned keys use the lowercase `com.codecave.codemixer` prefix from
`CodemixerACPKeys`, which is distinct from the macOS bundle identifier:

| Key | Direction | Effect |
| --- | --- | --- |
| `com.codecave.codemixer/a2ui` | client → agent on `initialize` | Advertises the supported A2UI versions and catalogs. The bare `a2ui` alias is rejected. |
| `com.codecave.codemixer/sessionNew` | client → agent on `initialize` | Agent may reverse-RPC `session/new` to register sidebar sessions. |
| `com.codecave.codemixer/phase_update` | agent → client `session/update` | Emits an ordered `sessionPhaseChanged` event. |
| `com.codecave.codemixer/overviewSession` | `session/new` reverse RPC or `session_info_update` `_meta` | Marks a session as the project overview/control session (`SessionSummary.isOverview`). |
| `com.codecave.codemixer/dashboardUrl` | agent → client on `initialize` | Emits `AgentEvent.agentDashboard`. Adapters with `.overviewDashboard` show that page when the **project** is selected (no Chat/Dashboard tab). File sessions stay chat-only. |
| `com.codecave.codemixer/dashboardTitle` | agent → client on `initialize` | Agent-owned visible title for the sidebar overview row; never hardcoded by Codemixer. |
| `_meta.archived` | `session_info_update` | Session hidden from sidebar summaries |
| `_meta.needsAttention` | `session_info_update` | Per-session sidebar badge; project-row attention count rollup; `sessionAttentionChanged` → macOS notification (agent display name / `"<title> needs human review"`) |

Streaming `session/update` chunks for foreground sessions enter the normal event stream. Foreign chunks are persisted through `recordBackgroundSessionEvents` without reaching the foreground UI. Background permission prompts are parked per-session (not in `pendingApprovals`, which is cleared on switch) and re-emitted after `session/load`.

Reference Custom ACP products using this contract live in their own repositories (not in this tree).
