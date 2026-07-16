<!--
CONTRIBUTING template.

Copy to a new project's repo root as `CONTRIBUTING.md`. Replace `{ … }` placeholders.
-->

# Contributing to {Project Name}

Thanks for your interest in contributing. This document is short and unambiguous: it tells you what good looks like in this codebase.

---

## Before you start

- **Open an issue first.** For anything beyond a typo fix or a one-line bug, open an issue describing the problem and your proposed approach before writing code. We'd rather discuss an approach than rewrite a PR.
- **Read the docs.** Skim [`docs/code-style.md`](docs/code-style.md), [`docs/visual-style.md`](docs/visual-style.md), and [`docs/architecture.md`](docs/architecture.md) before your first PR. They tell you what we mean by "fits."
- **Match the bar.** Existing code is the reference. If your change drifts in style, naming, or layering, reviewers will ask you to align.

---

## Development setup

```bash
git clone https://github.com/{org}/{repo}.git
cd {repo}

# Install hooks
make install-hooks

# Verify the toolchain
make doctor
```

`make doctor` checks Xcode version, SwiftFormat, SwiftLint, and any other required tooling.

---

## Workflow

1. **Branch from `main`** with a descriptive name: `fix/diff-panel-empty-state`, `feature/voice-commands-extended`.
2. **Make focused commits.** Each commit should compile and pass tests. Squash trivial fixups before review.
3. **Write tests.** New code without tests is rejected unless it's pure UI plumbing that the visual review covers.
4. **Run `make ci-local`** before pushing — this runs the same checks as CI.
5. **Open a PR** using the [PR template](docs/reference/templates/pr.template.md).
6. **Respond to review.** Threading: leave threads open until the reviewer (not you) resolves them.

---

## Commit messages

Conventional Commits, with a project flavour:

```
<type>(<scope>): <imperative summary>

<body — what changed and why, not how>

<footer — `Closes #123`, breaking-change notes>
```

| `type` | When |
| --- | --- |
| `feat` | New user-visible capability. |
| `fix` | Bug fix. |
| `refactor` | Internal reorganisation; no behaviour change. |
| `perf` | Performance improvement. |
| `test` | Test-only changes. |
| `docs` | Documentation only. |
| `chore` | Tooling, deps, CI; never user-facing. |

**Examples:**

```
feat(engine): emit assistantThinking events from hook stream

Surfaces structured thinking events so the UI can render shimmer / spinner
states without scraping the PTY text. Wires through the same multicast bus
as other events.

Closes #142
```

```
fix(ipc): clean up stale unix socket on startup

EADDRINUSE was being raised because the prior process's socket file
survived crash exits. We unlink, retry once, then fail loudly.

Fixes #189
```

---

## Code style — the short version

Full guide in [`docs/code-style.md`](docs/code-style.md). Key rules:

- **Strict concurrency on.** Compile with `-strict-concurrency=complete`. `Sendable` annotations are not optional.
- **Naming.** Types and protocols are `UpperCamelCase`. Functions and properties are `lowerCamelCase`. Acronyms keep their case (`PTYHost`, `URLString`, not `PtyHost`, `UrlString`).
- **No `print(...)`.** Use the `Logger` for the module — see [`docs/reference/patterns/structured-logging-with-privacy.md`](docs/reference/patterns/structured-logging-with-privacy.md).
- **No `fatalError(...)`.** Use `Logger.fatal`. The only exception is the `default` of an exhaustive switch over a closed enum.
- **Typed errors per module.** See [`docs/reference/patterns/typed-errors-and-wire.md`](docs/reference/patterns/typed-errors-and-wire.md).
- **`MainActor` only for view state.** Engines, IO, and protocols are `actor` or `Sendable`.
- **Comments explain *why*, not *what*.** The code says what; comments say why.

`SwiftFormat` and `SwiftLint` enforce the mechanical parts. Run `make fmt lint` locally — CI will catch you otherwise.

---

## Tests

- **Swift Testing**, not XCTest.
- One test file per source file under test.
- Test names use natural language: `@Test("rejects writes after close")`, not `testRejectsWritesAfterClose`.
- Avoid mocks-of-mocks; use the [dependency-injection seams](docs/reference/patterns/dependency-injection-seams.md). A `FakeClock` or `InMemoryFileSystem` is better than a mock framework.
- Golden wire-frame fixtures: inline in `RemoteParityTests` sources (no `Fixtures/` directory).

`swift test` must pass on a clean checkout. Flaky tests are bugs; fix or quarantine within one cycle.

---

## Reviews

- **Reviewers expect the PR template's checklist to be complete** before they engage.
- **At least one approval** from a code owner (`CODEOWNERS`) before merge.
- **No unresolved threads** at merge time.
- **CI green.**

Reviewers — please follow the [pre-merge review checklist](docs/reference/templates/pr.template.md).

---

## Releasing

Tagging convention: `v<major>.<minor>.<patch>`. CHANGELOG is updated in the release PR. See [`docs/release.md`](docs/release.md) for the full process.

---

## Where to ask

- **Questions about an existing feature:** GitHub Discussions.
- **Architecture / design discussion:** open an Architecture Decision Record using [`docs/reference/templates/adr.template.md`](docs/reference/templates/adr.template.md).
- **Security:** see [`SECURITY.md`](SECURITY.md).

Thank you for the care.
