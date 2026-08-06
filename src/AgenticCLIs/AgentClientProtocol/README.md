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
| A2UI | `initialize` advertises `A2UISchemaProfile.clientCapabilitiesMetaKey` capability (test-scoped catalog id only, see `docs/architecture.md` §36); a MIME-typed (`application/a2ui+json`) `EmbeddedResource` inside `session/update`/`tool_call` content decodes to `AgentEvent.a2uiBatch` via `ACPEventDecoder+A2UI`; client actions/errors encode back as `session/prompt` via `ACPInputEncoding.a2uiAction`/`a2uiClientError` under `RequestPurpose.a2uiFeedbackPrompt` (never finalizes a chat turn) |
| Sessions | AgentCore's project-local `SessionTranscriptRepository` owns listing and visible history. `session/load` restores only agent state; replayed history chunks are discarded. Foreign live updates enter the repository through `recordBackgroundSessionEvents`. **One ACP process hosts many session ids** — New Chat / warm resume issue `session/new` or `session/load` on the existing stdio transport rather than respawning; the decoder scopes streaming and permissions by `sessionId` so a previous session's late frames never paint as the foreground chat. |
| Existing-project import | `ACPSessionCatalogImporter` reads the retired Custom ACP `.codemixer/acp/<id>/sessions-index.json` format once; no live ACP turn cache remains. |

Production custom projects register `CustomACPAdapterFactory` from `ACPCLIs`
(Bootstrap/daemon). `ACPCustomAgentAdapterFactory` still builds a bare
`ACPAdapter` for unit/twin tests.

## Layout

- `Adapter/ACPAdapter.swift` — production `AgentAdapter` (implements `encodeA2UIAction`/`encodeA2UIClientError`)
- `Common/` — framing, codec, state, decoder, retired-catalog importer, FS/terminal helpers
- `Common/ACPEventDecoder+A2UI.swift` — decodes MIME-typed A2UI `EmbeddedResource` content into `A2UIServerBatch`
- `External/ACPTerminalProcess.swift` — sole `Process()` site for reverse terminals
- `digital-twin/Twin/ACPTwin.swift` — deterministic test twin
- `digital-twin/Twin/ACPTwinScenario.swift` — scripted scenarios for `fake-acp`
- `digital-twin/fake-acp/` — stdio ACP server twin (`swift build --product fake-acp`)
