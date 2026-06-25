# Agentic CLIs

This folder holds **one Swift package target per interactive coding-agent CLI**
that Codemixer drives under a hidden PTY (`claude` in v1; Codex, Cursor CLI,
Gemini CLI, etc. later). Each agent is a leaf module: `AgentCore` and `AgentUI`
stay agent-agnostic; nothing here imports SwiftUI.

Read [`docs/reference/patterns/plugin-adapter-protocol.md`](../../docs/reference/patterns/plugin-adapter-protocol.md)
for the `AgentAdapter` contract and
[`docs/architecture.md` §5](../../docs/architecture.md) for how targets wire
into the daemon and GUI.

---

## Layout convention (required)

Every agent under `src/AgenticCLIs/<AgentName>/` uses the same three-folder
shape. **Do not invent a fourth top-level bucket** without updating this README
and `Package.swift` in the same PR.

```
src/AgenticCLIs/
├── README.md                 # this file — the convention
└── <AgentName>/              # one SPM library target (e.g. ClaudeCode)
    ├── README.md             # executable contract for that CLI (hooks, transcript, PTY)
    ├── Adapter/              # production `AgentAdapter` + parsers/installers
    ├── Common/               # code shared by Adapter/ and digital-twin/ only
    └── digital-twin/
        ├── Twin/             # in-process twin (`AgentAdapter` for tests)
        └── <fake-binary>/    # optional stand-in executable for CI / no-login dev
```

### `Adapter/`

Production integration: binary discovery, hook decode, transcript tailing, TUI
fallback, settings injection, and the type that conforms to `AgentAdapter`.

- May import `AgentCore`, `AgentProtocol`, and types from `Common/`.
- Must not import another agent's folder or `AgentUI` / `AgentRemoteControl`.

### `Common/`

Shared **contract surface** used by both the adapter and the digital twin:
path conventions, stdin encoding, built-in slash-command catalog, session-list
helpers, and other logic that must stay identical in tests and production.

- Twin and adapter both compile against `Common/` inside the same SPM target.
- Twin sources must not call adapter-only types (`*HookDecoder`, `*TranscriptTailer`, …).
  Parity tests in `<Agent>AdapterTests` validate the contract from the outside.

### `digital-twin/`

Runnable specification of what Codemixer expects from the external CLI. A digital
twin is **not** a mock object hidden in a test helper — it is the codified,
executable form of our explicit understanding of the vendor contract.

| Subfolder | Purpose |
| --- | --- |
| `Twin/` | Deterministic in-process `AgentAdapter` for `swift test` without the real binary. |
| `<fake-binary>/` | Optional minimal executable (e.g. `fake-claude`) resolved when `CODEMIXER_FAKE_*=1`. Excluded from the library target; declared as its own `executableTarget` in `Package.swift`. |

**Why we maintain twins**

1. **Tests without the real binary.** `swift test` works on CI without `claude`
   installed because `ClaudeCodeTwin` satisfies the same `AgentAdapter` contract.
2. **The twin is documentation.** Vendor schema changes update the twin first; a
   diff against the twin is a diff against our model of the world.
3. **Deterministic failure modes.** Thinking pauses, permission timeouts,
   truncated JSONL, crash mid-turn — one-line test cases.
4. **No subscription burn.** The twin never spends tokens or authenticates against
   a real backend.

**Rules**

- Twin sources must not call adapter-only parser types (`*HookDecoder`,
  `*TranscriptTailer`, …). Parity tests in `<Agent>AdapterTests` validate the
  contract from the outside.
- Twins are runnable end-to-end: own state, real-time bytes/JSONL/hook payloads,
  full engine lifecycle.
- State every guess: `// ASSUMPTION:` plus how it was verified (or that it wasn't).
- Version with the contract: new hook events land in the agent `README.md`, `Twin/`,
  and `Adapter/` in the same PR.

Update the agent's `README.md` first when the vendor changes hook JSON, transcript
JSONL, or PTY semantics; then update `Twin/`, then `Adapter/`.

---

## SPM wiring checklist

Adding `src/AgenticCLIs/CodexCLI/` (example):

1. **Library target** — `path: "src/AgenticCLIs/CodexCLI"`, `exclude: ["README.md", "digital-twin/fake-codex"]` (adjust fake path).
2. **Product** — `.library(name: "CodexCLI", targets: ["CodexCLI"])`.
3. **Fake executable** (if any) — separate `executableTarget` under `digital-twin/`.
4. **Register at startup** — `await AdapterRegistry.shared.register(CodexAdapter())` in `CodemixerApp` / `CodemixerDaemon` only; never from `AgentCore` or `AgentUI`.
5. **Tests** — `tests/AgenticCLIs/<AgentName>/<Agent>AdapterTests/`, optional `<Agent>TwinTests/`; depend on the new library, not on other agents. See [`tests/AgenticCLIs/README.md`](../../tests/AgenticCLIs/README.md).
6. **Docs** — agent contract `README.md`, row in root `README.md` module map, pointer in this file's inventory below.

---

## Inventory

| Folder | SPM target | Real binary | Fake executable |
| --- | --- | --- | --- |
| [`ClaudeCode/`](ClaudeCode/README.md) | `ClaudeCode` | `claude` | `fake-claude` |

---

## Cross-links

- Claude Code contract (v1 reference): [`ClaudeCode/README.md`](ClaudeCode/README.md)
