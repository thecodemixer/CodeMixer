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

- `pre-commit.swift`
  - Pre-commit gate: `swift build`, `swift test --no-parallel`, SwiftFormat lint, SwiftLint.
  - Typical install:
    - `ln -sf ../../scripts/pre-commit.swift .git/hooks/pre-commit`

- `check-test-runtime.swift`
  - Parses `swift test` output from `stdin` and fails if suite runtime budgets are exceeded.
  - Usage:
    - `swift test --no-parallel 2>&1 | scripts/check-test-runtime.swift`
  - Uses overrides from `test-runtime-overrides.json`.

### Architecture / Policy Checks

- `check-no-swiftui-imports.swift`
  - Ensures `import SwiftUI` appears only in allowed UI targets.

- `check-direct-framework-calls.swift`
  - Prevents direct calls to wrapped Apple APIs outside `External/` wrapper seams.
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

### Live Spikes (Manual Validation)

- `spike-billing.swift`
  - Live Claude token/cost capture spike using the same interactive PTY path
    as Codemixer.
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

- `characterize-claude-code.swift`
  - Manual fixture capture scaffold for Claude Code hook/transcript characterization.
  - Writes a provenance manifest; not run in CI.
  - Usage:
    - `scripts/characterize-claude-code.swift --workspace /path/to/project [--scenario text]`

## Config / Templates

- `test-runtime-overrides.json`
  - Per-suite runtime budget overrides for `check-test-runtime.swift`.

- `com.codecave.Codemixer.daemon.plist`
  - LaunchAgent template for running `codemixerd` at login.

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
