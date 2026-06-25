# Visual Style Guide — Template

> Copy this file into your project's `docs/style/visual-style.md` (or `docs/visual-style.md`) and fill in the bracketed sections. The Codemixer instance at [docs/style/visual-style.md](../../style/visual-style.md) is the worked example (~ 2,100 lines) — open it side-by-side as you adapt this template.

---

# {PROJECT_NAME} Visual Style Guide

This is the visual aesthetic for {PROJECT_NAME}. It describes how {PROJECT_NAME} *looks*, *moves*, *responds*, and *feels* — not what its code says about itself. It exists because pixel decisions accrete the same way code decisions do: every magic number, every off-curve ease, every shadow without intent becomes a quote inherited by the next reviewer.

Read this once, fully, before opening any view file. Re-read the *Visual review checklist* every time you raise a UI pull request. The reference exemplar `{EXEMPLAR_VIEW}` is this document made concrete.

---

## Platform applicability

> Replace this section with platform-applicability tags appropriate to your project.

---

## Contents

1. The soul — N visual principles
2. The reference exemplar — `{EXEMPLAR_VIEW}`
3. Hard rules (lint-enforceable)
4. `Theme` — the single source of visual truth
5. Color system
6. Typography
7. Spacing & rhythm
8. Iconography
9. Motion & easing
10. Surfaces, elevation, and materials
11. Pointer, cursor, and drag visuals
12. Layout & composition
13. Progressive disclosure
14. Activity indicators
15. The primary conversation / content surface
16. The composer / input surface
17. Detail panels
18. Palettes and autocomplete
19. Context menus
20. Search
21. Status, toasts, banners, and errors
22. Feedback patterns: success, skeleton, rate-limit
23. Permission and approval surfaces
24. Confirmation & destructive patterns
25. Voice, mic, and TTS (if applicable)
26. Form & settings design
27. Accessibility
28. Dark mode parity
29. Density, scaling, and Dynamic Type
30. Formatting reference
31. Window chrome and platform shell
32. Multi-window, sound, and haptics
33. Onboarding, empty states, and first-run
34. Remote control & pairing surfaces (if applicable)
35. Visual review checklist
36. Don'ts — the no-go list
37. Tooling & enforcement
38. Glossary
39. When in doubt

---

## 1. The soul — N visual principles

> Write 10–18 principles. Each gets a rationale. These are reviewed by eye; the lint can't catch them.
>
> Example principles to adapt:
>
> - Serene by default, dense on demand.
> - Type hierarchy over rules and boxes.
> - Color carries a category, not just a mood.
> - Motion serves comprehension, never decoration.
> - Activity is honest — gaps are always bridged.
> - Accessibility is the design, not a layer on top.
> - One source of truth: `Theme`.

---

## 2. The reference exemplar — `{EXEMPLAR_VIEW}`

> Pick one view file that embodies the whole visual language. Annotate it as `/// Reference visual exemplar — see /docs/visual-style.md.`

---

## 3. Hard rules (lint-enforceable)

> Examples to seed your list:
>
> - No hardcoded colors. All colors come from `Theme.color.*`.
> - No hardcoded fonts. All fonts come from `Theme.font.*`.
> - No magic numbers for spacing. All spacing comes from `Theme.spacing.*` (4 / 8 / 12 / 16 / 24 / 32 / 48 / 64).
> - No `Color(white: x)` or `Color(red: x, green: y, blue: z)` outside `Theme.swift`.
> - No animation duration outside the `Theme.motion.*` curves.
> - No `Image(systemName:)` outside `Theme.icon.*` or component files.
> - Every interactive view has a `.help(...)` modifier.
> - Every interactive view has an `accessibilityLabel`.

---

## 4. `Theme` — the single source of visual truth

> Cover what your project's design tokens look like. Codemixer's `Theme` exposes:
>
> - `Theme.color.*` — semantic colors (`text.primary`, `text.secondary`, `accent.agent`, `accent.danger`, `surface.card`, `surface.sunken`, `border.hairline`, `state.hover`, `signal.warning`, etc.)
> - `Theme.font.*` — six type roles (`displayLarge`, `display`, `title`, `headline`, `body`, `caption`, `mono`).
> - `Theme.spacing.*` — fixed multiples of 4 pt.
> - `Theme.shape.*` — corner radii (`small`, `medium`, `large`, `pill`).
> - `Theme.motion.*` — animation curves (`quick`, `responsive`, `changing`, `expressive`).
> - `Theme.elevation.*` — shadow definitions for raised / floating surfaces.
> - `Theme.icon.*` — common SF Symbol names.

---

## 5–6. Color & Typography

> Document every color and every type role with name, value, contrast ratio, and intended use. Include a screenshot or diagram if available.

---

## 7. Spacing & rhythm

> Document the spacing scale. Every value in your codebase must use one of these.

---

## 8. Iconography

> Document the icon system. SF Symbols only? Custom set? Sizing rules? Weight rules?

---

## 9. Motion & easing

> Document the curves. Each has a name, a duration, an ease, and a list of where it's used.

---

## 10. Surfaces, elevation, and materials

> Document the elevation system. How many levels? What shadow per level? What blur per level?

---

## 11. Pointer, cursor, and drag visuals

> Document cursor changes, hover delays, drag preview design, drop target visuals, resize affordances.

---

## 12. Layout & composition

> Document the grid (if any), the column rules, the margin scale, the responsive breakpoints.

---

## 13. Progressive disclosure

> Document how secondary actions appear on hover / focus / long-press. Codemixer uses an `IntentReveal` modifier — adapt for your framework.

---

## 14. Activity indicators

> Document the spinner / shimmer / skeleton vocabulary. See [reference/patterns/coherent-activity-heartbeat.md](../patterns/coherent-activity-heartbeat.md) for the server-side architecture.

---

## 15–25. Component-level rules

> One section per major component. For each: anatomy, sizing, states (rest / hover / active / disabled / loading / error), motion specifics, accessibility props.

---

## 26. Form & settings design

> Document row anatomy, validation visuals, button states, section grouping.

---

## 27. Accessibility

> Document at minimum: VoiceOver, Voice Control, Reduce Motion, Increase Contrast, Dynamic Type, keyboard navigation.

---

## 28. Dark mode parity

> Document the dark-mode strategy: derived colors? hand-tuned per-mode? what's the rule when a designer asks for a one-mode-only color?

---

## 29. Density, scaling, and Dynamic Type

> Document density modes (`compact`, `regular`, `comfortable`) and how they affect every component.

---

## 30. Formatting reference

> Numbers, durations, dates, costs, file sizes, locale rules, numerals, bidi.

---

## 31. Window chrome and platform shell

> Document window appearance (titlebar style, traffic lights, toolbar items), inactive-window appearance, restoration behaviour.

---

## 32. Multi-window, sound, and haptics

> Document multi-window behaviour, sound vocabulary, haptic vocabulary.

---

## 33. Onboarding, empty states, and first-run

> Document the first-time experience and the empty states for each major surface.

---

## 34. Remote control & pairing surfaces

> If your project pairs with companion devices, document those surfaces here.

---

## 35. Visual review checklist

> Inline checklist for PRs that touch visuals. Reuse the items from [reference/templates/pr.template.md](pr.template.md).

---

## 36. Don'ts — the no-go list

> Concrete things that look wrong by project standards.

---

## 37. Tooling & enforcement

> SwiftLint custom rules for color / font / spacing tokens, visual-diff testing if you use it.

---

## 38. Glossary

> Project-specific visual vocabulary.

---

## 39. When in doubt

> Decision-resolver paragraph.

---

*Last revised alongside [docs/code-style.md](../code-style.md) and [docs/architecture.md](../architecture.md). To propose changes to this visual style guide, open a PR that modifies this file and provides a screenshot or diagram showing the new rule in action.*
