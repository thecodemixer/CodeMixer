<!--
README template.

Copy to a new project's repo root as `README.md`. Replace every `{ … }` placeholder.
Keep the section list — reviewers and contributors expect this shape.
-->

# {Project Name}

> {One sentence: what does this project do, for whom?}

{2–3 sentence elaboration. Lead with the user-visible value. Mention the platform(s). Mention what makes this implementation interesting (e.g. "native macOS, no Electron"; "headless-first with optional GUI"; "zero-config local LAN").}

[![Build](https://img.shields.io/github/actions/workflow/status/{org}/{repo}/ci.yml?branch=main)](https://github.com/{org}/{repo}/actions)
[![License](https://img.shields.io/badge/license-{License}-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-{macOS%2014%2B}-lightgrey.svg)]()

---

## Table of contents

- [Features](#features)
- [Quick start](#quick-start)
- [Building from source](#building-from-source)
- [Architecture at a glance](#architecture-at-a-glance)
- [Usage](#usage)
- [Configuration](#configuration)
- [Headless / API mode](#headless--api-mode)
- [Development](#development)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)

---

## Features

- {Feature 1 — user-facing, one line.}
- {Feature 2 — user-facing, one line.}
- {Feature 3 — technical differentiator if relevant.}
- {Feature 4 — technical differentiator if relevant.}
- {…}

---

## Quick start

For users who just want it running, in 30 seconds:

```bash
# Install (one of):
brew install {tap}/{repo}                  # Homebrew (when published)
# or download the latest release:
curl -fsSL https://github.com/{org}/{repo}/releases/latest/download/{Project}.dmg -o {Project}.dmg
open {Project}.dmg

# Launch
open -a {Project}
```

First-run requirements:

- {Permission 1 (e.g., microphone access, full disk access)} — granted on first prompt.
- {Dependency 1 (e.g., `claude` CLI installed via `npm i -g @anthropic-ai/claude-code`)} — checked at startup; first-run installer offers to fix.

---

## Building from source

**Requirements:**

- macOS {14}+ (or Linux {Ubuntu 22.04}+)
- Xcode {16}+ (Swift {6.2}+)
- {Other dependencies — Node, Python, etc.}

```bash
git clone https://github.com/{org}/{repo}.git
cd {repo}

# Build the SPM package and run tests
swift test

# Open the app in Xcode (for the GUI variant)
open {Project}.xcodeproj
```

The first build resolves SPM dependencies (~30 s).

---

## Architecture at a glance

{One paragraph: the major moving parts and how they fit together. Examples:}

> The codebase is organized as a Swift Package (`{Project}Kit`) with library targets for the engine, network protocol, adapters, and UI. An Xcode app target (`{Project}.xcodeproj`) provides the macOS shell. The engine is an actor that owns a subprocess and emits a typed `AsyncStream` of events; the UI is a `@MainActor` consumer that folds events into observable view state; a separate daemon target (`{project}d`) exposes the same engine over a WSS API for remote control.

See [`docs/architecture.md`](docs/architecture.md) for the full breakdown.

---

## Usage

{Walkthrough of the most common user task with screenshots / GIFs if appropriate.}

### {Task 1 — e.g. "Open a project and run a prompt"}

1. Step one.
2. Step two.
3. Step three.

### {Task 2 — e.g. "Approve a tool call"}

…

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘N | New session |
| ⌘W | Close window |
| ⌘K | Slash command palette |
| ⌘. | Stop current operation |
| {…} | {…} |

---

## Configuration

{Project} reads configuration from:

- `~/Library/Application Support/{bundleID}/prefs.json` (auto-generated on first run; human-editable).
- Environment variables, prefixed `{PROJECT}_`. See [`docs/configuration.md`](docs/configuration.md).
- The Settings window (⌘,).

| Key | Default | Description |
| --- | --- | --- |
| `theme` | `auto` | `light`, `dark`, or `auto`. |
| `voiceEnabled` | `false` | Enable microphone-driven input. |
| `headlessPort` | `0` (disabled) | WSS port for remote control. `0` disables the daemon. |
| {…} | | |

---

## Headless / API mode

{Project} can run without the GUI, exposing the same operations over a WSS API. Useful for mobile remote control, automation, or CI.

```bash
# Start the daemon (listens on TLS WSS, port from prefs)
{project}d --pair                 # one-time: prints a pairing code
{project}d                        # ongoing: serves paired clients
```

API spec: [`docs/api.md`](docs/api.md). Pairing flow: [`docs/pairing.md`](docs/pairing.md).

---

## Development

```bash
# Format and lint (also runs on pre-commit)
make fmt lint

# Run the test suite
swift test

# Run a single test target
swift test --filter {ModuleTests}

# Generate documentation
make docs
```

We use `SwiftFormat` and `SwiftLint`; pre-commit hooks run both. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

---

## Documentation

- [`docs/code-style.md`](docs/code-style.md) — engineering conventions.
- [`docs/visual-style.md`](docs/visual-style.md) — UI / UX conventions.
- [`docs/architecture.md`](docs/architecture.md) — structural and concurrency design.
- [`docs/api.md`](docs/api.md) — wire protocol.
- [`docs/reference/`](docs/reference/) — reusable patterns and templates.

Code-level docs are generated by DocC: `make docs` produces `.build/documentation/`.

---

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Briefly:

1. Open an issue describing what you want to change.
2. Fork, branch, change.
3. Run `make fmt lint test` before pushing.
4. Open a PR using the template; reviewers expect the [pre-merge checklist](docs/reference/templates/pr.template.md) to be done.

---

## Security

See [`SECURITY.md`](SECURITY.md). To report a vulnerability privately: {security@example.com} (PGP key in the file).

---

## License

{MIT} — see [`LICENSE`](LICENSE).

---

## Acknowledgements

- {SwiftTerm} — headless terminal emulation.
- {Other open-source dependencies worth crediting.}
