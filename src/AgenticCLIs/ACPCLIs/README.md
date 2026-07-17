# ACP CLIs

Vendor-specific Agent Client Protocol adapters. Generic ACP framing, codec,
reverse RPC, and session index live in
[`../AgentClientProtocol`](../AgentClientProtocol). This target owns
**named, shipping** ACP-backed CLIs.

## Layout

```
ACPCLIs/
├── README.md
└── Cursor/
    ├── Adapter/CursorACPAdapter.swift
    └── Common/
        ├── CursorBinaryLocator.swift
        └── CursorModeCommand.swift
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

Codemixer therefore encodes Cursor mode changes via `session/set_mode`, not
slash text. `/debug` is listed in the catalog as diagnostic-only and is not
mapped to `session/set_mode`.
