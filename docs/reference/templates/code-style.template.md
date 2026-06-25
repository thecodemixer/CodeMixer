# Code Style Guide — Template

> Copy this file into your project's `docs/style/code-style.md` (or `docs/code-style.md`) and fill the bracketed sections in. The Codemixer instance at [docs/style/code-style.md](../../style/code-style.md) is the worked example (~ 1,700 lines) — open it side-by-side as you adapt this template.

---

# {PROJECT_NAME} Style Guide

This is the engineering aesthetic for {PROJECT_NAME}. It describes how we *write* code, not just what code we write. It exists because lint rules catch only the cheapest mistakes; the difference between a codebase that ages well and one that decays is taste, and taste needs to be written down.

Read this once, fully, before opening your editor. Re-read the *Pre-merge review checklist* every time you raise a pull request. The reference exemplar `{EXEMPLAR_FILE}` is this document made concrete — when you cannot articulate why something feels wrong, open `{EXEMPLAR_FILE}` side-by-side; the contrast usually makes the answer obvious.

---

## Platform applicability

> Replace this section with the platforms your project ships on. Codemixer's tagging convention:
>
> - `[macOS]` — applies only on macOS.
> - `[iOS / iPadOS / visionOS]` — applies on the noted mobile platforms.
> - `[Apple cross-platform]` — applies anywhere the framework ships.

---

## Contents

1. The soul — N principles
2. The reference exemplar — `{EXEMPLAR_FILE}`
3. Hard rules (lint-enforceable)
4. Naming conventions
5. Swift idiom
6. View aesthetic (SwiftUI / your UI framework)
7. Test aesthetic
8. Documentation & DocC
9. Access control
10. Protocol design
11. Codable & wire formats
12. Extensions & default arguments
13. Memory & ownership
14. Performance discipline
15. Security & secrets
16. Observability — logging, metrics, tracing
17. Configuration & feature flags
18. Localization
19. Refactoring etiquette
20. Git & pull-request aesthetics
21. Tooling & enforcement
22. Pre-merge review checklist
23. Philosophy — why this exists
24. Swift language feature adoption policy
25. Meta — how this document evolves
26. Glossary

---

## 1. The soul — N principles

> Write between 12 and 18 principles. Each gets a rationale and a one-line example. These are reviewed by eye; lint can't catch them.

### 1.1 {PRINCIPLE}

> Example principles to adapt:
>
> - Boring is a feature.
> - Strict concurrency is a feature, not a tax.
> - Errors are first-class objects.
> - The compiler is a reviewer; let it work.
> - Tests are documentation; write them like prose.
> - Comments explain *why*, never *what*.
> - Tools are quiet by default.
> - The reference exemplar is the source of truth for taste.

---

## 2. The reference exemplar — `{EXEMPLAR_FILE}`

> Pick one file in your codebase that embodies the whole style guide. Annotate it as `/// Reference style exemplar — see /docs/code-style.md.`. Every new contributor reads it before opening any other file. Update this section when you replace the exemplar.

---

## 3. Hard rules (lint-enforceable)

> List the rules CI enforces. Each rule gets a one-line rationale.
>
> Example seed list:
>
> - No force-unwrap (`!`) outside generated code.
> - No force-try (`try!`) outside test setup.
> - File length ≤ 400 lines.
> - Function body ≤ 60 lines.
> - Function parameter count ≤ 5.
> - No `print(...)` — use `Logger`.
> - No bare `// TODO` — every TODO names an owner and a ticket.
> - Direct `Date()` / `Int.random` / `ProcessInfo.processInfo.environment` / `FileManager.default` forbidden outside `Seams/Live*.swift`.
> - `@MainActor` forbidden outside the UI module.
> - All `@unchecked Sendable` annotations require a documented invariants block.

---

## 4. Naming conventions

> Cover at least: types, methods, parameters, generic parameters, async methods, throwing methods, files, modules.
>
> Codemixer's bullets:
>
> - Types: `UpperCamelCase`. Nouns. Avoid abbreviations (`Configuration`, not `Cfg`).
> - Methods: `lowerCamelCase`. Verbs for actions, nouns for accessors.
> - Async methods: pair with non-async overloads only when both make sense.
> - Throwing methods: name the failure mode if it's narrow (`tryParse` is fine; `tryEverything` is not).
> - Files: one main type per file; filename matches the type. Helpers in same file unless > 100 lines.
> - Modules: short, plural-noun-free, lowercase no underscores in SPM (`AgentCore`, not `Agent_Cores`).

---

## 5. Swift idiom

> Cover at least: let-vs-var preference, optional handling, error handling, generics, protocols-with-associated-types, computed properties, property wrappers, key paths.

---

## 6. View aesthetic (SwiftUI / your UI framework)

> Cover at least: view body length, view-model boundary, `@MainActor` placement, animation discipline, accessibility props requirements.

---

## 7. Test aesthetic

> Cover at least: test naming, test scope, fixture management, golden files, property tests, performance tests, what to mock and what not to.

---

## 8. Documentation & DocC

> Cover at least: doc-comment requirements (public symbols only? all symbols?), DocC catalogs, example code in docs, links between docs.

---

## 9. Access control

> Cover at least: `public` vs `internal` vs `fileprivate` vs `private`. The default is `internal`; `public` requires justification in the doc comment.

---

## 10. Protocol design

> Cover at least: when to reach for protocols vs concrete types, associated types, default implementations, `Sendable` requirements, witness tables.

---

## 11. Codable & wire formats

> Cover at least: when to use `Codable` synthesis vs hand-rolled, explicit `CodingKeys`, optional fields, version evolution, golden JSON files. See [reference/patterns/wire-domain-boundary.md](../patterns/wire-domain-boundary.md) for the pattern.

---

## 12. Extensions & default arguments

> Cover at least: when extensions are appropriate, when they aren't, retro-fitting protocols, default arguments vs overloads.

---

## 13. Memory & ownership

> Cover at least: `weak` vs `unowned`, capture lists in closures, `Task { [weak self] in }`, retain cycles in actor delegates.

---

## 14. Performance discipline

> Cover at least: when to measure, what to measure with (Instruments, signposts, ContinuousClock), latency budgets, throughput tests.

---

## 15. Security & secrets

> Cover at least: secrets never in code, Keychain layout, log privacy (`.private` vs `.public`), TLS, fingerprint pinning if applicable.

---

## 16. Observability — logging, metrics, tracing

> Cover at least: `Logger` categories, privacy levels, structured log fields, when to use `signpost`, when to expose health checks.

---

## 17. Configuration & feature flags

> Cover at least: where configuration lives (file? UserDefaults? Keychain?), how it's seeded, default values, runtime mutability rules, flag lifecycle (debug-only → public → permanent → removed).

---

## 18. Localization

> Cover at least: when to localize, when to defer, `String(localized:)`, plural rules, locale-aware formatting.

---

## 19. Refactoring etiquette

> Cover at least: when a refactor PR is appropriate, when it isn't, how to scope, how to test.

---

## 20. Git & pull-request aesthetics

> Cover at least: branch naming, commit message format, PR title format, PR body structure, squash vs merge policy.

---

## 21. Tooling & enforcement

> Cover at least: SwiftFormat config, SwiftLint config, pre-commit hook, CI checks, format-on-save expectation.

---

## 22. Pre-merge review checklist

> Reuse the [reference/templates/pr.template.md](pr.template.md) checklist here, inlined.

---

## 23. Philosophy — why this exists

> A short essay (≤ 500 words) on why a written style guide is worth the maintenance cost. Personalize to your project.

---

## 24. Swift language feature adoption policy

> Cover at least: when new Swift features become acceptable, when they become required, who decides, how the codebase migrates.

---

## 25. Meta — how this document evolves

> Cover at least: how rules are added, how rules are removed, how disputes are resolved, who owns this file, who reviews changes.

---

## 26. Glossary

> List terms that are specific to your project. Cross-link to docs that define them.

---

*Last revised alongside [docs/architecture.md](../architecture.md). To propose changes to this style guide, open a PR that modifies this file and provides a code citation showing the rule in action.*
