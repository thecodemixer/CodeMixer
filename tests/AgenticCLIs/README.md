# Agentic CLI tests

Test suites for adapters under `src/AgenticCLIs/` mirror that layout here:

```
tests/AgenticCLIs/
├── README.md                 # this file
└── <AgentName>/              # one folder per agent (e.g. ClaudeCode)
    ├── <Agent>AdapterTests/  # SPM test target — adapter parsers, hooks, transcript
    └── <Agent>TwinTests/     # optional second target — digital-twin + engine E2E
```

Claude Code (v1):

| SPM test target | Path |
| --- | --- |
| `ClaudeAdapterTests` | `ClaudeCode/ClaudeAdapterTests/` |
| `ClaudeCodeTwinTests` | `ClaudeCode/ClaudeCodeTwinTests/` |

Target names stay stable; only directory paths move when colocating with `src/AgenticCLIs/<AgentName>/`.

Source layout, twin rules, and the add-agent checklist: [`src/AgenticCLIs/README.md`](../../src/AgenticCLIs/README.md).
