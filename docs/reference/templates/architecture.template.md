# Architecture — Template

> Copy this file into your project's `docs/architecture.md` and fill in the bracketed sections. The Codemixer instance at [docs/architecture.md](../../architecture.md) is the worked example.

---

# {PROJECT_NAME} Architecture

This document is the source of truth for *how {PROJECT_NAME} is put together*. [docs/code-style.md](code-style.md) governs how individual files read; [docs/visual-style.md](visual-style.md) governs how the product looks; this file governs how the system thinks.

When this file and `code-style.md` disagree on how code reads, `code-style.md` wins; when it and `visual-style.md` disagree on how something appears, `visual-style.md` wins.

---

## Contents

1. Why this document exists
2. Product surface in one paragraph
3. Foundational constraints
4. Deployment modes
5. Module map
6. Layering and the dependency arrow
7. Concurrency model
8. The event-sourced core
9. {Subsystem 1 — e.g. I/O pipeline}
10. {Subsystem 2 — e.g. Event source priority}
11. The plug-in / adapter protocol
12. The input alphabet
13. The orchestrator
14. The event bus
15. {Subsystem-specific sections}
16. Dependency injection seams
17. State machine and lifecycle
18. {Domain subsystems}
19. {Domain subsystems}
20. Persistence model
21. Remote control architecture (if applicable)
22. Headless daemon (if applicable)
23. Security model
24. Error model
25. Performance model
26. Testing topology
27. Tooling and enforcement
28. End-to-end data flows
29. Failure modes and recovery
30. Versioning and wire-protocol evolution
31. Extension recipes
32. Trade-offs and rejected alternatives
33. Glossary
34. When in doubt

---

## Platform applicability

> Tag your project's platforms.

---

## 1. Why this document exists

> Three to five reasons. The first should always be *"the architecture is unusual"* (if it isn't, you probably don't need this doc). The last should be *"the wrong abstraction is expensive."*

---

## 2. Product surface in one paragraph

> One paragraph. No more. Cover:
>
> - What the product is.
> - Its deployment shapes.
> - Its extensibility shape.
> - Its key constraint(s).
> - Its event/state shape (event-sourced? request/response? streaming?).

---

## 3. Foundational constraints

> Numbered subsections. Each names a constraint, what it forbids, what it forces.
>
> Common items:
>
> ### 3.1 {Constraint name — e.g. billing / licensing}
> ### 3.2 {Constraint name — e.g. no visible terminal}
> ### 3.3 Strict concurrency (Swift 6 / your language equivalent)
> ### 3.4 Headless-first / GUI-first / Server-first
> ### 3.5 Pluggability — adapter pattern
> ### 3.6 Remote-controllability (if applicable)
> ### 3.7 Sandbox / hardened runtime / signing

---

## 4. Deployment modes

> Diagram each mode. Codemixer has two (in-process / daemon-backed). Yours may have more.

---

## 5. Module map

> ASCII tree of source layout. Then a table:
>
> | Target | Platform | Imports | Concern |
> | --- | --- | --- | --- |
> | `{ModuleA}` | … | … | … |
> | `{ModuleB}` | … | … | … |

End with **Hard import rules (lint-enforced)** — the cross-target restrictions and how CI checks them.

---

## 6. Layering and the dependency arrow

> A picture every contributor should be able to draw from memory. Plus rules:
>
> - No module imports above it.
> - Cross-imports at the same layer are forbidden.
> - The boundary between domain and wire is explicit.

---

## 7. Concurrency model

> Reference [reference/patterns/strict-concurrency-layout.md](../patterns/strict-concurrency-layout.md).
>
> Cover:
>
> - The four isolation domains (actor / `@MainActor` / structured concurrency / `@unchecked Sendable`).
> - Where the `@MainActor` seam lives.
> - `Sendable` boundary rules.
> - The `@MainActor` discipline (lint-enforced).

---

## 8. The event-sourced core

> Reference [reference/patterns/event-sourced-typed-port-core.md](../patterns/event-sourced-typed-port-core.md).
>
> Cover:
>
> - The event grammar — categorical roles.
> - Event identity and replay.
> - Domain vs wire (cross-link [reference/patterns/wire-domain-boundary.md](../patterns/wire-domain-boundary.md)).

---

## 9–10. {Project-specific subsystems}

> One section per heavy subsystem. Include diagrams, key types, invariants.

---

## 11. The plug-in / adapter protocol

> Reference [reference/patterns/plugin-adapter-protocol.md](../patterns/plugin-adapter-protocol.md).

---

## 12. The input alphabet

> Show the command enum / RPC method list. Group commands by category.

---

## 13. The orchestrator

> Show the engine actor's lifecycle, internal state, and invariants. What it does NOT do is as important as what it does.

---

## 14. The event bus

> Properties: per-subscriber bounded queue, ring buffer, replay semantics.

---

## 15. {Project-specific subsystem with cross-cutting concern}

> e.g. activity indicators, permission flow, transaction log.

---

## 16. Dependency injection seams

> Reference [reference/patterns/dependency-injection-seams.md](../patterns/dependency-injection-seams.md).
>
> Cover: the four (Clock / Random / Env / FileSystem). Add any project-specific seams (Logger, Locale, Notifications).

---

## 17. State machine and lifecycle

> Show the state enum. Show the canonical lifecycle in ASCII.

---

## 18–19. {Project-specific subsystems}

---

## 20. Persistence model

> Where files live, atomic-write strategy, schema-version evolution.

---

## 21. Remote control architecture

> If your project has a network protocol, reference [reference/patterns/headless-remote-duality.md](../patterns/headless-remote-duality.md) and [reference/patterns/lan-pairing-and-auth.md](../patterns/lan-pairing-and-auth.md).

---

## 22. Headless daemon

> If your project has one, cover the install / uninstall path, idle-exit policy, CI guards.

---

## 23. Security model

> Sandbox, hardened runtime, TCC, Keychain, TLS, secrets-in-logs policy.

---

## 24. Error model

> Typed error enums per module. Wire-codable error types. `localizedDescription` policy.

---

## 25. Performance model

> Table of latency budgets, throughput targets, memory caps.

---

## 26. Testing topology

> Diagram of test targets. List of patterns (golden, property, deterministic-time, real-IO suite).

---

## 27. Tooling and enforcement

> SwiftFormat / SwiftLint / custom rules / pre-commit / CI / CODEOWNERS.

---

## 28. End-to-end data flows

> Three canonical walkthroughs. Read them in order to internalise the architecture.

---

## 29. Failure modes and recovery

> Table of failure / detection / recovery.

---

## 30. Versioning and wire-protocol evolution

> Reference [reference/patterns/wire-domain-boundary.md](../patterns/wire-domain-boundary.md).
>
> Cover: `v: Int` field, compatibility policy, migration policy, telemetry on mismatch.

---

## 31. Extension recipes

> Numbered subsections: "adding a new X."

---

## 32. Trade-offs and rejected alternatives

> Table of considered / rejected / why.

---

## 33. Glossary

> Project vocabulary.

---

## 34. When in doubt

> Decision-resolver paragraph.

---

*Last revised alongside [docs/code-style.md](code-style.md) and [docs/visual-style.md](visual-style.md). When this file and the plan/spec disagree on structural decisions, this file is updated; when this file and `code-style.md` disagree on how code reads, `code-style.md` wins; when this file and `visual-style.md` disagree on how the product appears, `visual-style.md` wins.*
