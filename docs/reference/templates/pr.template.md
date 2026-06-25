# Pull Request Template

> Drop this file at `.github/PULL_REQUEST_TEMPLATE.md` (GitHub auto-loads it as the default PR body) or `.gitlab/merge_request_templates/Default.md` (GitLab). Customize the bracketed sections for your project; everything below the front-matter is intentionally generic.

---

## Summary

<!--
One paragraph. What does this PR do and why?
- The first sentence should be readable in a release-notes summary.
- The second sentence should answer "why now?" (bug, regression, feature, refactor, dep upgrade).
- Cite the issue or ADR if applicable.
-->

## Type

<!-- Tick all that apply. -->

- [ ] Bug fix
- [ ] Feature
- [ ] Refactor (no behavior change)
- [ ] Performance
- [ ] Documentation
- [ ] Tooling / CI / build
- [ ] Security
- [ ] Wire-protocol change *(requires version bump — see ADR)*
- [ ] Architecture change *(requires ADR — see [reference/templates/adr.template.md](adr.template.md))*

## Scope

<!--
Which modules / files are touched? A bullet list is fine. Linker errors love specifics.
-->

- `path/to/module/file.swift`
- `path/to/another/file.swift`

## How to verify

<!--
Step-by-step reproduction or test instructions. A reviewer should be able to verify the change without asking.
-->

1. `swift test`
2. Open the GUI, do X, observe Y.
3. ...

## Screenshots / recordings (UI changes only)

<!-- Drop before/after images or a short Loom. UI-affecting PRs are stalled without these. -->

---

## Pre-merge review checklist

<!--
Tick every box. Reviewers will hold the PR until each is genuinely complete.
The exemplar references are project-specific — adapt the file names.
-->

### Correctness

- [ ] Tests cover the change. New behaviour has new tests; new edge case has a new test.
- [ ] Tests pass locally (`swift test`).
- [ ] No `print` / `dump` / `dbg` / `console.log` / `XXX` left behind.
- [ ] All `TODO`s in the diff name an owner and link to a tracking issue.
- [ ] Error paths are covered, not just happy paths.

### Code style

- [ ] Code reads like `{REFERENCE_EXEMPLAR_FILE}` (per `docs/code-style.md`).
- [ ] No force-unwraps (`!`) or force-tries (`try!`) outside generated / test setup.
- [ ] File ≤ 400 lines, function body ≤ 60 lines, parameter count ≤ 5.
- [ ] Public symbols carry doc comments describing contracts (pre/post-conditions, ownership, threading).
- [ ] Naming follows `docs/code-style.md` (types `UpperCamelCase`, methods verb-first, async pair conventions).
- [ ] Comments explain *why*, never *what*.

### Concurrency

- [ ] All cross-actor types are `Sendable`.
- [ ] No `@MainActor` outside the UI module.
- [ ] Any new `@unchecked Sendable` carries a documented invariants block.
- [ ] No new global mutable state.
- [ ] `Task { [weak self] in }` for any escaping closure that captures `self`.

### Error model

- [ ] New error cases are typed (no `Error` or `NSError` thrown by my own code).
- [ ] Errors that cross the network boundary are `Codable`.
- [ ] `localizedDescription` is actionable, not opaque.
- [ ] No new `fatalError` outside `Logger.fatal` shims.

### Observability

- [ ] New code uses `Logger`, not `print`.
- [ ] Log privacy levels are explicit (`.private` / `.public`).
- [ ] No secrets in logs.

### Dependency hygiene

- [ ] No new `import Foundation`-free types use platform types accidentally (check portable modules).
- [ ] No new module-cross imports forbidden by `docs/architecture.md` §5.
- [ ] No new third-party dependencies without ADR.

### Visual (UI PRs only)

- [ ] Visual changes match `docs/visual-style.md` (color, type, spacing, motion tokens — no magic numbers).
- [ ] Reduce-Motion / Increase-Contrast / Dynamic-Type behaviour verified.
- [ ] Dark mode parity verified.
- [ ] Every new interactive view has `.help(...)` and `accessibilityLabel`.

### Wire protocol (if touched)

- [ ] Wire DTOs in the portable module, not the engine module.
- [ ] `WireCodec` updated; round-trip parity test passes.
- [ ] Golden JSON files regenerated (and reviewed by an explicit reviewer).
- [ ] `v: Int` field bumped if breaking; ADR cites the bump.
- [ ] `unknown` catch-all updated in any wire enum.

### Architecture (if touched)

- [ ] ADR drafted ([reference/templates/adr.template.md](adr.template.md)).
- [ ] `docs/architecture.md` updated.
- [ ] Cross-references in `code-style.md` / `visual-style.md` updated if the change affects them.

### Tests

- [ ] All new tests are deterministic (no `Task.sleep` against real time).
- [ ] Long-running real-IO tests live in the integration suite, not the unit suite.
- [ ] No flaky tests introduced (run the new tests 10× before merge).

### Build & CI

- [ ] `swift build -Xswiftc -warnings-as-errors` clean.
- [ ] `swift test -Xswiftc -warnings-as-errors` clean.
- [ ] `swiftformat .` clean.
- [ ] `swiftlint` clean.
- [ ] No build-time increase > 5 % without an explanation.
- [ ] No binary-size increase > 1 % without an explanation.

### Security

- [ ] No secrets in code, fixtures, or commit messages.
- [ ] No PII or token values in logs.
- [ ] If touching auth / pairing / Keychain: verified against [reference/patterns/lan-pairing-and-auth.md](../patterns/lan-pairing-and-auth.md).

---

## Reviewer expectations

A reviewer can reasonably ask:

- *"Show me where this is tested."*
- *"Show me the ADR if this touches architecture."*
- *"Show me the golden file if this touches the wire."*
- *"Show me Reduce-Motion behaviour if this touches motion."*
- *"Why didn't you do X instead?"*

A PR is **not ready** until you can answer each in one sentence.

---

## After merge

- [ ] Release notes / changelog updated if user-visible.
- [ ] Tracking issue closed (or scope deferred to a follow-up issue with a clear name).
- [ ] If wire version bumped: roll-out plan attached to the ADR.

---

*This template lives at `docs/reference/templates/pr.template.md`. To propose changes, open a PR that modifies this file and the resulting changes will be picked up by the next contributor on this repo.*
