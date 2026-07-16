# Codemixer Visual Style Guide

This is the visual aesthetic for Codemixer. It describes how Codemixer *looks*, *moves*, *responds*, and *feels* — not what its code says about itself. It exists because pixel decisions accrete the same way code decisions do: every magic number, every off-curve ease, every shadow without intent becomes a quote inherited by the next reviewer.

Read this once, fully, before opening any SwiftUI file that touches the surface. Re-read the *Visual review checklist* (§35) every time you raise a UI pull request. The reference exemplar `AssistantBubbleView.swift` is this document made concrete — when you cannot articulate what feels off, open `AssistantBubbleView` side-by-side; the contrast usually makes the answer obvious.

[docs/architecture.md](../architecture.md) is the canonical *how-and-where the system is put together*. [docs/style/code-style.md](code-style.md) is the canonical *how code reads*. This file is the canonical *how the product looks and behaves on screen*. When they conflict, `architecture.md` wins on structural decisions, `code-style.md` wins on how code reads, and this file wins on visuals.

---

## Contents

1. [The soul — fifteen visual principles](#1-the-soul--fifteen-visual-principles)
2. [The reference exemplar — `AssistantBubbleView`](#2-the-reference-exemplar--assistantbubbleview)
3. [Hard rules (lint-enforceable)](#3-hard-rules-lint-enforceable)
4. [Theme — the single source of visual truth](#4-theme--the-single-source-of-visual-truth)
5. [Color system](#5-color-system)
6. [Typography](#6-typography)
7. [Spacing & rhythm](#7-spacing--rhythm)
8. [Iconography](#8-iconography)
9. [Motion & easing](#9-motion--easing)
10. [Surfaces, elevation, and materials](#10-surfaces-elevation-and-materials)
11. [Pointer, cursor, and drag visuals](#11-pointer-cursor-and-drag-visuals)
12. [Layout & composition](#12-layout--composition)
13. [Progressive disclosure (`IntentReveal`)](#13-progressive-disclosure-intentreveal)
14. [Activity indicators](#14-activity-indicators)
15. [Conversation surface](#15-conversation-surface)
16. [Composer](#16-composer)
17. [Diff panel](#17-diff-panel)
18. [Slash palette and autocomplete](#18-slash-palette-and-autocomplete)
19. [Context menus](#19-context-menus)
20. [Search](#20-search)
21. [Status, toasts, banners, and errors](#21-status-toasts-banners-and-errors)
22. [Feedback patterns: success, skeleton, rate-limit](#22-feedback-patterns-success-skeleton-rate-limit)
23. [Permissions & approval surfaces](#23-permissions--approval-surfaces)
24. [Confirmation & destructive patterns](#24-confirmation--destructive-patterns)
25. [Voice, mic, and TTS surfaces](#25-voice-mic-and-tts-surfaces)
26. [Form & settings design](#26-form--settings-design)
27. [Accessibility](#27-accessibility)
28. [Dark mode parity](#28-dark-mode-parity)
29. [Density, scaling, and Dynamic Type](#29-density-scaling-and-dynamic-type)
30. [Formatting reference](#30-formatting-reference)
31. [Window chrome and platform shell](#31-window-chrome-and-platform-shell)
32. [Multi-window, sound, and haptics](#32-multi-window-sound-and-haptics)
33. [Onboarding, empty states, and first-run](#33-onboarding-empty-states-and-first-run)
34. [Remote control & pairing surfaces](#34-remote-control--pairing-surfaces)
35. [Visual review checklist](#35-visual-review-checklist)
36. [Don'ts — the no-go list](#36-donts--the-no-go-list)
37. [Tooling & enforcement](#37-tooling--enforcement)
38. [Glossary](#38-glossary)
39. [When in doubt](#39-when-in-doubt)

---

## Platform applicability

Codemixer **ships on macOS 14+ only** today. Visual rules below are written for the shipped Mac app. Tags marked **[Roadmap: iOS / iPadOS / visionOS]** describe how a future remote client *might* reflow the same vocabulary — they are not implemented surfaces.

- **[macOS]** — shipped.
- **[Roadmap: iOS / iPadOS / visionOS]** — not built; remote-control client only.
- **[Apple cross-platform]** — SwiftUI patterns that would transfer if we add other Apple platforms.

---

## 1. The soul — fifteen visual principles

These are not lint rules. They are reviewed by eye, and a pull request that violates them is refused merge regardless of how green CI is. Each principle has a rationale and a concrete example.

### 1.1 Serene by default, dense on demand

A first glance at Codemixer should feel like a quiet desk. Conversation is the centre; everything else is at the edges or hidden entirely. Toolbars are sparse, surfaces are flat, motion is rare. Density appears only when the user reaches for it: hovering a message, opening the diff panel, summoning the slash palette.

**Why:** an agent CLI wrapper is a creative tool. The user's attention belongs on their reasoning and the agent's response, not on twenty buttons fighting for it.

**Test:** stop a designer or engineer on the street, show them the empty conversation, and ask "where do I type?" The composer should be obvious in one second. If they hesitate, the chrome is too loud.

### 1.2 Progressive disclosure beats hidden complexity

The flip side of serenity is discoverability. Every feature is reachable; most features are hidden until intended. The contract is: **at-rest** is calm, **hover** reveals affordances, **focus** reveals modes, and **a deliberate gesture** (long-press, right-click, slash key) reveals the full surface.

Implementation pattern: the `IntentReveal` SwiftUI modifier (§13).

### 1.3 Motion has a job, or it doesn't ship

Every animation answers two questions: *what changed?* and *what caused it?* If neither answer is interesting, the motion is decoration and we remove it. Decoration adds latency, distracts the eye, and ages badly.

**Allowed motion:**
- State changes (loading → loaded, idle → busy).
- Spatial continuity (an element moves to where it came from).
- Tactile feedback (button pressed, message accepted).

**Forbidden motion:**
- Page-load flourishes.
- Tooltip fade-ins longer than 120ms.
- Animated gradients, parallax, "shine" effects.
- Animations that play on every render.

### 1.4 Content is the chrome

Where a designer might add a bordered container, we ask: *can the content speak for itself?* Often, type weight and spacing alone are enough hierarchy. Borders and backgrounds appear when they earn their place — usually at semantic boundaries (a tool call card has a card because it's a different kind of thing, not because it looks nicer).

### 1.5 One token, one source

Every visual decision lives exactly once. Colors come from `Theme.swift`. Spacing comes from `Theme.spacing`. Type comes from `Theme.font`. Motion durations come from `Theme.motion`. No raw `Color.red`, no inline `.padding(16)`, no `.font(.system(size: 14))`. The compiler is our design reviewer.

### 1.6 Activity is honest

The user must never wonder "is it stuck?" Every interaction that lasts more than 150ms emits a visible signal. Every gap longer than 500ms emits a refreshed signal. Every gap longer than 5s emits a contextual phrase ("Reading file…", "Running tests…"). This is non-negotiable — silence is a bug.

The architecture: `HeartbeatActivityMonitor` on the engine side emits structured events; `StatusPillView`, `ShimmerDots`, and `ThinkingBlockView` render them. Full system in §14.

### 1.7 Type is the primary structuring device

Codemixer's hierarchy is built from type, not lines or boxes. Six type styles cover the entire app (§6). Use weight and size to separate ideas before reaching for a divider or a background.

### 1.8 Color earns its place

Color in Codemixer is either *semantic* (success / warning / danger / agent identity) or *content* (syntax highlighting, diff red/green). Decorative color is forbidden. If you cannot answer "what does this color mean?", remove it.

A monochrome screenshot of Codemixer should still be legible.

### 1.9 Accessibility is the design

Every visible affordance has a Voice Control label, a keyboard shortcut, and a screen-reader description. These are not retrofits; they are written when the component is. A view without accessibility is not done, and not eligible for merge.

### 1.10 Dark mode is a sibling, not a child

Both schemes are designed at the same time. Every color is defined in both. Every screenshot reviewed is reviewed in both. No "looks fine in light, awkward in dark" — that's the same bug, twice.

### 1.11 Mouse, keyboard, voice, and remote API are equal

Every interaction is available through all four surfaces. Designs that imply "mouse only" or "keyboard only" are rejected. This is the architectural commitment; the visual reflection is that affordances appear in shapes that work on every input: a button is also a Voice Control target, a hover-reveal is also a `cmd+.` shortcut.

### 1.12 Errors are humane

An error message tells the user what happened, why it might have happened, and what to do next. It is never accusatory ("you provided invalid input"), never opaque ("an error occurred"), and never anonymous (no Codemixer error has an unattributed message).

The grammar template: *<what happened>. <why if non-obvious>. <next step if known>.*

### 1.13 Permissions are the user's question

When Claude asks to run a command, Codemixer's UI is built as *the user's deliberation*, not *the agent's interruption*. The permission card is centered, the choices are equally weighted, the destructive option is never the default, and the agent's quote is shown verbatim so the user is reading the agent, not Codemixer's interpretation.

### 1.14 Reduced motion is honoured everywhere

`@Environment(\.accessibilityReduceMotion)` is consulted in every animated view. When true: durations collapse to zero, spatial transitions become opacity cross-fades, the ShimmerDot becomes a static three-dot glyph. Reduced motion is never a "lesser" experience — it's a parallel one.

### 1.15 Density adapts

Codemixer runs comfortably on a 27" display and credibly on a 13" laptop. When (in future) a phone or pad client mirrors the same agent, the chrome compresses but the conversation does not. We support three density classes: `comfortable` (default macOS), `compact` (small windows or iPad), and `tactile` (touch surfaces). All three are driven by a single `Theme.density` setting plus environment-derived layout — never by `if isPhone { ... }`.

---

## 2. The reference exemplar — `AssistantBubbleView`

Before any other view ships, `AssistantBubbleView` is built to perfection. Its file header reads:

```swift
/// Reference visual exemplar — see /docs/style/visual-style.md.
```

Every subsequent view is reviewed against the question: *does this read like `AssistantBubbleView`?* When a reviewer cannot articulate what's wrong with a piece of UI, they open `AssistantBubbleView.swift` side-by-side and the contrast usually makes the answer obvious.

`AssistantBubbleView` carries every aesthetic in this document:

- Type from `Theme.font.body`, never inline `.font(...)`.
- Spacing from `Theme.spacing.s16` and `.s12`, never magic numbers.
- One `padding`, one `background`, one `clipShape` — in that order, never lasagna.
- `IntentReveal` modifier hiding the copy / quote-reply / regenerate buttons at rest, revealing them on hover or focus.
- Voice Control labels on every revealed button.
- `@Environment(\.colorScheme)` not consulted directly — colors come from `Theme` which adapts automatically.
- A `#Preview` showing both light and dark, both density classes, and a reduced-motion variant.
- An `accessibilityElement(children: .combine)` declaration so VoiceOver hears a single bubble, not a stack of fragments.

When this file is done, it is the answer to *show me what good looks like.*

---

## 3. Hard rules (lint-enforceable)

Checked by SwiftLint, SwiftFormat, custom scripts, and CI. A pull request that violates any of these fails the build.

- **No raw `Color.*` outside `Theme.swift`.** Custom SwiftLint rule rejects `Color.red`, `Color(.systemRed)`, `Color(red:green:blue:)`, `Color(hue:saturation:brightness:)` anywhere else.
- **No raw `.padding(N)` or `.padding(.top, N)` with a numeric literal outside `Theme.swift`.** Use `Theme.spacing.sN`.
- **No raw `.font(.system(size:))`.** Use `Theme.font.<role>`.
- **No raw `.cornerRadius(N)`.** Use `Theme.shape.<role>` (which returns a `RoundedRectangle` shape with the appropriate radius).
- **No `.shadow(radius: N, ...)`.** Use `Theme.elevation.<role>`.
- **One `padding`, one `background`, one `clipShape`** per stack, in that order. No lasagna.
- **Every `Button`, `Toggle`, `TextField`, `Slider`** has either visible text content or an `.accessibilityLabel`. CI greps for missing labels on icon-only buttons.
- **Every animated view consults `@Environment(\.accessibilityReduceMotion)`** before declaring an animation longer than `Theme.motion.quick`.
- **No `GeometryReader`** except where wrapping an absolutely-positioned overlay. Justify in code review otherwise.
- **No `if isLight { ... } else { ... }`** branching on color scheme. Colors come from `Theme` which already adapts.
- **`#Preview`** is mandatory for every view. CI's preview-compile job fails if a public view declares no preview.
- **No string literal `Text("...")`** for system phrases — must be a `LocalizedStringKey` literal (which `Text` accepts implicitly) or explicit `Text(verbatim:)`.
- **No SF Symbol used by string name** — use a typed `Theme.icon.<name>` accessor or an extension that constrains the symbol set.
- **No `.animation(...)`** without a value to trigger it; use `.animation(_:value:)` form.
- **No `.transition(.identity)` workaround** — declare the transition you want.
- **No `Image(systemName: ...)` directly inside `Button`** without a `Label` or an `.accessibilityLabel`.

---

## 4. Theme — the single source of visual truth

`Theme.swift` is the central registry. Every visual token is a typed property of a nested enum:

```swift
public enum Theme {
    public enum color { … }
    public enum font { … }
    public enum spacing { … }
    public enum shape { … }
    public enum elevation { … }
    public enum motion { … }
    public enum icon { … }
    public enum density { … }
}
```

### Conventions

- All members are `static let` — never computed for trivial tokens.
- Adaptive tokens (color, font when respecting Dynamic Type) live as `Color` or `Font` values that the SwiftUI runtime resolves; we never branch on environment ourselves.
- Token names are *semantic*, not *descriptive*: `Theme.color.surface.bubble.user`, not `Theme.color.gray100`. The semantic name carries intent.
- Each new token requires a one-line justification comment when added — *why this token exists, what it replaces.*

### Adding a token

1. Identify the semantic role (`surface.toolCard.background`, not `paleBlue`).
2. Define both light and dark variants in `Assets.xcassets`.
3. Add the typed accessor in `Theme.swift`.
4. Remove every inline literal that the new token replaces — leaving the literal is grounds for refusal.

### Removing a token

A token is removed only when no callers remain. CI fails if `Theme.color.foo` is referenced but `foo` is gone.

---

## 5. Color system

Codemixer uses a small, semantic palette. The full surface is built from ~25 tokens, no more.

### Categories

**Surfaces** — backgrounds at the three elevation levels:

- `Theme.color.surface.base` — the window background.
- `Theme.color.surface.raised` — cards, bubbles, panels.
- `Theme.color.surface.floating` — popovers, toasts, sheets.
- `Theme.color.surface.sunken` — inset wells (composer field, diff hunk body).

**Bubbles** — conversation message surfaces:

- `Theme.color.surface.bubble.user`
- `Theme.color.surface.bubble.assistant`
- `Theme.color.surface.bubble.tool`
- `Theme.color.surface.bubble.system`

**Text** — foreground levels:

- `Theme.color.text.primary` — body content.
- `Theme.color.text.secondary` — captions, timestamps.
- `Theme.color.text.tertiary` — placeholders, disabled state.
- `Theme.color.text.codeForeground` — monospaced inline code.
- `Theme.color.text.onAccent` — text on accent-colored surfaces.

**Accents** — semantic emphasis:

- `Theme.color.accent.agent` — the current agent's tint (Claude orange by default; per-adapter override).
- `Theme.color.accent.focusRing` — keyboard focus.
- `Theme.color.accent.success` — confirmations, completed tools.
- `Theme.color.accent.warning` — degraded states, low-confidence prompts.
- `Theme.color.accent.danger` — destructive actions, errors.

**Diff** — code change rendering:

- `Theme.color.diff.additionFill` / `additionStroke` / `additionGutter`
- `Theme.color.diff.deletionFill` / `deletionStroke` / `deletionGutter`
- `Theme.color.diff.contextBackground`

**State** — interaction feedback:

- `Theme.color.state.hover`
- `Theme.color.state.pressed`
- `Theme.color.state.selected`
- `Theme.color.state.disabled`

**Borders** — dividers and hairlines:

- `Theme.color.border.hairline` — the 1px line between regions.
- `Theme.color.border.divider` — heavier dividers between major sections.
- `Theme.color.border.focusRing` — focus outline (matches `accent.focusRing`).

### Palette rules

- **No more than two accent colors** in a single view. If the view needs three, the design is wrong.
- **No saturated red as primary surface.** Red is reserved for danger and diff deletions. A "primary red button" is forbidden.
- **Contrast is checked.** Every text-on-surface combination meets WCAG AA (4.5:1 for body, 3:1 for large text). CI runs `scripts/check-contrast.sh` on every Theme color pair.
- **The agent tint is a single hue per session.** Multiple agents in the same window each carry their own accent; we don't blend.

### Light & dark variants

Both schemes are designed in `Assets.xcassets`. The named color set has Any Appearance and Dark variants; the SwiftUI runtime handles the rest. No view branches on color scheme.

When designing a new color:

1. Define light first — that's where contrast issues are most visible.
2. Define dark by adjusting *luminance*, not hue. A token is the same idea in both schemes.
3. Verify in `#Preview` with `.preferredColorScheme(.light)` and `.dark`.

---

## 6. Typography

Codemixer ships with six type roles. Each role has a defined `Font`, a defined leading, and a defined tracking. Every text in the app is one of these — no exceptions.

```swift
public enum Theme.font {
    /// Largest display type — used only on the empty conversation hero.
    public static let display: Font  = .system(size: 32, weight: .medium, design: .default)

    /// Window-section titles ("Conversation", "Changes").
    public static let title: Font    = .system(size: 22, weight: .semibold, design: .default)

    /// Card headers, agent names, dialog titles.
    public static let headline: Font = .system(size: 17, weight: .semibold, design: .default)

    /// Body text — assistant prose, user prompts.
    public static let body: Font     = .system(size: 14, weight: .regular,  design: .default)

    /// Inline code and tool output — paired with `body` line-height.
    public static let bodyMono: Font = .system(size: 13, weight: .regular,  design: .monospaced)

    /// Captions, timestamps, hint text.
    public static let caption: Font  = .system(size: 12, weight: .regular,  design: .default)

    /// Footnote — used in toolbars and chips.
    public static let footnote: Font = .system(size: 11, weight: .medium,   design: .default)
}
```

### Rules

- **Six roles, no eighth.** A new role requires a written justification and a Theme PR.
- **Weight tells hierarchy.** Prefer raising weight over raising size.
- **Mono is for code and only code.** Tool names, file paths, and command snippets — never UI labels.
- **Leading is paired.** Body text uses 1.5× line height (21pt for 14pt body); headlines use 1.2×; mono uses 1.4×. Defined in `Theme.font.lineHeight`.
- **Tracking is left alone** except for `display` (which gets `-0.5` tracking to feel tight) and `caption` (which gets `+0.2` for legibility at small sizes).

### Dynamic Type

Type roles respect Dynamic Type via the `.scaledFont` modifier. The fixed sizes above are *defaults*; on platforms where Dynamic Type is honoured (iOS, iPadOS, visionOS, and macOS through Sonoma's "Larger Text" setting), the runtime scales them.

```swift
extension Font {
    static func scaled(_ role: Theme.font.Role) -> Font { … }
}

Text("Hello").font(Font.scaled(.body))
```

Code paths that depend on physical pixel measurements (the ShimmerDot rendering, the diff gutter width) read the resolved `UIFont`/`NSFont` metrics, never the fixed size.

### Internationalisation

- **Tracking is locale-aware.** Chinese / Japanese / Korean ignore tracking.
- **Right-to-left mirroring** is implicit — we use `.leading` / `.trailing`, never `.left` / `.right`.

### Don'ts

- No italics. They render poorly at body size on Retina, especially in mono.
- No underline as a styling tool — reserved for genuine hyperlinks.
- No all-caps for body content. (Footnote SF Symbol labels may use caps if the symbol's accessibility label does; otherwise no.)
- No mixed weights within a single sentence.

---

## 7. Spacing & rhythm

Codemixer is built on a 4-point grid. Every spacing value is one of:

```swift
public enum Theme.spacing {
    public static let s2:  CGFloat = 2    // hairline gaps
    public static let s4:  CGFloat = 4    // micro spacing inside compact controls
    public static let s8:  CGFloat = 8    // tight stack spacing
    public static let s12: CGFloat = 12   // default content gap inside a card
    public static let s16: CGFloat = 16   // default bubble padding, card padding
    public static let s24: CGFloat = 24   // between cards in a section
    public static let s32: CGFloat = 32   // between sections
    public static let s48: CGFloat = 48   // around hero content
    public static let s64: CGFloat = 64   // large empty-state breathing room
    public static let s96: CGFloat = 96   // page-margin maxima on wide windows
}
```

### Rhythm rules

- **A bubble has `s16` padding** on every side.
- **Inline content inside a bubble** is separated by `s12`.
- **Bubbles within a turn** are separated by `s8`.
- **Turns within a conversation** are separated by `s24`.
- **Sections within a panel** are separated by `s32`.

These values create a consistent vertical music — the eye learns the rhythm and stops noticing it.

### When to break the grid

You don't. If you find yourself wanting `s10` or `s20`, the design is wrong, not the grid. Either compress to `s8` or expand to `s12`/`s24`.

### Horizontal vs vertical

The same scale applies to both axes. Asymmetric padding (e.g., `.padding(.horizontal, .s16).padding(.vertical, .s12)`) is the common pattern for cards — wider than tall to mirror reading direction.

### Edge insets

Window-content edges have `s24` insets at default density, `s16` in compact, `s32` in comfortable on wide displays.

---

## 8. Iconography

Codemixer uses **SF Symbols** [Apple cross-platform] exclusively. No custom glyphs except where a brand mark is required (e.g., the Codemixer wordmark on the launch screen).

### Rules

- **Symbol names are typed** via `Theme.icon`. No `Image(systemName: "magnifyingglass")` directly in views.
- **Weight follows text weight.** A symbol next to body text uses `.regular`; next to a headline uses `.semibold`.
- **Size follows text size.** Symbols sit on the type baseline; their size derives from the surrounding `Theme.font`.
- **Hierarchical variants** are preferred for tints (the system uses muted secondary tones automatically).
- **Filled vs outline:** outline is default; filled denotes selected or active state.

### The Codemixer icon vocabulary

A small, deliberate set:

```swift
public enum Theme.icon {
    public static let send       = Image(systemName: "arrow.up.circle.fill")
    public static let stop       = Image(systemName: "stop.circle.fill")
    public static let mic        = Image(systemName: "mic.circle.fill")
    public static let micActive  = Image(systemName: "waveform.circle.fill")
    public static let think      = Image(systemName: "brain")
    public static let review     = Image(systemName: "eye")
    public static let edit       = Image(systemName: "pencil")
    public static let copy       = Image(systemName: "doc.on.doc")
    public static let regenerate = Image(systemName: "arrow.clockwise")
    public static let search     = Image(systemName: "magnifyingglass")
    public static let diff       = Image(systemName: "square.split.2x1")
    public static let permission = Image(systemName: "lock.shield")
    public static let warning    = Image(systemName: "exclamationmark.triangle")
    public static let danger     = Image(systemName: "exclamationmark.octagon")
    public static let success    = Image(systemName: "checkmark.circle")
    public static let info       = Image(systemName: "info.circle")
    public static let close      = Image(systemName: "xmark")
    public static let more       = Image(systemName: "ellipsis")
    // …
}
```

### Spacing around symbols

A leading icon is followed by `s8` before its label. A trailing icon is preceded by `s8` after its label. Symbols never touch text.

### Don'ts

- No emoji as UI icons. (Conversation content from the agent may contain emoji; the *chrome* doesn't.)
- No multicolor SF Symbols unless the symbol is itself a semantic indicator (e.g., `exclamationmark.triangle.fill` in `.warning` tint).
- No animated symbols outside the `mic` recording state and the `regenerate` action.

---

## 9. Motion & easing

Motion is a language with five words. Use it sparingly and the user notices it; use it constantly and the user fights it.

### Durations

```swift
public enum Theme.motion {
    public static let instant:    Duration = .zero          // 0ms — reduced-motion default
    public static let quick:      Duration = .milliseconds(120)
    public static let gentle:     Duration = .milliseconds(220)
    public static let considered: Duration = .milliseconds(350)
    public static let deliberate: Duration = .milliseconds(550)  // rare; modal transitions
}
```

### Curves

- **`.easeOut`** — entrances and reveals. The view arrives smoothly and stops with intention.
- **`.easeIn`** — exits and dismissals. The view begins moving and accelerates away.
- **`.easeInOut`** — state changes between two stable points (toggle, expand/collapse).
- **`.spring(response: 0.35, damping: 0.85)`** — tactile feedback (press, drop, snap). Used sparingly.

A custom token wraps these:

```swift
public enum Theme.motion.curve {
    public static let arriving = Animation.easeOut(duration: Theme.motion.gentle.asTimeInterval)
    public static let leaving  = Animation.easeIn(duration: Theme.motion.quick.asTimeInterval)
    public static let changing = Animation.easeInOut(duration: Theme.motion.gentle.asTimeInterval)
    public static let tactile  = Animation.spring(response: 0.35, dampingFraction: 0.85)
}
```

### Where motion lives

| Surface                            | Motion                                                  |
| ---                                | ---                                                     |
| Bubble appears                     | `arriving`, opacity + 4pt upward translate              |
| Bubble dismissed                   | `leaving`, opacity                                      |
| IntentReveal hover                 | `quick`, opacity only                                   |
| StatusPill phrase change           | `changing`, cross-fade                                  |
| ShimmerDot pulse                   | `quick`, opacity, infinite                              |
| Slash palette open                 | `gentle`, opacity + scale 0.96 → 1                       |
| Permission card                    | `considered`, opacity + 8pt upward translate            |
| Toast                              | `gentle`, slide from top edge                           |
| Sheet (settings, onboarding step)  | `deliberate`, system default                            |
| Diff panel slide                   | `considered`, width                                     |

### Reduced motion

When `accessibilityReduceMotion` is true:

- All durations clamp to `Theme.motion.instant`.
- Translates are removed; only opacity remains.
- Shimmer dots become a static glyph.
- Sheets and modals still animate (system-managed), but at system reduced-motion timing.

### Don'ts

- No motion on every render. An animation triggered by `.onAppear` runs once.
- No spring on long durations. Spring is for tactile interactions, not 350ms transitions.
- No multiple concurrent animations on the same view. Compose by `.transition` and `.animation(_:value:)`; don't stack `.animation` modifiers.

---

## 10. Surfaces, elevation, and materials

Codemixer recognises three elevation levels. Each has a defined surface color, optional material, and optional shadow.

### Levels

```swift
public enum Theme.elevation {
    /// Base — the window content area. No shadow, no material.
    public static let base = Surface(
        background: Theme.color.surface.base,
        material: nil,
        shadow: nil
    )

    /// Raised — cards, bubbles, the composer field.
    /// 1pt hairline border, no shadow on macOS; subtle shadow on iOS / iPadOS.
    public static let raised = Surface(
        background: Theme.color.surface.raised,
        material: .regularMaterial,
        shadow: nil // [macOS], shadow added on [iOS / iPadOS]
    )

    /// Floating — popovers, toasts, the slash palette, context menus.
    /// Always has a soft shadow on every platform.
    public static let floating = Surface(
        background: Theme.color.surface.floating,
        material: .ultraThinMaterial,
        shadow: .soft(radius: 16, opacity: 0.18)
    )
}
```

### Materials

- **Base** has no material. The window's chrome is opaque.
- **Raised** uses `.regularMaterial` only when the underlying content benefits from translucency (e.g., the composer field over the conversation). Most raised surfaces are solid `Theme.color.surface.raised`.
- **Floating** always uses `.ultraThinMaterial` so popovers feel weightless.

### Shadow rules

- **Never a hard shadow.** Always large radius, low opacity.
- **Never coloured shadows.** Always black at variable opacity.
- **Never multiple shadows on the same surface.**
- **Macros are macOS-aware.** Shadows are subtle or absent on macOS where translucency does the work; on iOS / iPadOS, shadows are slightly stronger to separate elevation layers visually.

### Corner radii

```swift
public enum Theme.shape {
    public static let small:  CGFloat = 6   // chips, small buttons
    public static let medium: CGFloat = 10  // bubbles, cards
    public static let large:  CGFloat = 16  // sheets, popovers
    public static let pill:   CGFloat = 999 // status pill, capsule controls
}
```

The radius is part of the elevation language: raised surfaces are `medium`, floating surfaces are `large`, capsule controls are `pill`. Mixing radii within a single surface (e.g., a card with one corner pinned and three rounded) is forbidden.

---

## 11. Pointer, cursor, and drag visuals

The pointer is a tool, not a decoration. Codemixer uses native macOS cursors throughout — never custom — but the *moments* at which the cursor changes are deliberately designed.

### Cursor vocabulary

| Cursor | When |
| --- | --- |
| `default` (arrow) | Resting over chrome, prose, surfaces. |
| `text` (I-beam) | Inside any text-selectable region (bubbles, code blocks, fields). |
| `pointingHand` | Over a button, link, or any actionable region that is not a text field. |
| `openHand` | Over a draggable handle at rest (split-pane divider, list reorder grip). |
| `closedHand` | While actively dragging. |
| `resizeLeftRight` / `resizeUpDown` | Over a resize boundary (window splits, panel edges). |
| `dragLink` | While dragging a file *into* the composer from outside the window. |
| `notAllowed` | Over a drop target that rejects the current drag. |

Custom cursors are forbidden. Every cursor is a native `NSCursor` [macOS] or the platform's equivalent.

### Hover delay vocabulary

The timing of *when things appear on hover* is as deliberate as the visuals themselves.

| Delay | Action |
| --- | --- |
| Instant | IntentReveal opacity changes — the trigger fires immediately on pointer entry. |
| 50 ms | Stability grace — IntentReveal does not commit until the pointer has been stable for 50 ms, preventing flicker on fast pointer transit. |
| 150 ms | Tooltip dismissal grace after the pointer leaves — gives the user time to move *into* an interactive tooltip. Rarely used. |
| 500 ms | Tooltip appearance delay over any element carrying `.help(_:)`. Matches the Apple-standard hover timing. |
| 800 ms | Long-press for context menus on touch surfaces [iOS / iPadOS] — matches the iOS context-menu standard. |
| 400 ms | Codemixer-specific long-press on the mic button — overrides the generic touch long-press because dictation is a high-frequency, latency-sensitive interaction. |

### Tooltip system

Tooltips appear after the 500 ms hover delay over any interactive element that carries `.help(_:)`. Rules:

- **Content is short.** A tooltip is a *name* or a *one-phrase explanation*, never a paragraph. If more is needed, use an info popover.
- **Position** — anchored above the element on desktop windows, below near the bottom edge, with the system's automatic edge-avoidance.
- **One at a time.** Moving the pointer to a new element instantly dismisses the previous tooltip.
- **Type** — `Theme.font.caption` in `Theme.color.text.primary` on `Theme.elevation.floating`.
- **Motion** — fade in `quick` (120 ms). No sliding.
- **No interactive tooltips** in v1. If the content has a button, it belongs in a popover.

### Drag and drop visuals

A drag is a four-state interaction: handle (at rest), drag preview (in flight), drop target (valid / invalid), drop indicator (insertion point).

- **Drag handle** — `line.3.horizontal` SF Symbol, `Theme.color.text.tertiary`. Cursor becomes `pointingHand` on hover and `closedHand` while grabbed.
- **Drag preview** — a faithful 60%-alpha snapshot of the dragged element follows the pointer with a `Theme.elevation.floating` shadow.
- **Drop target — at rest** — looks normal; no overlay.
- **Drop target — valid drag hovering** — `Theme.color.accent.focusRing` 2 pt dashed outline, `Theme.color.state.hover` fill at 60 % opacity, animated in over `quick` (120 ms).
- **Drop target — invalid** — `notAllowed` cursor; the rejecting element subtly desaturates (20 % grayscale filter). No red flash; "not now" is not an error.
- **Drop indicator** in reorderable lists — 2 pt `Theme.color.accent.focusRing` horizontal rule between rows, appearing at the prospective insertion point. Position animates with `.changing` (220 ms).
- **Multi-file drag** — drag preview shows the count badge at the trailing-bottom corner ("3 items") atop the lead item's snapshot.

### Resize affordances

- **Window splits** — 4 pt invisible hit zone centered on the visible 1 pt divider. Cursor switches to the appropriate resize axis on hover.
- **Composer field grow** — automatic, no manual handle. Users never resize the composer themselves.
- **Diff panel width** [macOS] — draggable; cursor `resizeLeftRight`, with snap zones at 25 % / 33 % / 50 % of the window.
- **Sheet height** [macOS] — the system handles resize; we don't add custom handles.

### When the pointer is hidden

- **During text typing** [macOS] — the system hides the pointer automatically; we never override.
- **Full-screen Quick Look** [macOS, post-v1] — system-managed.
- **TTS playback** — the pointer stays visible; speaking is not a pointer-disrupting activity.

### Right-click / secondary click

- **Always available on every visible surface** that has a context menu (see §19).
- **Two-finger tap on trackpad** maps to right-click — handled by the system; we never re-implement.
- **Voice Control "Right-click X"** invokes the context menu via accessibility — every menu item is therefore voice-addressable by its visible label.

---

## 12. Layout & composition

### The window

[macOS] Codemixer's main window is a `NavigationSplitView`: a collapsible session navigator, then the conversation + diff detail:

```
┌───────────────┬────────────────────┬──────────────────────┐
│               │                    │                      │
│  Session      │  Conversation      │   Diff (optional,    │
│  Navigator    │  (always shown)    │   can be collapsed)  │
│  (collapsible)│                    │                      │
│               │                    │                      │
│               ├────────────────────┴──────────────────────┤
│               │  Composer (always at the bottom)          │
└───────────────┴───────────────────────────────────────────┘
```

[iOS / iPadOS / visionOS] The same regions exist but reflow into a single column: the navigator becomes a slide-over / first column, the diff is accessible via a tab or sheet.

### Session Navigator

The leftmost column lists the **currently-loaded workspace's projects** and, under each, that project's resumable sessions. It is *not* a global "recent projects" list — it is scoped to the open workspace.

- **Width:** `sessionSidebarMinWidth … sessionSidebarIdealWidth … sessionSidebarMaxWidth` tokens; never literals.
- **Collapsibility:** toggled via the toolbar button or `cmd+\`. Visibility persists through `AppearancePrefs.sidebarVisible` (the shared prefs path, never `UserDefaults`), so it survives relaunch and stays multi-mode safe.
- **Structure:** one `surface.panel` background, a hairline trailing divider, hairline group separators. No nested boxes competing for attention (principle 1.4).
- **Projects:** a new project is created as a **subfolder of the workspace**; an *added existing* project keeps its original path. Both create paths and the "add existing" flow live behind the header's `+` menu.
- **Sessions:** grouped by recency (Today / Yesterday / earlier). Selection is a soft `surface.bubbleUser` wash with a `matchedGeometryEffect`, never a heavy fill. The active session shows a small `signal.success` dot.
- **Transport neutrality:** when the active agent has no resumable-session concept (`supportsResumableSessions == false`), projects show **New Chat only** with no session rows. An empty list is a first-class empty state ("No prior sessions. Start a new one."), never an error.
- **Modality parity (principle 1.11):** every row is a focusable button (keyboard + Return), carries an `accessibilityLabel`/trait, mirrors hover actions in a right-click context menu (mouse + Voice Control), and routes its action through wire `AgentCommand`s (`.newSession` / `.openProject`) so remote clients reach the same behavior. `New Chat` is `cmd+n`.
- **Motion:** disclosure and selection use the `changing` token, resolved through the reduced-motion helper.

### Resizable splits

- The diff panel toggles open/closed via a window-toolbar button or `cmd+D`.
- Open default width: 40% of the window.
- Min conversation width: 480pt. Below that, the diff auto-collapses.
- Composer height grows with input up to 6 lines, then scrolls internally.

### Empty conversation

The hero state — no messages yet — has two faces, driven only by view-model state (transport-neutral):

- **No workspace open:** a `folder.badge.questionmark` glyph, "No workspace open", and a single hint to open a project from the navigator.
- **Workspace ready:** a `sparkles` glyph, "Ready when you are", and a hint naming the workspace ("Ask anything about *Name*. Type a prompt below to begin.").

Both use `heroIcon` type, a centered column clamped to the reading width, generous `s32` padding, and exactly one idea each. No tutorial overlays, no helper text walls. The hero cross-fades to the conversation with the `changing` token (reduced-motion safe).

### Conversation list

- Single column, max width clamped at 720pt for legibility.
- Centered horizontally when the conversation area is wider.
- Turns are separated by `s24`; bubbles within a turn by `s8`.
- Timestamps appear only on hover (IntentReveal) and on the first/last bubble of every minute.

### Sticky elements

- **StatusPill** stays pinned at the top of the conversation, just below the window toolbar.
- **Composer** stays pinned at the bottom, always visible.
- **Search overlay** floats over the conversation but doesn't displace it.

---

## 13. Progressive disclosure (`IntentReveal`)

The single most important visual pattern in Codemixer. The `IntentReveal` modifier governs every secondary action, every hover-shown control, every "advanced" surface.

### The contract

A view can be in one of three intent states:

- **`.atRest`** — calm; only primary content visible.
- **`.intent`** — the user has signalled interest (hover with mouse, focus with keyboard, tap-and-hold on touch). Secondary affordances appear.
- **`.committed`** — the user has selected the surface (right-click, modal open, search active). Tertiary affordances appear; the surface is now the focus of attention.

### Implementation

```swift
public struct IntentReveal<Content: View, Reveal: View>: View {
    let primary: Content
    let onIntent: Reveal

    public var body: some View {
        primary
            .overlay(alignment: .topTrailing) {
                onIntent
                    .opacity(intentState == .atRest ? 0 : 1)
                    .accessibilityHidden(intentState == .atRest)
                    .animation(.arriving, value: intentState)
            }
            .onHover { hovering in /* update intentState */ }
            .focusable()
            .onFocus { focused in /* update intentState */ }
    }
}
```

### Rules

- **Voice Control sees everything.** Even at `.atRest`, the secondary affordances are `.accessibilityHidden(false)` *for Voice Control* — they're just visually transparent. Voice users say "Show copy button" and it appears; mouse users hover.
- **Keyboard reveals.** Tabbing to a bubble auto-enters `.intent` state. The user never needs a mouse to see the actions.
- **Long-press reveals on touch.** [iOS / iPadOS] A long-press on a bubble enters `.committed` state, surfacing the full context menu.
- **Reveals fade in `quick` (120ms).** Never instant — that flickers. Never `gentle` — that lags.
- **No more than three revealed affordances per surface.** If you need four, the design is wrong.

### Where IntentReveal applies

| Surface                | At rest               | Intent                            | Committed                          |
| ---                    | ---                   | ---                               | ---                                |
| AssistantBubble        | Text only             | Copy, Quote, Regenerate           | Full context menu                  |
| UserBubble             | Text only             | Edit, Copy                        | Full context menu                  |
| ToolCallCard           | Header collapsed      | Expand / Collapse, Copy command   | Full diff if produced              |
| ConversationHeader     | Title only            | Star, Rename, Archive             | Settings sub-panel                 |
| DiffHunk               | Hunk text             | Copy, View in editor              | Apply individually (post-v1)       |

---

## 14. Activity indicators

The honesty principle (§1.6) demands a continuous, structured visible signal during any non-trivial work. Three primitives cover every case.

### The state machine

`HeartbeatActivityMonitor` is the engine-side actor that drives every indicator. It emits structured `AgentEvent` cases:

- `.turnStarted` — first user prompt sent.
- `.thinking(phrase: String?)` — the assistant is reasoning. Optional phrase from `/think`-mode output.
- `.toolStarted(name: String)` — a tool is about to run.
- `.toolProgress(callID: UUID, progress: ToolProgress)` — incremental progress.
- `.noEventGap(elapsed: Duration)` — emitted every 500ms while busy; tells the UI "still working."
- `.turnEnded` — the turn is complete.

The UI's role is to project these into one of three primitives:

### 13.1 ShimmerDot

The smallest, calmest indicator. Three dots that breathe in opacity, never moving.

```swift
struct ShimmerDots: View {
    var body: some View {
        HStack(spacing: Theme.spacing.s4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.color.text.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(opacities[i])
            }
        }
        .accessibilityLabel("Working")
    }
}
```

Used inline at the end of the latest assistant bubble when the assistant is composing a response.

### 13.2 StatusPill

A pill anchored at the top of the conversation. Carries an icon + a short phrase.

```
┌──────────────────────────────┐
│  ◐  Reading file…            │
└──────────────────────────────┘
```

The phrase comes from `StatusPhraseResolver`, which picks the highest-priority signal:

1. Permission-requested → "Waiting for approval"
2. Tool-running → "<tool name>…"
3. Thinking → "Thinking…"
4. Heartbeat — > 5s gap → "Still working…"
5. Idle → pill hidden

Phrase changes use `.changing` (220ms cross-fade). The icon is `Theme.icon.<contextual>` and rotates 360° once per 1.5s during the `.thinking` state — a single, slow rotation, not a spinner.

### 13.3 ThinkingBlock

When the agent emits structured thinking content (e.g., from `/think`), it surfaces as a collapsible block above the assistant bubble:

```
┌───────────────────────────────────────────┐
│  ▾ Thinking (3 paragraphs)                │
│  ───────────────────────────────────────  │
│  …                                        │
│  …                                        │
└───────────────────────────────────────────┘
```

- **Collapsed by default** — the user opts in.
- **Header is `caption` weight** — never competes with the assistant's response.
- **Body is `bodyMono` if the agent emitted code-like content, else `body`.**
- **Opening uses `.changing` (220ms)**, height-based.

### 13.4 Tickers

Below the StatusPill, ticker text emits short factual lines describing what just happened:

```
✓ Read AppDelegate.swift (240 ms)
✓ Found 3 matches in src/
… Running tests
```

Tickers fade in on `arriving`, fade out (`.leaving`) after 4s of inactivity. Maximum visible: 5 lines. Older ticks scroll up and out.

### Composition

A typical "busy" frame:

```
┌──────────────────────────────────┐  ← window toolbar
├──────────────────────────────────┤
│  [StatusPill: Running tests…]    │  ← always pinned
│  ✓ Compiled module               │  ← tickers fade through
│  ✓ Loaded fixtures               │
│  … Running 18 tests              │
│                                  │
│  <last assistant bubble>         │
│   …with ShimmerDots inline       │
│                                  │
└──────────────────────────────────┘
```

---

## 15. Conversation surface

### Turn composition

A "turn" is one user message + the assistant's response (potentially many bubbles).

```
┌── turn ──────────────────────────────────────┐
│                                              │
│  ┌── UserBubble ──────────────────┐          │
│  │  "Refactor the diff parser"    │          │
│  └────────────────────────────────┘          │
│                                              │
│              ┌── AssistantBubble ──────────┐ │
│              │  "I'll start by reading…"   │ │
│              └─────────────────────────────┘ │
│                                              │
│              ┌── ToolCallCard ─────────────┐ │
│              │  ▸ Read DiffParser.swift   │ │
│              └─────────────────────────────┘ │
│                                              │
│              ┌── AssistantBubble ──────────┐ │
│              │  "The parser uses a…"       │ │
│              └─────────────────────────────┘ │
│                                              │
└──────────────────────────────────────────────┘
```

### Bubbles

- **UserBubble**: left-aligned, `Theme.color.surface.bubble.user`, `medium` corner radius, `s16` padding, `body` text.
- **AssistantBubble**: right-aligned, `Theme.color.surface.bubble.assistant`, same shape and padding.
- **ToolCallCard**: full-width inset, `Theme.color.surface.bubble.tool`, header + expandable body.
- **SystemBubble**: centered, no background, `caption` text in `text.tertiary` — used for "Session resumed", "Permission granted", etc.

### Markdown rendering

The assistant emits Markdown. Codemixer renders it with:

- **Headings**: mapped to `headline` (h1, h2) and `body` bold (h3+).
- **Inline code**: `bodyMono`, `Theme.color.surface.sunken` background, `s4` padding.
- **Code blocks**: `bodyMono`, `Theme.color.surface.sunken` background, `s12` padding, `small` corner radius.
- **Lists**: native SwiftUI lists with `s4` item spacing.
- **Block quotes**: `s12` leading inset with a 2pt `Theme.color.border.divider` rule.
- **Links**: `Theme.color.accent.agent` underline-on-hover.

### Code blocks

When a code block is fenced with a language, syntax highlighting applies via `swift-syntax-highlighting`. Colors come from `Theme.color.code.*` — defined alongside the diff palette.

A code block has IntentReveal affordances:

- Copy button (top-right, hidden at rest).
- "Open in editor" button [macOS — opens the file in the user's default editor for the language].

### Selection and copy

- Text is fully selectable in every bubble (`.textSelection(.enabled)`).
- The selection color matches the OS appearance — we never override it.
- Right-click on selected text reveals the standard system Services + Codemixer additions ("Quote in reply", "Send to /review").

### Quoted reply

The user can right-click any bubble (or use the IntentReveal Quote button) to insert a quoted excerpt into the composer:

```
> The parser uses a recursive descent…

Yes — let's change that to a state machine.
```

### Edit and resubmit

The user can edit any past `UserBubble`:

- IntentReveal exposes an Edit pencil.
- Clicking enters an inline edit mode: the bubble becomes a text editor with `Submit` and `Cancel` actions.
- Submit creates a new turn from that point forward; the original turn becomes greyed out (`Theme.color.state.disabled`) with a "Replaced" badge.
- Cancel reverts to the original bubble with no change.

---

## 16. Composer

The persistent input surface at the bottom of the window.

### Anatomy

```
┌──────────────────────────────────────────────────────────────┐
│  [/think] [/review]                                          │  ← mode toggles
│  ┌────────────────────────────────────────────────────────┐  │
│  │  Type a message…                                       │  │  ← TextField (auto-grow)
│  │                                                        │  │
│  └────────────────────────────────────────────────────────┘  │
│  [@ mic ]  [@ attach ]               [@ stop ] [@ send ]    │  ← leading / trailing toolbar
└──────────────────────────────────────────────────────────────┘
```

### Layout rules

- **Field auto-grows** from 1 line up to 6 lines, then scrolls.
- **Padding**: `s16` around the field, `s8` between toolbar items.
- **Background**: `Theme.color.surface.raised` with `Theme.elevation.raised` material on macOS.
- **Top border**: `Theme.color.border.hairline`, 1pt.
- **Corner radius**: `medium`.

### Mode toggles

Two mutually-exclusive toggles on the leading toolbar:

- **`/think`** — `Theme.icon.think`, lights up `Theme.color.accent.agent` when active.
- **`/review`** — `Theme.icon.review`, lights up `Theme.color.accent.agent` when active.

Clicking either inserts the corresponding slash prefix at the start of the message (and removes it when toggled off). Both available from the slash palette as well.

### Mic button

- **At rest**: `Theme.icon.mic`, `Theme.color.text.secondary`.
- **Recording**: `Theme.icon.micActive`, `Theme.color.accent.danger`, animated wave (respects reduced motion → static).
- **Permission denied**: `Theme.icon.mic` with `Theme.color.state.disabled`, taps open the permission settings sheet.

### Send / Stop

- **Send** is enabled only when the field has non-whitespace content or an attached file.
- **Stop** replaces the Send button whenever the engine is busy. Same position, same size — the user never has to look for it.
- **Stop is keyboard-shortcut `cmd+.`** [macOS] / **double-tap escape on hardware keyboard** [iOS / iPadOS].

### Keyboard behaviour

- **Enter** submits.
- **Shift+Enter** inserts a newline.
- **/** at start of an empty field opens the slash palette.
- **@** opens the file-mention palette (post-v1 hook into project file picker).
- **Esc** clears the field if non-empty, blurs the field if empty.

### Focus indicator

The field shows a `Theme.color.accent.focusRing` 2pt outline when focused. On macOS, the system also shows its own focus ring; we suppress it via `.focusEffectDisabled()` for the field and provide our own — the system ring competes with our visual language.

---

## 17. Diff panel

### Anatomy

```
┌─────────────────────────────┐
│  Changes              [⌄]   │  ← header
├─────────────────────────────┤
│  ► AppDelegate.swift  +12 -3│  ← changed files list
│    DiffParser.swift   +5 -22│
│    Theme.swift        +1   │
├─────────────────────────────┤
│  @@ Hunk header             │  ← selected file's hunks
│    context line             │
│  + added line               │
│  - removed line             │
│    context line             │
└─────────────────────────────┘
```

### Changed-file list

- **Row layout**: file icon (SF Symbol per extension), filename in `body`, additions/deletions in `caption`.
- **Status icon**: `▴` (modified), `+` (added), `−` (deleted), `→` (renamed).
- **Selection**: clicking a row scrolls the hunk view to that file's first hunk. Selected row uses `Theme.color.state.selected`.
- **IntentReveal** on row: copy path, open in editor.

### Hunk view

- **Monospaced** throughout, `bodyMono` at `s12` line height.
- **Gutter**: 32pt wide, `Theme.color.surface.sunken` background, line numbers in `caption` `text.tertiary`.
- **Addition row**: `Theme.color.diff.additionFill` background, `Theme.color.diff.additionStroke` left border (2pt), gutter shows `+`.
- **Deletion row**: `Theme.color.diff.deletionFill`, deletion stroke and `−` gutter.
- **Context row**: `Theme.color.diff.contextBackground`, no left border, line number in both columns.
- **Hunk header (`@@`)**: `caption`, `text.tertiary`, hairline divider above.

### Empty diff

When no changes are pending: a quiet `caption` line in the body — *"No changes since last commit."* No illustration, no large icon.

### Panel toggle

The diff panel can be:

- Closed (default for new sessions).
- Open as a side pane (default when changes appear during a turn).
- Open as a full-window overlay (post-v1, via `cmd+shift+D`).

Animation: `.considered` width transition.

---

## 18. Slash palette and autocomplete

### Slash palette

Triggered by `/` at the start of an empty composer field, or by clicking the slash-palette button (IntentReveal on the composer toolbar).

```
┌───────────────────────────────────────────┐
│  /                                        │
│  ─────────────────────────────────────    │
│  /think     Reason step-by-step before…   │
│  /review    Review changes before app…    │
│  /clear     Clear the conversation        │
│  /resume    Resume a previous session     │
│  /export    Export the conversation       │
│  /help      Show command reference        │
│  …                                        │
└───────────────────────────────────────────┘
```

- **Floating popover** at the composer's leading edge, `Theme.elevation.floating`.
- **Filter as the user types** — fuzzy match on command name and description.
- **Selection**: arrow keys, mouse hover, or Voice Control "Click /think".
- **Enter** confirms; the slash command is inserted into the field, ready to submit or compose around.
- **Esc** dismisses.
- **Animation**: `.gentle` opacity + scale 0.96 → 1.

### Mention palette

`@` opens a similar palette for files in the workspace, matching `git ls-files`. Same visual language, same shortcuts.

> **Not shipped:** mid-turn inline prompt composers (separate from the main composer) were removed. Permission prompts and the main `PromptComposerView` cover user input today.

### Autocomplete

Within the composer, file paths, command names, and known agent shortcuts are matched and shown as a single suggestion line above the field:

```
… type AppD                  ↩ AppDelegate.swift
```

- `caption`, `text.tertiary`, fades in after 200ms of paused typing.
- `Tab` accepts, `Esc` dismisses.

---

## 19. Context menus

Right-click (or long-press [iOS / iPadOS]) reveals a contextual menu. Codemixer's context menus are *complete* — every action available anywhere in the UI is also available through context menus, so mouse-only or touch-only users never feel limited.

### Menu organisation

Sections separated by a divider, ordered by frequency of use:

```
┌────────────────────────────────────┐
│  Copy                       ⌘C    │
│  Copy as Markdown                  │
│  Quote in Reply             ⌘⇧R    │
│  ──────────────────────────────    │
│  Edit (UserBubble only)     ⌘E    │
│  Regenerate (AssistantBubble) ⌘R   │
│  ──────────────────────────────    │
│  Read Aloud                 ⌘⇧S    │
│  Search Conversation        ⌘F    │
│  ──────────────────────────────    │
│  Delete Turn                ⌫    │
└────────────────────────────────────┘
```

### Rules

- **Shortcut hints aligned right** in `caption` `text.tertiary`.
- **Destructive items in `Theme.color.accent.danger`** with a confirm step (no immediate destructive action from a context menu).
- **No icons in context menus** — the OS-native context menu chrome doesn't carry our visual language, and adding icons feels heavy.
- **Voice Control labels exist** on every menu item.

### Menu sources

| Surface             | Menu items                                                            |
| ---                 | ---                                                                   |
| AssistantBubble     | Copy, Copy as Markdown, Quote, Regenerate, Read Aloud, Search, Delete |
| UserBubble          | Copy, Edit, Quote, Delete                                             |
| ToolCallCard        | Copy command, Re-run (post-v1), Hide tool calls                       |
| DiffHunk            | Copy hunk, Copy file path, Open in editor                             |
| Composer field      | Standard system menu + Codemixer additions (Slash command, Mention)   |

---

## 20. Search

`cmd+F` opens an overlay search bar at the top of the conversation:

```
┌──────────────────────────────────────────────────────┐
│  [@search]  "parser"          1 of 12  [<] [>] [x]   │
└──────────────────────────────────────────────────────┘
```

- **Floating, `Theme.elevation.floating`** — never displaces the conversation.
- **Match highlighting**: matches in the conversation get a `Theme.color.accent.warning` background; the current match adds a stronger outline.
- **Match count and navigation**: previous / next buttons with keyboard arrows.
- **Esc dismisses** and clears all highlights.
- **Animation**: `.gentle` slide from top.

### Session-level search

A separate "Search all sessions" command opens a full sheet showing matches across the user's session history. Same visual language, different scope.

---

## 21. Status, toasts, banners, and errors

### Status pill

Covered in §14.2. The pill is the *active state* indicator.

### Toasts

Transient messages that fade out:

```
┌────────────────────────────────────┐
│  ✓  Session saved                  │
└────────────────────────────────────┘
```

- **Anchored top-center**, below the window toolbar.
- **`Theme.elevation.floating`** material, `pill` corner radius.
- **Auto-dismiss after 3.5s** of no further changes; tap dismisses immediately.
- **Stacks**: at most 3 visible; older toasts slide out.
- **Animation**: slide from top, `.gentle`.

### Banners

Persistent until acknowledged or resolved:

```
┌──────────────────────────────────────────────────────┐
│  ⚠  Claude is not installed. [Install]  [Dismiss]    │
└──────────────────────────────────────────────────────┘
```

- **Anchored top of conversation**, full-width.
- **`Theme.color.accent.warning`** tint for warnings, `Theme.color.accent.danger` for errors.
- **Two actions max**: primary action and dismiss.
- **No auto-dismiss**.

### Errors

Errors come in three flavours:

- **Toast** for transient, recoverable errors ("Voice recognition unavailable; retry?").
- **Banner** for persistent, blocking errors ("Workspace is not a Git repository").
- **Inline** within a bubble for errors specific to that bubble ("Tool failed: <details>").

The message format follows §1.12 — *what happened, why, what to do next.*

---

## 22. Feedback patterns: success, skeleton, rate-limit

When the user initiates something, they need to know it happened. When something is loading, they need to know it's coming. When something is rate-limited, they need to know what to do next.

### Success feedback decision tree

| Action | Feedback |
| --- | --- |
| Copy to clipboard | Inline button morph: icon swaps from `doc.on.doc` → `checkmark` for 1.2 s, then reverts. No toast. |
| Save / Apply settings | Inline button text changes to *Saved* for 1.2 s. Settings sheet stays open. |
| Send prompt | Composer field clears + new `UserBubble` slides into the conversation. No toast — the new bubble *is* the feedback. |
| Submit a paired-device PIN | Sheet replaces its content with a success state (*"Paired with Codemixer Mobile"*) then auto-dismisses in 1.5 s. |
| Export session | Toast with file path and `Show in Finder` action. |
| Revoke device pairing | Toast with `Undo` action visible for 5 s. |
| Engine command sent over remote API | No visible feedback at the API layer; the resulting `AgentEvent` is the receipt. |

**The rule of thumb:**

- If the action's *result* is itself visible (a new bubble, a new file in the diff list, a setting reflected immediately), no separate feedback is needed.
- If the result is *invisible* (export, copy, revoke), a toast surfaces the outcome.
- If the action is a *commit* of a longer flow (pairing, settings sheet), the surface itself transitions to a success state.

### Skeleton loaders

For content that takes more than ~200 ms to appear, skeleton placeholders preserve layout and tell the user *something is loading*.

- **Shape** — a `Theme.color.surface.sunken` rectangle with `Theme.shape.small` corner radius, matching the size of the content it replaces.
- **Animation** — a subtle horizontal gradient sweeps left-to-right at 1.4 s cycle (same cadence as `ShimmerDots`). Reduce-Motion → static `Theme.color.surface.sunken` fill.
- **Skeleton ≠ ShimmerDots.** `ShimmerDots` mean *the agent is working*; skeletons mean *we are loading known-shape content into a known layout*.

#### Where skeletons appear

| Surface | Skeleton |
| --- | --- |
| Session list (cold load from disk) | Three rows of skeleton rectangles visible |
| Conversation when reopening a long session | First page renders; skeleton fills the rest until JSONL parsing catches up |
| Diff panel hunks (large diff) | Skeleton block matching gutter + body shape |
| Bonjour device list (pairing) | Two skeleton rows while the listener spins up |

### Rate-limit and quota visuals

Codemixer surfaces are minimal — quota is shown only when it has consequence.

- **Engine-side rate limit** (Anthropic throttling) — banner above the composer: `Theme.color.accent.warning` tint, message *"Anthropic is rate-limiting. Retrying in 12 s…"* with a live countdown. Auto-dismisses on success.
- **PIN-attempt lockout** — pairing sheet replaces inputs with a centered countdown and `Try again in 4:32` text. No vibration, no flash — the wait *is* the affordance.
- **Daemon idle countdown** — never shown to the user; the daemon exits silently. Reconnect happens transparently when the GUI returns.
- **Auth quota exhausted** — auth gate sheet re-appears with the explanation in `body` type and an action button to open billing in the browser.

### Connection status pip

When the GUI runs against a daemon (loopback) or remote clients are connected, a small pip sits in the window toolbar:

| Pip | State |
| --- | --- |
| Green | Engine healthy; ≥ 0 clients. |
| Amber | Engine healthy; daemon temporarily unreachable (reconnecting). |
| Red | Engine reachable but reported `errored` state. |
| Grey | Disconnected. |

The pip is `Theme.shape.pill`, 8 pt × 8 pt, with a leading icon-only chip showing the client count. Click reveals a popover listing devices.

### Auto-save and persistence indicators

Codemixer is implicitly persistent — every event is appended to JSONL by the agent itself; there is no Save button to flash.

- **No spinner during background writes.** Disk I/O is silent unless it fails.
- **Write failure** — banner with `Theme.color.accent.danger` tint: *"Could not write transcript. Check disk space."* Persists until acknowledged.
- **No "saved at HH:MM"** affordance. The JSONL file's modification time in the Sessions popover is the source of truth.

### What we never show

- A green checkmark on every keystroke.
- "Synced!" badges.
- "Saving…" tickers — we have JSONL append, not REST PUTs.
- A spinner on the send button (the bubble is the response).
- Confirmation toasts for actions that are themselves visible (sending, opening a file in the diff list).

---

## 23. Permissions & approval surfaces

When the agent requests permission to run a command, the permission card appears as an inline bubble in the conversation:

```
┌── PermissionPromptView ──────────────────────────────────┐
│  ⛨  Permission requested                                  │
│                                                           │
│  Claude wants to run:                                     │
│                                                           │
│     git push origin main                                  │
│                                                           │
│  [ Allow once ]  [ Allow always ]  [ Decline ]            │
└───────────────────────────────────────────────────────────┘
```

### Rules

- **Wider than a regular bubble** — full conversation width.
- **`Theme.color.surface.bubble.system`** background with a 2pt `Theme.color.accent.warning` left border.
- **Buttons are equally weighted by default**, but if the command is destructive (`rm`, `git push --force`, `:1,$d` in editors), the Decline button becomes the recommended action and Allow buttons require an explicit hover.
- **Verbatim quote of the command** in `bodyMono` — never paraphrased.
- **No auto-dismiss, no auto-allow** — the user must choose.
- **Voice Control labels** make every button addressable ("Allow once", "Allow always", "Decline"). Voice users can say "Click Allow once."

### Auto-approval rules editor

A separate settings surface lets the user pre-approve patterns (e.g., "Allow `git status` always", "Decline any `rm -rf` automatically"). These edit the same underlying `PermissionPrefs` and never bypass the visible card — they pre-fill the choice and surface a "Auto-approved" caption.

---

## 24. Confirmation & destructive patterns

When a user is about to do something irreversible, the UI's job is to make the consequence visible *before* the action commits. Not to scold, not to over-warn — just to provide the right amount of friction.

### The modality decision tree

| Need | Modality | Example |
| --- | --- | --- |
| Confirm a destructive single action | Inline `Alert` | "Delete this turn?" |
| Approve a structured request with context | Inline `Card` in the conversation | Permission request (§23) |
| Inform the user transiently | `Toast` | *Copied path*, *Session saved* |
| Inform the user persistently until acknowledged | `Banner` | *Rate-limited. Retrying…* |
| Collect structured input | `Sheet` | Settings, Pairing |
| Reveal a complex set of options | `Popover` | Slash palette, Sessions popover |
| Surface a contextual menu | `.contextMenu` | Right-click on a bubble |

The rule of thumb: **the most disruptive modality wins only when the user's current task cannot continue.** A toast wins over an alert when the action is undoable; an alert wins over a toast only when the action is *not* undoable and the consequence is significant.

### Confirmation grammar

The confirmation button's label *names the action*, never `OK`:

- *Delete turn*
- *Revoke pairing*
- *Quit Codemixer*
- *Discard changes*

The cancel button is always literally `Cancel`. Never *No*, never *Nevermind*. Always last word.

### Button positioning

[macOS] Cancel on the left, primary (destructive or confirming) on the right. The destructive button uses `Theme.color.accent.danger` foreground on `Theme.color.surface.raised`.

[iOS / iPadOS] Cancel on the left in row layouts, but a destructive action in a sheet uses the system standard — top-right or full-width at bottom.

### Default focus

- **Non-destructive confirms** — primary action is default (`Theme.color.accent.focusRing` on focus). Enter commits.
- **Destructive confirms** — *Cancel* is default. Enter cancels. The user must explicitly mouse, voice-target, or arrow-key to the destructive button.
- **No "Don't ask again" checkboxes.** They create a class of users for whom the confirmation is silently disabled, which is worse than no confirmation at all. If a confirmation is annoying, the underlying flow needs redesign.

### Undo affordances

Destructive actions that are *recoverable in software* (delete turn, revoke pairing within the lockout window, dismiss session from the picker) get an inline `Undo` action on the success toast for 5 seconds.

```
┌────────────────────────────────────────────┐
│  Turn deleted.                 [ Undo ]    │
└────────────────────────────────────────────┘
```

After 5 seconds the toast slides out and the action becomes permanent. No second confirmation; the implicit deadline is the contract.

Actions that are *not* recoverable (overwrite a file, send a paired device a destructive command remotely) skip the toast Undo and use a hard confirmation alert.

### Multi-step destructive flows

For high-stakes destructive flows (Revoke all paired devices, Reset all preferences, Sign out and clear local data), the pattern is:

1. Tap the destructive action — opens a **sheet**, not an alert. The sheet describes the consequence in plain language.
2. Type a confirmation word — the user must type the literal word `revoke` (or `reset`) into a text field. The destructive button is disabled until match.
3. Tap the destructive button.
4. Toast confirms the action — no undo.

This pattern is reserved for ≤ 3 places in the app — overusing it is hostile.

### What we never do

- **Modal alerts for non-destructive information.** Use a toast or banner.
- **Confirmations on every save** — settings persist on row blur without confirmation.
- **Three-button alerts** (*Save / Don't Save / Cancel*) — break into two alerts or a sheet with a button row.
- **Destructive actions as the default.** Cancel is the default.
- **Confirmations on the first attempt of an undoable action** — undoable means the undo *is* the confirmation.

---

## 25. Voice, mic, and TTS surfaces

Codemixer treats voice as a peer input, not an accessibility afterthought.

### Mic button

Covered in §16. Always visible in the composer toolbar.

### Inline-prompt mic

Inline prompts (§18) carry their own mic button — when the agent asks "should I run X?", a quick spoken "yes" works the same as typing.

### Dictation overlay

While recording, a thin band appears at the top of the composer field:

```
┌──────────────────────────────────────────────────┐
│  🎤  Listening…                       [✕ cancel] │
└──────────────────────────────────────────────────┘
```

- **`Theme.color.accent.danger` 2pt left border** to signal "live recording".
- **Real-time partial transcription** shown in the band as the user speaks, in `caption` `text.secondary`.
- **Submitting** (Enter or saying "submit") commits the transcription into the field.

### TTS playback

Every AssistantBubble has a "Read Aloud" affordance:

- **IntentReveal-revealed speaker button** at the top-right of the bubble.
- **Clicking starts playback** of the bubble's text. The button changes to a pause icon.
- **Global TTS toggle** in settings — when on, new assistant bubbles auto-read.
- **Voice and rate** configurable in settings.

### Voice Control compatibility

Every interactive element in Codemixer has a `.accessibilityLabel` that matches its visible label (or describes the icon). Voice Control users can address every button by name:

- "Click Send"
- "Click Allow once"
- "Click /think"
- "Show numbers" — Voice Control overlays numbers on every actionable region

The numbered overlay is honoured natively because we use SwiftUI controls; no custom accessibility wiring is needed beyond labels.

---

## 26. Form & settings design

Codemixer's settings sheet is the only deeply form-heavy surface in the app. Forms in remote-control attachments (Pairing PIN, Add Device, About) follow the same rules.

### Row anatomy

A settings row is the atomic unit:

```
┌────────────────────────────────────────────────────────────────────────┐
│  Label                                              [Control]          │
│  Helper text in caption, text.secondary.                               │
└────────────────────────────────────────────────────────────────────────┘
```

- **Label** in `Theme.font.body`, `Theme.color.text.primary`, leading-aligned.
- **Control** trailing-aligned. Toggle, picker, button, text field, slider, etc.
- **Helper text** in `Theme.font.caption`, `Theme.color.text.secondary`, indented to align with the label's leading edge, max 2 lines.
- **Row padding** — `Theme.spacing.s12` vertical, `Theme.spacing.s16` horizontal.

### Section grouping

Settings cluster into named sections, separated by `Theme.spacing.s32` vertical space.

```
┌────────────────────────────────────────┐
│  Appearance                            │  ← section title
│                                        │
│  Theme               [ Auto ▾ ]         │
│  Show usage chip     [ ○ ]              │
│  Always show controls [ ○ ]             │
│                                        │
│  ────────────────────────────          │
│                                        │
│  Voice                                 │
│  …                                     │
└────────────────────────────────────────┘
```

- **Section title** in `Theme.font.headline`, `Theme.color.text.primary`, no decoration, with `Theme.spacing.s24` below it.
- **Section divider** — none by default; whitespace separates. The exception is when section count exceeds 6, in which case a 1 pt `Theme.color.border.hairline` rule appears between sections.

### Field types vocabulary

- **Toggle** — Apple system style. Single label leading, control trailing.
- **Picker** — system menu picker (`Picker(..., selection:)`); shows the selected value with a chevron.
- **Stepper** — for bounded numerics (heartbeat interval, page size).
- **Slider** — for ranged numerics with a sensible default; always paired with a numeric readout aligned trailing.
- **Text field** — for free-form input, with `Theme.color.border.hairline` 1 pt outline and a focus ring on focus.
- **Regex field** — text field with a live-validity indicator (green check or red exclamation) in the trailing position.
- **Segmented control** — for ≤ 4 mutually exclusive options where each label is short. More than 4 → picker.
- **Radio group** — for > 4 mutually exclusive options where each needs explanation; one row per option with the radio leading.
- **Multi-select list** — `EditMode`-driven with row-trailing checkmarks; reorderable via leading grip.

### Validation visuals

- **At rest** — no decoration. The user is exploring.
- **Live invalid** — when content is currently invalid, the field's border becomes `Theme.color.accent.danger` and helper text turns danger-tinted. No icon flash; just the persistent state.
- **Live valid** — when a previously-invalid field becomes valid, the border returns to `Theme.color.border.hairline` and helper text returns to normal in `quick` (120 ms).
- **Submit-disabled state** — the primary action button is disabled (low opacity, no hover) until every required field is valid. Tooltip on the disabled button names the first invalid field: *"Fix the regex to enable."*

### Loading and submitting buttons

- **At rest** — `Theme.font.body` label, `Theme.color.accent.agent` background, `Theme.color.text.onAccent` foreground.
- **Submitting** — label is replaced by `ShimmerDots` (no spinner — same activity primitive as everywhere else); button is non-tappable but visually unchanged in size and shape.
- **Succeeded** — label momentarily becomes `Theme.icon.success` for 1.2 s, then returns to its original label or the surface dismisses.
- **Failed** — label returns; an inline error message in `Theme.color.accent.danger` appears below the button.

### Disabled state

- **Disabled button** — 40 % opacity, no hover affordance, cursor stays `default` (not `pointingHand`).
- **Disabled field** — same opacity; the user can still focus to read the value but cannot type.
- **Disabled toggle** — system style.

### Specific Codemixer settings screens

| Sheet | Sections |
| --- | --- |
| **Appearance** | Theme picker, density picker, auto-detect-density toggle, *Show usage chip*, *Always show controls*, *Show timestamps* |
| **Voice** | Recognition locale, mic confidence threshold slider, *Send on long-press* toggle, TTS auto-speak toggle, voice picker, rate slider |
| **Permissions** | Auto-approval rules list (reorderable, per-rule editor), headless timeout slider, default permission mode picker |
| **Remote** | Enable remote access toggle, Allow LAN toggle, Enable on login toggle, *Pair new device* button, Paired devices list, headless permission timeout |
| **About** | Version, build, link to docs, link to release notes |

Each sheet uses **two columns** at default density (≥ 720 pt width) and **single column** in `compact` density. Submit always commits silently — there is no global Save button; rows commit on blur or value-change.

### Settings keyboard rhythm

- **Tab** moves focus down the rows.
- **Shift-Tab** moves up.
- **Cmd-W** closes the sheet (settings persist regardless).
- **Cmd-.** cancels any in-flight regex / PIN validation without committing.

---

## 27. Accessibility

Accessibility is the design (§1.9). The concrete rules:

### Required attributes

- **`accessibilityLabel`** on every icon-only button. CI greps for missing.
- **`accessibilityHint`** on non-obvious actions ("Sends the message and starts a new turn").
- **`accessibilityElement(children: .combine)`** on composite views like bubbles, so VoiceOver hears one element.
- **`accessibilityAddTraits(.isButton)`** on tappable non-button views.
- **`accessibilityValue`** on toggles and sliders.
- **`accessibilitySortPriority`** on overlapping floating surfaces (e.g., search overlay).

### Focus order

- **Top → bottom, leading → trailing.**
- **Toolbar → conversation → composer**, in that reading order.
- **Inline prompts** take focus when they appear.

### Hit targets

- **Minimum 44pt × 44pt** on touch surfaces [iOS / iPadOS].
- **Minimum 24pt × 24pt** on mouse-driven surfaces [macOS], with `.contentShape` padded to 28pt for hover affordance.

### Contrast

- **Body text: WCAG AA — 4.5:1** against its background.
- **Large text (≥18pt or ≥14pt bold): WCAG AA — 3:1**.
- **CI runs `scripts/check-contrast.sh`** on every color-pair in `Theme`.

### Reduced motion

Covered in §9.

### Reduced transparency

When `accessibilityReduceTransparency` is true, materials become solid. The `Theme.color.surface.floating` token resolves to a solid color rather than `.ultraThinMaterial`. The runtime handles this automatically because we use semantic SwiftUI Material values.

### High contrast

When `accessibilityDifferentiateWithoutColor` (or platform-equivalent) is set:

- **Diff additions and deletions** get glyph indicators (`+` and `−`) in addition to color.
- **Status colors** carry icons (success ✓, warning ⚠, danger ⊘).
- **Focused elements** add a thicker outline.

---

## 28. Dark mode parity

Every surface, every component, every screenshot is designed in light and dark in parallel.

### Workflow

- Define colors with light and dark variants in `Assets.xcassets`.
- Every `#Preview` declares both:

  ```swift
  #Preview("Light") { AssistantBubbleView(...).preferredColorScheme(.light) }
  #Preview("Dark")  { AssistantBubbleView(...).preferredColorScheme(.dark)  }
  ```

- A PR that touches visuals attaches *both* screenshots in the description.

### Don'ts

- No "dark mode" branching in code. The system resolves the asset.
- No inverted-luminance colors for dark mode — defining `accent.warning` dark as the literal RGB inversion of light is almost always wrong; calibrate by eye.
- No different shadow opacities for dark mode unless the elevation level demands it.

---

## 29. Density, scaling, and Dynamic Type

### Density classes

Three named classes, applied via `Theme.density`:

| Class         | When                                     | Effect                                                       |
| ---           | ---                                      | ---                                                          |
| `comfortable` | Default macOS, wide windows              | `s24` content insets, `s12` intra-card spacing                |
| `compact`     | Narrow macOS windows, iPad split view    | `s16` content insets, `s8` intra-card spacing                 |
| `tactile`     | Touch surfaces, larger hit targets       | `s16` content insets, `s12` intra-card spacing, 44pt targets  |

Density is read from `@Environment(\.codemixerDensity)`, which the root view sets based on window size and platform.

### Dynamic Type

Covered in §6. Every type role scales; physical sizes (pixel measurements, signpost lines) are computed from the resolved font metrics.

### Window scaling

[macOS] When the user drags the window narrower than 720pt, density auto-shifts to `compact`. Below 480pt the diff panel auto-collapses.

[iOS / iPadOS] iPad split view triggers `compact` when the window is below 600pt. Phone-style narrow widths always use `tactile`.

---

## 30. Formatting reference

Numbers, durations, dates, costs, file sizes — Codemixer renders all of these in many places. The rules below cover every case so a designer never has to invent a format on the fly.

### Numbers

- **Token counts** — `12,000 tok` at default density, `12k tok` when space-constrained (composer chip, status pill). Use `NumberFormatter.localizedString(from:number:.decimal)`; the `tok` suffix is a separate `caption` chip beside the number.
- **Large counts (events, messages, files)** — full thousand-separators (`12,400 events`). Never `12.4k` outside chips.
- **Percentages** — one decimal place when < 10 %, none when ≥ 10 % (`3.5 %` vs `42 %`). `localizedString(from:number:.percent)`.
- **Decimal separator** is locale-driven. We never hard-code `.`.

### Durations

| Duration | Display | Notes |
| --- | --- | --- |
| < 1 ms | `< 1 ms` | Below this resolution we round to 1 ms. |
| 1 ms – 999 ms | `240 ms` | No decimal. |
| 1 s – 9.9 s | `1.2 s` | One decimal. |
| 10 s – 59 s | `45 s` | No decimal. |
| 1 min – 59 min | `12 min` | No decimal. |
| ≥ 1 h | `2 h 14 min` | Always pair hours with minutes. |

`Duration.formatted(.units(allowed:, width: .narrow))` covers most of these. The `noEventGap` ticker uses these labels verbatim.

### Dates

| When | Display |
| --- | --- |
| Today | `Today at 2:14 PM` |
| Yesterday | `Yesterday at 2:14 PM` |
| This week | `Tuesday at 2:14 PM` |
| This year | `Mar 14 at 2:14 PM` |
| Older | `Mar 14 2024` |

Use `Date.RelativeFormatStyle()` for *relative* phrases ("3 min ago") and `Date.FormatStyle()` for absolute phrases. Locale-aware throughout.

Relative phrasing rules:

- **< 30 s** → `just now`
- **30 s – 60 s** → `under a minute ago`
- **1 m – 60 m** → `3 min ago`
- **1 h – 24 h** → `2 h ago`
- **> 24 h** → switch to absolute (`Yesterday at 2:14 PM` / `Mar 14 at 2:14 PM`).

### Costs

- **USD** — `$0.0245` to four decimal places when < $1.00, `$0.45` when < $10.00, `$1.20` when ≥ $1.00. Trailing zero is preserved.
- **Locale currency** — `Number.formatted(.currency(code: "USD"))` resolves localised symbols.
- **Daily / session aggregates** — full precision; never round to `$0` for non-zero usage.
- **Per-token cost** — never shown; users care about totals.

### File sizes

`ByteCountFormatter` with `.countStyle = .file`:

| Range | Display |
| --- | --- |
| 0 – 999 B | `240 B` |
| 1 KB – 999 KB | `4.5 KB` (one decimal at < 100 KB, none above) |
| 1 MB – 999 MB | `12 MB` |
| 1 GB+ | `1.2 GB` |

PTY byte throughput (in tool renderers) uses `.binary` style: `4.0 KiB/s`. Disk file sizes use `.file` style: `4.5 KB`. The two are different by convention, and Codemixer respects the distinction.

### Locale rules

- **Currency symbol** follows the user's region setting, even when the price is USD (`USD 12.50` is the right rendering in regions that prefer code + amount).
- **Decimal separator** is `Locale.current.decimalSeparator`.
- **Thousand separator** is `Locale.current.groupingSeparator`.
- **First day of week** follows `Calendar.current.firstWeekday`.
- **Hour cycle** follows `Locale.current.hourCycle` — never hard-code 12-hour or 24-hour.
- **Negative numbers** — `-12,400` (leading minus, locale-formatted). Never parenthesised accounting style for free-form numbers.

### Numerals

- **Western Arabic numerals** (`0 1 2 3 4 5 6 7 8 9`) are used in code blocks regardless of locale — code is universal.
- **Localised numerals** (`٠١٢٣٤٥٦٧٨٩` for Arabic locales) are honoured in prose, dates, and counts.

### Bidirectional content

- **Prose** flows in the user's writing direction (`.environment(\.layoutDirection)` is honoured throughout — we never hard-code `.leftToRight`).
- **Mixed-direction** segments (English code inside Arabic prose) use the Unicode bidi algorithm naturally; we never inject explicit bidi marks.
- **Code blocks** are always LTR — we wrap them in `.environment(\.layoutDirection, .leftToRight)` regardless of the surrounding direction.

### Negative space in numbers

Numbers in lists are **right-aligned** when comparable (cost per session, file sizes in the diff list, token counts) so the eye can scan magnitudes. Numbers in prose are left-aligned with the surrounding text.

---

## 31. Window chrome and platform shell

### [macOS] Window toolbar

```
┌─────────────────────────────────────────────────────────────┐
│  🟠🟡🟢   <session title>            [⊕ new]  [⌗ diff]  [⊙]  │
└─────────────────────────────────────────────────────────────┘
```

- **Toolbar style**: `.unifiedCompact` — flush with the title bar.
- **Title**: session name in `headline`. Renaming is inline by clicking the title.
- **Trailing controls**: New session, diff toggle, settings menu. Maximum 4 items; more goes into a `more` menu.
- **No back / forward arrows.** Codemixer is not a browser.

### [macOS] Menu bar

Standard `App` menu with these Codemixer additions:

- **File**: New Session (`cmd+N`), Open Session (`cmd+O`), Export Conversation, Quit.
- **Edit**: standard.
- **View**: Toggle Diff (`cmd+D`), Show Statistics (`cmd+I`), Increase / Decrease Text Size.
- **Commands**: each slash command appears here with its shortcut — voice users and keyboard users get a discoverable list.
- **Window**: standard.
- **Help**: Documentation, About Codemixer.

### [macOS] Menu bar extra

An optional menu bar item (`MenuBarExtra` in SwiftUI) shows a Codemixer glyph that:

- Indicates daemon state (idle / busy / disconnected).
- Lets the user open the main window or pause the daemon.
- Right-click reveals the settings.

### [Roadmap: iOS / iPadOS] Navigation

Not shipped. When a mobile remote client exists, it would reflow the same regions into a single column (navigator slide-over, diff in a sheet).

- **Single window**, navigation via `NavigationStack` for settings and sessions.
- **Conversation occupies the main view.**
- **Diff accessible via a swipe-from-trailing-edge or tab bar entry.**
- **Composer pinned bottom**, with a keyboard accessory row for slash commands.

---

## 32. Multi-window, sound, and haptics

A handful of platform-peripheral behaviours that don't fit elsewhere.

### Multi-window [macOS]

Codemixer supports multiple workspace windows simultaneously — one per active project.

- **`⌘N`** opens a new workspace window with the project picker.
- **`⌘⇧T`** restores the most recently closed window.
- **`⌘\``** cycles between open Codemixer windows.

#### Active vs inactive window appearance

When a Codemixer window loses focus, native AppKit handles the chrome (traffic lights dim, toolbar saturation drops). We layer on:

- **Composer focus ring** removes its `Theme.color.accent.focusRing` outline.
- **`StatusPill` saturation** drops to 60 % so the active window's status reads more strongly when multiple windows are visible.
- **`ShimmerDots`** continue to animate in the inactive window (the agent is still working); other inert chrome dims.
- **Diff panel selection** is unchanged; the user's last selection should survive a focus change.

#### Window restoration [macOS]

When the app launches after a system restart with state restoration enabled:

- Last conversation reloads from JSONL — `Theme.color.surface.sunken` skeleton fills the conversation column while parsing (typically < 200 ms for sessions under 10 MB).
- Diff panel state restores closed by default; if it was open, it restores open with its prior file selection.
- Composer field text *does not* restore — the half-typed prompt is discarded to avoid double-sends.

### Sound

Codemixer uses **system sounds exclusively**. No custom audio. The vocabulary:

| Event | Sound | When |
| --- | --- | --- |
| Bell (`0x07` from PTY) | `NSSound(named: "Funk")` | Agent emits a terminal bell. |
| Permission required | `NSSound(named: "Pop")` | Inline permission card appears. Suppressed if window is focused. |
| Pairing succeeded | `NSSound(named: "Glass")` | New device paired. |
| Connection lost | `NSSound(named: "Bottle")` | Daemon or remote client disconnects unexpectedly. |
| Destructive action confirmed | — | Visual feedback is enough. |
| Success toast | — | Silence. |

Rules:

- **Sounds only fire when the window is unfocused.** Active-window operations are visual-only.
- **Sound respects the system "Play sound on alert" setting.** When off, all sounds skip; we never override.
- **No looping sounds.** Each sound plays once.
- **TTS audio** (§25) is governed by `AVSpeechSynthesizer`; it is not part of this vocabulary.

### Haptics [macOS]

macOS trackpads support haptic feedback through `NSHapticFeedbackManager`. Codemixer uses three patterns:

| Pattern | When |
| --- | --- |
| `.alignment` | The composer-mic long-press threshold is reached (400 ms). A single soft pulse. |
| `.levelChange` | A drag-and-drop snaps into a valid drop target. A single firm pulse. |
| `.generic` | A multi-step destructive confirmation step commits. A single neutral pulse. |

Haptic rules:

- **Haptics only fire when the trackpad is the active input device.** Mouse users get no haptics — the system handles this automatically.
- **Haptics never replace visual feedback.** Every haptic event is paired with a visible state change.
- **System haptic preferences are honoured** — when haptics are disabled in System Settings, all `performFeedback` calls are no-ops by design.

### [Roadmap: iOS / iPadOS / visionOS] Haptics

Not shipped. A future mobile client could map the same feedback vocabulary to `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator`.

visionOS adds spatial-audio rules (volume per-window, depth-attenuated bell sounds). Out of scope for v1 / v1.1.

---

## 33. Onboarding, empty states, and first-run

### First launch

When Codemixer starts and has never seen this user:

- A single, centered card asks the one essential question: *which folder?*
- A subtle illustration (line-art, no color) hints at the conversation that's about to begin.
- A "Get started" button — primary action — opens a folder picker.
- A "Learn more" link — secondary action — opens the documentation in a sheet.

No multi-step onboarding tour. No "Tap here, now tap there." If the user needs more, they ask.

### Empty conversation

```
                                                
                                                
              "Type a message, or               
               press the microphone."           
                                                
                                                
              [@ mic ] [@ slash ]               
                                                
                                                
```

- **`display` type** for the suggestion.
- **`s48` vertical padding**.
- **Two affordances visible**: mic and slash. Everything else is hidden.
- **No animated illustration.**

### Empty diff panel

A single `caption` line, `text.tertiary`: *"No changes since last commit."* Nothing else.

### Empty search results

*"No matches for `xyz`."* in `caption`, with a "Search all sessions" link in `body` `accent.agent`.

### Empty session list

*"No prior sessions. Start a new one."* with a "New Session" button.

---

## 34. Remote control & pairing surfaces

The daemon mode of Codemixer is controlled by the GUI via the same WebSocket protocol that a remote mobile client uses. The pairing flow is the visual representation of that handshake.

### Pairing card

When a new client requests pairing:

```
┌── PairingPrompt ─────────────────────────────────────┐
│  📱  New device requesting access                     │
│                                                       │
│  Codemixer Mobile · Alice's iPhone                    │
│                                                       │
│  Enter the PIN shown on this device:                  │
│                                                       │
│     ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐               │
│     │ 4 │ │ 1 │ │ 9 │ │ _ │ │ _ │ │ _ │               │
│     └───┘ └───┘ └───┘ └───┘ └───┘ └───┘               │
│                                                       │
│  [ Cancel ]                          [ Pair ]         │
└───────────────────────────────────────────────────────┘
```

- **Centered modal sheet** on the engine-side GUI.
- **Device name and platform** verbatim from the request.
- **6-digit PIN field**, large `display` numbers in mono.
- **Rate-limited**: 5 wrong attempts locks out for 5 minutes (visible countdown).
- **Cancel is destructive-tinted only when wrong PIN entered**; otherwise neutral.

### Pairing QR code

For the smoothest pairing, the GUI shows a QR code containing the engine's hostname, port, TLS fingerprint, and the PIN:

```
  ┌─────────────────────┐
  │   ▓▓ ▓▓▓ ▓▓ ▓ ▓▓    │
  │   ▓ ▓▓  ▓▓ ▓▓▓ ▓    │
  │   ▓▓▓ ▓ ▓▓ ▓▓ ▓▓    │
  │   …                 │
  └─────────────────────┘
```

- **Centered in the pairing card**, replaces the PIN entry on tap.
- **Animation**: cross-fade between PIN and QR.

### Connected clients indicator

Once paired, a small chip in the window toolbar shows connected clients:

```
[● 1 client]
```

- **Green dot** when connected.
- **Click reveals a popover** listing devices and a "Revoke access" action for each.

### Remote client mirror

When the GUI runs against a daemon (loopback WebSocket) or when a remote client connects, the conversation surface looks identical. The same visual language applies. The only difference is a small `caption` line in the window toolbar: *"Connected to Codemixer daemon · localhost"* or *"Connected to Codemixer · 192.168.1.5"*.

---

## 35. Visual review checklist

Every reviewer of a UI pull request reads these questions aloud (literally, in their head) before approving:

1. **At rest, does the surface look quiet?** If the at-rest state shows more than 3 affordances per primary region, the design is too dense.
2. **Are every padding, color, font, radius, shadow, and motion duration drawn from `Theme`?** A grep for `Color.` / `.padding(N)` / `.font(.system(size:` / `.cornerRadius(` / `.shadow(radius:` in the diff returns zero hits.
3. **Does every interactive element have an `.accessibilityLabel`?** Especially icon-only buttons.
4. **Does the view's `#Preview` declare both light and dark?**
5. **Does every animation have a `value:` parameter?** No floating `.animation(...)` modifiers.
6. **Does every animated surface honour `accessibilityReduceMotion`?**
7. **Does the view break the "one padding, one background, one clipShape" rule?**
8. **Is type hierarchy carried by weight and size, not by lines and boxes?**
9. **Is every revealed affordance also reachable by Voice Control and keyboard?**
10. **Does the view degrade gracefully at compact density?** Open the preview at 480pt and look.
11. **Does the view degrade gracefully at large Dynamic Type?** Open the preview at `.accessibilityExtraExtraLarge`.
12. **Would you ship this in two years and feel proud?** If not, it's not done.

A "no" to any of these is grounds for refusal. The reviewer's job is not to find pixel-misalignments; CI finds those. The reviewer's job is to ask whether this view earns its place in a product meant to feel serene.

---

## 36. Don'ts — the no-go list

The shortcut list of forbidden moves. CI catches some; reviewers catch the rest.

- No animated gradients.
- No parallax.
- No "shine" or "shimmer" effects on text.
- No drop caps.
- No multi-color shadows.
- No gradient backgrounds outside the launch screen.
- No glyph spinners — we have `ShimmerDots` and `StatusPill`.
- No system progress bars except in the genuine progress case (large file uploads). For activity, use `ShimmerDots`.
- No `Color.red` (or any literal color) outside `Theme.swift`.
- No magic spacing literals outside `Theme.swift`.
- No fixed-size frames on text (`.frame(width: 200)`) — text computes its own width or fills.
- No emoji as UI icons.
- No italic body text.
- No underline as decoration.
- No banners that auto-dismiss.
- No modal alerts for non-blocking information (use toasts).
- No "Ok" button. The action button names the action.
- No nested scrollviews unless absolutely necessary (and never two with the same axis).
- No autoplay video, audio, or motion.
- No tooltips on touch surfaces — they don't translate.

---

## 37. Tooling & enforcement

Visual rules are enforced where possible by automated tooling; the rest are reviewed by eye.

### SwiftLint custom rules (in `.swiftlint.yml`)

- `theme_color_only` — reject `Color.*` outside `Theme.swift`.
- `theme_spacing_only` — reject `.padding(N)` with numeric literal outside `Theme.swift`.
- `theme_font_only` — reject `.font(.system(...))` outside `Theme.swift`.
- `theme_shape_only` — reject `.cornerRadius(N)` outside `Theme.swift`.
- `theme_shadow_only` — reject `.shadow(radius:` outside `Theme.swift`.
- `accessibility_label_required` — match `Button { Image(systemName: "...") }` without `.accessibilityLabel`.
- `animation_value_required` — match `.animation(.<curve>)` without a `value:` parameter.
- `preview_required` — every public View must declare at least one `#Preview`.

### Scripts

- `scripts/check-contrast.sh` — iterates `Theme.color.*` pairs, computes WCAG ratios, fails CI on < 4.5:1 for body / < 3:1 for large.
- `scripts/check-a11y.swift` — scans SwiftUI files for icon-only buttons without `accessibilityLabel`.
- `scripts/check-theme-coverage.sh` — verifies every color in `Assets.xcassets` is referenced from `Theme.swift` and vice versa.

### CI gates

- **Build** — preview-compile every `#Preview` in the package (catches "preview crash on appear" before merge).
- **Lint** — SwiftLint with the rules above, errors-as-errors.
- **Visual tests** (optional, post-v1) — snapshot tests comparing to baselines; ≥0.1% pixel diff triggers a review comment with the rendered before/after.

### Design source files

Codemixer does not maintain Figma artboards as source of truth. The source is the code: `Theme.swift`, the `#Preview`s, and this document. We sketch in Figma; we ship from SwiftUI.

### CODEOWNERS

`docs/style/visual-style.md`, `Theme.swift`, `Assets.xcassets`, and `src/AgentUI/**` carry a visually-conscious code-owner who reviews changes.

---

## 38. Glossary

Terms used throughout this document.

- **At rest** — the visual state of a surface with no user intent expressed (no hover, no focus, no active interaction).
- **Bubble** — a conversation message surface. Four kinds: user, assistant, tool, system.
- **Committed** — the third intent state; the user has selected the surface (right-click, modal open, search active).
- **Density class** — one of `comfortable`, `compact`, `tactile`. Controls spacing, hit targets, and chrome compression.
- **Elevation** — one of three levels: base (window), raised (cards), floating (popovers/toasts). Each carries its own surface color, material, and shadow.
- **Hairline** — a 1pt border in `Theme.color.border.hairline`. Used between regions, never to box content.
- **Hunk** — in the diff panel, one contiguous block of changes in a file.
- **Intent state** — `atRest`, `intent`, or `committed`. Drives the `IntentReveal` modifier.
- **`IntentReveal`** — the SwiftUI modifier governing "hidden by default, visible on intent" behaviour for secondary actions.
- **Lasagna** — the SwiftUI anti-pattern of stacking `.padding().background().padding().background()` — forbidden.
- **Loopback** — the WebSocket connection from the GUI window to a daemon-mode engine on `127.0.0.1`.
- **Pairing PIN** — the 6-digit code used to authenticate a remote client on first connection.
- **`PermissionPromptView`** — the inline bubble that presents a permission request from the agent.
- **ShimmerDots** — three breathing dots indicating "still working" — the smallest activity primitive.
- **Slash palette** — the floating popover triggered by `/` in the composer; lists agent commands.
- **StatusPill** — the pinned pill at the top of the conversation showing the current high-priority activity phrase.
- **Surface** — any visual region with its own background color or material. Bubbles, cards, panels, popovers, toasts.
- **Tactile** — the touch-optimised density class; larger hit targets, slightly more spacing.
- **Theme** — the typed registry of all visual tokens (color, font, spacing, shape, elevation, motion, icon, density).
- **ThinkingBlock** — the collapsible block surfacing structured reasoning from `/think` mode.
- **Ticker** — short factual line beneath the StatusPill describing what just happened ("Read X.swift").
- **Turn** — one user message + the assistant's complete response (potentially many bubbles).

---

## 39. When in doubt

- Read `AssistantBubbleView.swift`.
- Ask: *what would the calmest version of this look like?*
- Ask: *could I delete a visual element and lose nothing?*
- Ask: *is this color, this padding, this animation pulling its weight?*
- Ask: *what will the next reviewer see when they open this in two years?*

**Loud is the enemy. Quiet is the goal.**

---

*Last revised alongside [docs/architecture.md](../architecture.md) and [docs/style/code-style.md](code-style.md). When this file and `code-style.md` disagree, `code-style.md` wins on how code reads; this file wins on how the product looks. To propose changes, follow the same process as `code-style.md` §29.*
