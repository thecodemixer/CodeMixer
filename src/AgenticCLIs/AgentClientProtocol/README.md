# Agent Client Protocol

Codemixer acts as an **ACP client**. User-configured custom projects that select
Agent Client Protocol launch an ACP agent server over stdio JSON-RPC
(`StdioJSONRPCTransport`).

## Contract

| Concern | Behavior |
| --- | --- |
| Transport | `.agentClientProtocol` → newline-delimited JSON-RPC 2.0 |
| Bootstrap | `initialize` only; after success/authenticate → `initialized` + `session/new` or `session/load` / `session/resume` |
| Auth | If `authMethods` is non-empty, call ACP `authenticate` with the advertised method so the server can reuse existing CLI credentials; auth failures surface `authenticationRequired` — no in-app auth UI |
| Prompt | `session/prompt` with text content blocks |
| Cancel | `session/cancel` notification |
| Updates | `session/update` → `AgentEvent`s |
| Reverse RPCs | `fs/*`, `terminal/*`, `session/request_permission` |
| Sessions | `ACPSessionIndexing`: app-support `ACPSessionIndex` (Cursor / bare) or project `ACPProjectSessionStore` (Custom under `.codemixer/acp/<id>/`) |

Production custom projects register `CustomACPAdapterFactory` from `ACPCLIs`
(Bootstrap/daemon). `ACPCustomAgentAdapterFactory` still builds a bare
`ACPAdapter` for unit/twin tests.

## Layout

- `Adapter/ACPAdapter.swift` — production `AgentAdapter`
- `Common/` — framing, codec, state, decoder, session index, FS/terminal helpers
- `External/ACPTerminalProcess.swift` — sole `Process()` site for reverse terminals
- `digital-twin/Twin/ACPTwin.swift` — deterministic test twin
- `digital-twin/Twin/ACPTwinScenario.swift` — scripted scenarios for `fake-acp`
- `digital-twin/fake-acp/` — stdio ACP server twin (`swift build --product fake-acp`)
