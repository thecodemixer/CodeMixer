# Reference implementation library

This folder is the *portable* portion of Codemixer's documentation — the patterns, templates, and decision frameworks that another Swift / SwiftUI / actor-concurrent project can adopt directly. Every file here is written to stand alone. Each pattern describes a problem, the shape of a solution, the trade-offs we considered, and code sketches you can paste into a new codebase with minimal edits.

If you only want to read one doc to "get" the project, read [docs/architecture.md](../architecture.md). The files in this folder are the *building blocks* of that architecture, written so you can reuse them without inheriting the rest of Codemixer.

---

## Where to start

| You want to… | Read |
| --- | --- |
| Find the right pattern for a concrete problem | [`SELECTION_MATRIX.md`](SELECTION_MATRIX.md) |
| Look up a term used across the library | [`GLOSSARY.md`](GLOSSARY.md) |
| See "what *not* to do" before reviewing a PR | [`ANTI_PATTERNS.md`](ANTI_PATTERNS.md) |
| Read every pattern end-to-end | The patterns table below, in order |
| Bootstrap a new project's docs | The templates table below |

---

## How to use this folder

- **You're starting a new project** and want to skip the "what shape should this take" research phase → start with [`SELECTION_MATRIX.md`](SELECTION_MATRIX.md), then read the patterns it points to, then copy the templates and fill them in.
- **You hit a specific design question** (how do I isolate actors in Swift 6? how do I pair a phone to a Mac app? how do I spawn a subprocess safely?) → look it up in [`SELECTION_MATRIX.md`](SELECTION_MATRIX.md).
- **You're reviewing a PR** and need to point a contributor at the reasoning → link the relevant pattern. Skim [`ANTI_PATTERNS.md`](ANTI_PATTERNS.md) first.
- **You're authoring a style guide / architecture doc / ADR for a new project** → start from the template, not from blank.

Each file states its scope at the top. None of them assume you have read the others, though several cross-link where the patterns naturally compose.

---

## Patterns (15)

Architectural building blocks, ordered roughly from foundational to peripheral.

### Concurrency, state, orchestration

| # | File | One-line summary |
| --- | --- | --- |
| 1 | [`patterns/strict-concurrency-layout.md`](patterns/strict-concurrency-layout.md) | How to map a codebase onto Swift 6 strict-concurrency isolation domains: `actor` for state, `@MainActor` at the UI seam only, `@unchecked Sendable` quarantined. |
| 2 | [`patterns/event-sourced-typed-port-core.md`](patterns/event-sourced-typed-port-core.md) | An actor engine with one typed command port in, one typed event stream out, fanned to N consumers with ring-buffer replay. The load-bearing pattern; most others compose around it. |
| 3 | [`patterns/multicast-tee-primitive.md`](patterns/multicast-tee-primitive.md) | Reference pattern for one stream → N independent subscriber streams. Codemixer currently uses `MulticastEventBus` for replay-aware event fan-out and inline fan-out for PTY bytes. |
| 4 | [`patterns/coherent-activity-heartbeat.md`](patterns/coherent-activity-heartbeat.md) | A server-side state machine that emits structured "still working" events with locked thresholds, so every connected client agrees on activity timing to the millisecond. |

### Errors and observability

| # | File | One-line summary |
| --- | --- | --- |
| 5 | [`patterns/typed-errors-and-wire.md`](patterns/typed-errors-and-wire.md) | One typed `Error` enum per module, `Codable` mirror types at the network boundary, single `WireError` envelope, `Logger.fatal` as the only escape hatch. |
| 6 | [`patterns/structured-logging-with-privacy.md`](patterns/structured-logging-with-privacy.md) | `os.Logger` per module, explicit `privacy:` levels, structured `key=value` fields, signposts, no `print()`, lint-enforced. |

### IO, storage, processes

| # | File | One-line summary |
| --- | --- | --- |
| 7 | [`patterns/posix-child-lifecycle.md`](patterns/posix-child-lifecycle.md) | `posix_spawn` (never `fork` from Swift), C bridge, controlling TTY for PTYs, `DispatchIO` reads, global `SIGCHLD` reaper, `SIGTERM → grace → SIGKILL` shutdown. |
| 8 | [`patterns/filesystem-watch-with-debounce.md`](patterns/filesystem-watch-with-debounce.md) | `FSEventStreamCreate` / `inotify_init1` wrapped in an actor with a 50 ms debounce window, cached `.gitignore` filter, batched dedup'd callbacks. |
| 9 | [`patterns/ipc-server-listener.md`](patterns/ipc-server-listener.md) | `NWListener` over Unix sockets, NDJSON framing, per-client actor lifecycle, stale-socket recovery, graceful shutdown with timeout. |
| 10 | [`patterns/atomic-file-persistence.md`](patterns/atomic-file-persistence.md) | Temp + `rename(2)` writes, embedded `schemaVersion`, forward-only migrations, `~/Library/Application Support/` convention, encoder discipline. |

### Architecture and adapters

| # | File | One-line summary |
| --- | --- | --- |
| 11 | [`patterns/plugin-adapter-protocol.md`](patterns/plugin-adapter-protocol.md) | A `Sendable` protocol that quarantines per-vendor knowledge into self-contained adapter modules — the core stays agnostic forever. |
| 12 | [`patterns/dependency-injection-seams.md`](patterns/dependency-injection-seams.md) | `Clock`, `RandomSource`, `Environment`, `FileSystem` as injected protocols, enforced by lint, mirrored by deterministic test fakes. |
| 13 | [`patterns/wire-domain-boundary.md`](patterns/wire-domain-boundary.md) | A pure-Foundation wire-protocol target with `Codable` DTOs, separated from richer domain types, with a single converter and a parity test. |

### Network and security

| # | File | One-line summary |
| --- | --- | --- |
| 14 | [`patterns/headless-remote-duality.md`](patterns/headless-remote-duality.md) | The same engine binary running in-process and as a headless daemon; the GUI becomes "just another client" so multi-client coherence falls out for free. |
| 15 | [`patterns/lan-pairing-and-auth.md`](patterns/lan-pairing-and-auth.md) | First-time PIN pairing + bearer tokens + Keychain-pinned TLS + lockout for trusted local-network remote control. |

---

## Templates (14)

Skeletons you can copy into a new project and fill in. The Codemixer guides ([`../code-style.md`](../code-style.md), [`../visual-style.md`](../visual-style.md), [`../architecture.md`](../architecture.md)) are concrete instances of the first three templates — open them side-by-side as worked examples.

### Documentation skeletons

| File | Use for |
| --- | --- |
| [`templates/code-style.template.md`](templates/code-style.template.md) | The engineering aesthetic — naming, idioms, concurrency, error model, testing, tooling. |
| [`templates/visual-style.template.md`](templates/visual-style.template.md) | The product's visual language — color, type, spacing, motion, components, accessibility. |
| [`templates/architecture.template.md`](templates/architecture.template.md) | The structural document — modules, layering, boundaries, data flow, security, performance. |
| [`templates/adr.template.md`](templates/adr.template.md) | One ADR (Architecture Decision Record) per material decision. Numbered, dated, immutable once accepted. |
| [`templates/pr.template.md`](templates/pr.template.md) | The pull-request body, including a pre-merge review checklist. Drop into `.github/PULL_REQUEST_TEMPLATE.md`. |

### Project meta files

| File | Drop into |
| --- | --- |
| [`templates/README.template.md`](templates/README.template.md) | Repo root → `README.md`. |
| [`templates/CONTRIBUTING.template.md`](templates/CONTRIBUTING.template.md) | Repo root → `CONTRIBUTING.md`. |
| [`templates/SECURITY.template.md`](templates/SECURITY.template.md) | Repo root → `SECURITY.md`. |
| [`templates/CHANGELOG.template.md`](templates/CHANGELOG.template.md) | Repo root → `CHANGELOG.md` (Keep a Changelog 1.1.0 format). |
| [`templates/CODEOWNERS.template.md`](templates/CODEOWNERS.template.md) | `.github/CODEOWNERS` (review assignment by path). |

### Tooling configurations

| File | Drop into |
| --- | --- |
| [`templates/ci-workflow.template.md`](templates/ci-workflow.template.md) | `.github/workflows/ci.yml` (format, lint, test, docs, release). |
| [`templates/swiftformat.template.md`](templates/swiftformat.template.md) | `.swiftformat` at repo root. |
| [`templates/swiftlint.template.md`](templates/swiftlint.template.md) | `.swiftlint.yml` at repo root, with custom rules that enforce many patterns in this library. |
| [`templates/pre-commit.template.md`](templates/pre-commit.template.md) | `scripts/hooks/pre-commit` + a `make install-hooks` target. |

---

## Meta documents

| File | Purpose |
| --- | --- |
| [`SELECTION_MATRIX.md`](SELECTION_MATRIX.md) | Problem → pattern lookup. Canonical stacks. What's intentionally out of scope. |
| [`GLOSSARY.md`](GLOSSARY.md) | Every term used across the library. Codemixer-specific entries tagged. |
| [`ANTI_PATTERNS.md`](ANTI_PATTERNS.md) | "Do not do this," indexed for grep, grouped by domain, with fix-links. |

---

## Reading order if you're starting fresh

1. **Foundations (every project):**
   1. [`strict-concurrency-layout`](patterns/strict-concurrency-layout.md) — sets the `actor` / `@MainActor` map you'll think in.
   2. [`typed-errors-and-wire`](patterns/typed-errors-and-wire.md) — one enum per module from minute one.
   3. [`structured-logging-with-privacy`](patterns/structured-logging-with-privacy.md) — `Loggers.swift` from minute one.
   4. [`dependency-injection-seams`](patterns/dependency-injection-seams.md) — makes the rest testable.
2. **State and event flow:**
   5. [`event-sourced-typed-port-core`](patterns/event-sourced-typed-port-core.md) — the heart.
   6. [`multicast-tee-primitive`](patterns/multicast-tee-primitive.md) — optional reference for smaller non-replay fan-out.
   7. [`coherent-activity-heartbeat`](patterns/coherent-activity-heartbeat.md) — once any operation can take long enough to need feedback.
3. **IO and processes (Apple-platform apps with subprocesses):**
   8. [`posix-child-lifecycle`](patterns/posix-child-lifecycle.md)
   9. [`filesystem-watch-with-debounce`](patterns/filesystem-watch-with-debounce.md)
   10. [`ipc-server-listener`](patterns/ipc-server-listener.md)
   11. [`atomic-file-persistence`](patterns/atomic-file-persistence.md)
4. **Architecture for multi-vendor / multi-client:**
   12. [`plugin-adapter-protocol`](patterns/plugin-adapter-protocol.md) — once you have more than one integration.
   13. [`wire-domain-boundary`](patterns/wire-domain-boundary.md) — before you write the first wire type.
5. **Remote control / mobile companion:**
   14. [`headless-remote-duality`](patterns/headless-remote-duality.md)
   15. [`lan-pairing-and-auth`](patterns/lan-pairing-and-auth.md)

Then read the templates as you draft your own docs.

[`SELECTION_MATRIX.md`](SELECTION_MATRIX.md) collapses the above into "given my project shape, here's the kit."

---

## License posture

Treat the patterns and templates as if released under MIT — adapt freely. The Codemixer-specific names (`AgentEngine`, `AgentEvent`, `ClaudeAdapter`, etc.) are stand-ins. Rename to your domain's vocabulary on copy.

---

*Last revised alongside [docs/architecture.md](../architecture.md). When a pattern in this folder disagrees with the Codemixer-specific architecture doc, the architecture doc wins on Codemixer's behaviour; the pattern doc wins as portable advice.*
