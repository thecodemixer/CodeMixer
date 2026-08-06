# Scripts Guide

This directory contains local automation and validation helpers for Codemixer.

## Conventions

- Scripts are Swift-first (`.swift`) and are intended to run locally.
- Run from repository root unless noted.
- Make executable once (`chmod +x scripts/<name>.swift`) or invoke with `swift`.
- Live-account spikes are manual tools and should **not** run in CI.

## Script Inventory

### Build, Test, and Project

- `generate-xcodeproj.swift`
  - Generates `src/CodemixerApp/Codemixer.xcodeproj` via Tuist.
  - Usage:
    - `scripts/generate-xcodeproj.swift`
    - `scripts/generate-xcodeproj.swift --no-open`
    - `scripts/generate-xcodeproj.swift --clean`

- `swift-test.swift`
  - Preferred way to run the SPM suite. Always injects `--no-parallel`, and by
    default clears leftover `CODEMIXER_LIVE_*` / `MIGRATION_LIVE*` environment
    gates so a prior live session cannot arm multi-minute harnesses during a
    normal unit/integration run.
  - Usage:
    - `scripts/swift-test.swift`
    - `scripts/swift-test.swift --filter A2UIActionResolverTests`
    - `scripts/swift-test.swift --allow-live --filter LiveCustomACPIntegrationTests`
  - Extra args after optional flags are forwarded to `swift test`.

- `pre-commit.swift`
  - Local pre-commit hook: `swift build`, `scripts/swift-test.swift`, SwiftFormat lint, SwiftLint.
  - This is a **narrow** gate — it does not run the full merge checklist (`check-package-layout`, `check-a11y`, `regen-coverage-manifest --check`, `check-test-runtime`, etc.). Run those manually before opening a PR.
  - Typical install:
    - `ln -sf ../../scripts/pre-commit.swift .git/hooks/pre-commit`

- `check-test-runtime.swift`
  - Parses `swift test` output from `stdin` and fails if suite runtime budgets are exceeded.
  - Usage:
    - `scripts/swift-test.swift 2>&1 | scripts/check-test-runtime.swift`
  - Uses overrides from `test-runtime-overrides.json`.

### Architecture / Policy Checks

- `check-no-swiftui-imports.swift`
  - Ensures `import SwiftUI` appears only in allowed UI targets.

- `check-direct-framework-calls.swift`
  - Prevents direct calls to wrapped Apple and SQLite APIs outside `External/` wrapper seams.
  - Usage:
    - `scripts/check-direct-framework-calls.swift`
    - `scripts/check-direct-framework-calls.swift <SourcesDirectory>`

- `check-a11y.swift`
  - Audits `AgentUI` for icon-only controls missing nearby accessibility metadata.
  - Usage:
    - `scripts/check-a11y.swift`
    - `scripts/check-a11y.swift <SourcesDirectory>`

- `regen-coverage-manifest.swift`
  - Regenerates / validates public API symbol inventory used by coverage-manifest tests.
  - Usage:
    - `scripts/regen-coverage-manifest.swift`
    - `scripts/regen-coverage-manifest.swift --check`

- `check-package-layout.swift`
  - Fails if tests drift back under a nested package layout or a suite directory is missing.
  - Usage:
    - `scripts/check-package-layout.swift`

- `check-no-personal-paths.swift`
  - Fails when sources or docs contain macOS home-directory paths (live probes must use env vars or neutral placeholders).
  - Usage:
    - `scripts/check-no-personal-paths.swift`

### Local developer setup

- `configure-cursor-cli-file-credentials.swift`
  - Adds `export AGENT_CLI_CREDENTIAL_STORE=file` to `~/.zprofile` so `cursor-agent`
    stores CLI auth in a file instead of macOS Keychain.
  - **When you need this:** Cursor CLI on macOS can fail to read Keychain-backed
    tokens after auto-updates or `cursor-agent login` — symptoms include
    `Keychain operation timed out after 30000ms`, `Authentication required` on
    `cursor-agent models`, or an empty model list in Codemixer even though the IDE
    is signed in. Codemixer discovers Cursor models by shelling out to
    `cursor-agent models` with the resolved interactive-shell environment; if
    that probe cannot read credentials, the composer model menu stays empty.
  - **What it does:** Idempotent append to `~/.zprofile`. Skips when the export
    is already present. Does not run `cursor-agent login` — authenticate
    separately after enabling file storage.
  - **Alternatives:** `CURSOR_API_KEY` (dashboard User API key) also bypasses
    Keychain; see [Cursor CLI authentication](https://cursor.com/docs/cli/reference/authentication).
  - Usage:
    - `scripts/configure-cursor-cli-file-credentials.swift`
  - After running:
    - `source ~/.zprofile` or open a new terminal
    - `cursor-agent login` (if not already authenticated with file storage)
    - `cursor-agent models` (should list models)
    - Restart Codemixer or refresh models from Workspace settings

### Live Spikes (Manual Validation)

Prefer the **SPM live harness** for automated opt-in checks when a logged-in
agent binary is available:

```bash
# Claude — interactive PTY billing path
CODEMIXER_LIVE_CLAUDE=1 swift test --no-parallel --filter LiveClaudeIntegrationTests

# Codex — App Server stdio JSON-RPC path
CODEMIXER_LIVE_CODEX=1 swift test --no-parallel --filter LiveCodexIntegrationTests
```

See [`tests/AgenticCLIs/README.md`](../tests/AgenticCLIs/README.md). The spikes
below remain useful for raw hook/billing characterization outside the test runner.

- `spike-billing.swift`
  - Live Claude token/cost capture spike using the same interactive PTY path
    as Codemixer (no `-p` / `--print`).
  - Sends one prompt, waits for Claude's Stop hook, then reads usage from the
    interactive transcript JSONL.
  - Usage:
    - `scripts/spike-billing.swift [workspace-path] [--prompt TEXT] [--timeout-secs N]`

- `spike-events.swift`
  - Captures Claude hook events over a Unix socket and prints coverage summary.
  - Leaves Claude in its normal interactive mode; run Claude yourself in the
    workspace while the spike listens for hook payloads.
  - Supports parser self-tests for mixed payload shapes.
  - Usage:
    - `scripts/spike-events.swift [workspace-path] [--duration-secs N]`
    - `scripts/spike-events.swift --self-test`
  - Dependencies:
    - `socat`
    - `jq`
    - `claude`

- Hook JSON helpers (`SpikeHookSupport`) are duplicated in both spike scripts
  because Swift's single-file script runner cannot import a sibling source file.

- `characterize-claude-code.swift`
  - Manual fixture capture scaffold for Claude Code hook/transcript characterization.
  - Writes a provenance manifest; not run in CI.
  - Usage:
    - `scripts/characterize-claude-code.swift --workspace /path/to/project [--scenario text]`

## Config / Templates

- `test-runtime-overrides.json`
  - Per-suite runtime budget overrides for `check-test-runtime.swift`.
  - The `EngineViewModel` suites pay a fixed ~40 ms `drain()` per test to let the
    view model's reduction task run, so their budgets grow with test count.
    Shortening `drain()` wedges the multi-hop navigator tests — raise the budget
    there instead of trimming the wait.

- `com.codecave.Codemixer.daemon.plist`
  - Canonical LaunchAgent template at `src/CodemixerApp/Resources/com.codecave.Codemixer.daemon.plist`.
  - The GUI installer substitutes `__CODEMIXERD_PATH__` at install time.

## Quick Examples

```bash
# Full tests + runtime budget check
swift test --no-parallel 2>&1 | scripts/check-test-runtime.swift
```

```bash
# Hook parser sanity checks
scripts/spike-events.swift --self-test
```

```bash
# Live hook capture for 2 minutes
scripts/spike-events.swift . --duration-secs 120
```

```bash
# Cursor CLI Keychain auth failures → file-based credential store in ~/.zprofile
scripts/configure-cursor-cli-file-credentials.swift
source ~/.zprofile
cursor-agent models
```
