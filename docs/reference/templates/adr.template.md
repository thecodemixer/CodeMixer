# ADR Template — Architecture Decision Records

> Drop this file into `docs/adr/0000-template.md`. Copy it for every architectural decision: `0001-some-decision.md`, `0002-other-decision.md`, etc. Numbers are sequential and immutable. Each ADR captures a single decision; once accepted, the ADR is **immutable** — supersede with a new ADR rather than edit an old one.

---

# ADR-{NNNN}: {Decision title in present tense, ≤ 60 chars}

| | |
| --- | --- |
| **Status** | Proposed \| Accepted \| Superseded by ADR-{MMMM} \| Deprecated |
| **Date** | YYYY-MM-DD |
| **Deciders** | {names or roles} |
| **Tags** | `{architecture}` `{security}` `{concurrency}` etc. |
| **Supersedes** | ADR-{NNNN} (or "none") |

---

## Context

> What's the situation that forced this decision? Be specific. Include:
>
> - The problem in one paragraph.
> - The relevant constraints (technical, business, regulatory).
> - The forces pulling in different directions.
> - Why the decision can't be deferred indefinitely.

---

## Considered options

> List every option that was on the table. Two to five is usual. For each:
>
> ### Option A — {short name}
>
> One-paragraph description. Pros (≤ 4 bullets). Cons (≤ 4 bullets).
>
> ### Option B — {short name}
>
> ...
>
> ### Option C — Do nothing
>
> Always include this option, even if absurd. The "do nothing" baseline forces honesty about why action is needed.

---

## Decision

> A single, clear declaration in present tense. *"We will…"* or *"We do…"*.
>
> Do not hedge. If the team isn't actually ready to commit, the ADR is still in *Proposed*; promote to *Accepted* only when the call is firm.

---

## Rationale

> Why this option, in 3–6 paragraphs. Address the strongest counter-argument explicitly — *"We considered X because Y, but rejected it because Z."*
>
> Cite measurements, benchmarks, prior art, or external constraints by name. Avoid hand-waving phrases ("seems cleaner," "feels right") — taste reasoning belongs in the style guide, not an architectural decision.

---

## Consequences

> List the effects of this decision, both positive and negative. Be concrete:
>
> ### Positive
>
> - {What gets easier, faster, safer, smaller, cheaper.}
>
> ### Negative
>
> - {What gets harder, slower, riskier, larger, more expensive.}
>
> ### Neutral
>
> - {Changes in workflow, vocabulary, dependencies.}
>
> Include knock-on effects on:
>
> - Build / CI time.
> - Test surface.
> - Onboarding for new contributors.
> - Existing documentation.
> - Operational practices (monitoring, alerting, on-call).
> - Cost (CPU, memory, network, $).

---

## Implementation notes

> Optional. If the decision is non-trivial to land, sketch the migration:
>
> 1. {First step.}
> 2. {Second step.}
> 3. {Cleanup / decommission.}
>
> Link to the tracking issue or PR series.

---

## Compliance / enforcement

> How will this decision be enforced going forward?
>
> - Lint rule? (cite the rule)
> - CI check? (cite the script)
> - PR template question?
> - Reviewer checklist item?
> - Documentation cross-reference?
>
> An ADR with no enforcement is a wishlist.

---

## Validation

> How will we know this decision was correct, six months from now?
>
> - {Metric or qualitative signal to watch.}
> - {Anti-signal — what would falsify the decision.}
> - {Date or trigger for revisit.}

---

## Links

> - Related ADRs: {ADR-XXXX}
> - Spec / plan section: {link or anchor}
> - External references: {RFC, paper, blog post, prior art}
> - Tracking issue: {link}

---

# How to use this template

## When to write an ADR

Write an ADR whenever **any of these** is true:

1. The decision is hard to reverse without rewriting code.
2. The decision affects the public API or wire protocol.
3. The decision constrains a future team member's choices.
4. The decision was contested in review and we want to remember why we chose what we did.
5. The decision involves trade-offs the team will forget within a quarter.

Do **not** write an ADR for:

- Style choices (those go in `code-style.md`).
- Pixel choices (those go in `visual-style.md`).
- Implementation details that won't outlive a sprint.
- Decisions that someone has unilateral authority to change.

## Numbering

ADRs are numbered sequentially starting at `0001`. Numbers are never reused, never reassigned, never deleted. If an ADR is wrong, supersede it with a new one and mark the old one *Superseded by ADR-NNNN*.

## Status lifecycle

- **Proposed** — written, under review, not yet binding.
- **Accepted** — agreed; binding. Code must conform.
- **Superseded** — replaced by a later ADR. Read for historical context only.
- **Deprecated** — no longer relevant (the system changed, the option became moot) but no replacement.

Once an ADR is *Accepted*, the body of the ADR is **never edited.** Errata, clarifications, follow-up consequences — all go in a new ADR that supersedes the old.

## Tone

ADRs are written for the person sitting in your seat 18 months from now. Optimise for:

- **Specificity**: name the actual classes, modules, commits.
- **Honesty**: list the costs as honestly as the benefits.
- **Brevity**: 2 pages is plenty. 8 pages means you've embedded a tutorial that should live elsewhere.
- **Reproducibility**: a reader should be able to summarise the decision in one sentence after reading.

## Filing

Store ADRs under `docs/adr/`. Index them in `docs/adr/README.md`:

```markdown
# Architecture Decision Records

| # | Title | Status | Date |
| --- | --- | --- | --- |
| 0001 | Use posix_spawn rather than Process for child invocation | Accepted | 2026-01-04 |
| 0002 | Adopt strict-concurrency complete | Accepted | 2026-01-09 |
| 0003 | Self-signed TLS for LAN remote control | Accepted | 2026-02-12 |
| 0004 | Wire protocol version 1 | Accepted | 2026-02-12 |
```

A pull-request that introduces a non-trivial architectural change without a corresponding ADR is held until the ADR is written.

---

*Adapted from Michael Nygard's original ADR format. Modified for the engineering-discipline level appropriate to a small-but-serious team.*
