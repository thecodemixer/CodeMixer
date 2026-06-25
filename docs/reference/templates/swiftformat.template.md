<!--
SwiftFormat configuration template.

Copy the block below to `.swiftformat` at repo root.
SwiftFormat reads it automatically (no flag needed).
This config matches the conventions in `docs/code-style.md`.
-->

# SwiftFormat configuration

A reference `.swiftformat` for projects following [`docs/code-style.md`](../code-style.md).

Copy this content to `.swiftformat` at repo root:

```
# ─── Swift version target ───────────────────────────────────────────────────
--swiftversion 6.2

# ─── Files included / excluded ──────────────────────────────────────────────
--exclude .build,Build,Vendored,**/*.generated.swift,**/Pods

# ─── Indentation and whitespace ─────────────────────────────────────────────
--indent 4
--smarttabs disabled
--trimwhitespace always
--linebreaks lf
--ifdef no-indent
--commas inline
--guardelse same-line

# ─── Wrapping ───────────────────────────────────────────────────────────────
--maxwidth 120
--wraparguments before-first
--wrapparameters before-first
--wrapcollections before-first
--wrapconditions before-first
--wrapreturntype if-multiline
--wraptypealiases before-first
--closingparen balanced
--wrapternary default

# ─── Numeric literals ───────────────────────────────────────────────────────
--decimalgrouping 3,6
--hexgrouping 4,8
--octalgrouping 4,8
--binarygrouping 4,8
--exponentcase lowercase
--hexliteralcase uppercase

# ─── Headers ────────────────────────────────────────────────────────────────
# Set per-project; remove the rule if you don't enforce headers.
--header ignore

# ─── Self ───────────────────────────────────────────────────────────────────
--self init-only
--selfrequired @autoclosure

# ─── Empty lines ────────────────────────────────────────────────────────────
--emptybraces no-space
--funcattributes prev-line
--typeattributes prev-line
--varattributes preserve
--lineaftermarks true

# ─── Sorting and organising ─────────────────────────────────────────────────
--sortedimports enabled
--importgrouping testable-bottom
--organizetypes class,actor,enum,struct
--marktypes always
--markextensions always
--extensionacl on-declarations

# ─── Modernisation ──────────────────────────────────────────────────────────
--patternlet inline
--shortoptionals always
--ranges no-space

# ─── Redundancy removal ─────────────────────────────────────────────────────
--redundanttype inferred
--stripunusedargs closure-only

# ─── Rules ──────────────────────────────────────────────────────────────────
# Enable strict rules beyond defaults.
--enable acronyms
--enable blankLinesBetweenImports
--enable blankLineAfterImports
--enable blockComments
--enable docComments
--enable isEmpty
--enable markTypes
--enable noExplicitOwnership
--enable organizeDeclarations
--enable preferKeyPath
--enable propertyType
--enable redundantNilInit
--enable sortDeclarations
--enable sortTypealiases
--enable wrapConditionalBodies
--enable wrapMultilineStatementBraces
--enable wrapSwitchCases

# Explicitly disable rules we don't want.
--disable andOperator
--disable redundantSelf
--disable unusedArguments
```

## Notes

- **`--swiftversion 6.2`** unlocks the latest formatting rules (e.g., `@MainActor` placement).
- **`--maxwidth 120`** is our convention. 80 is too cramped for SwiftUI; 140 lets people sneak through long lines.
- **`--wraparguments before-first`** is the modern style: open paren stays on the call line, each argument indented one level on its own line.
- **`--indent 4` spaces, not tabs.** Period. Mixed indentation in Swift is a war we're not having.
- **`--header ignore`** — set explicit headers in projects that require them (open-source attribution, license text); leave alone otherwise.
- **`--selfrequired @autoclosure`** — `self.` only appears in initialisers and inside `@autoclosure` parameters (where Swift demands it).
- **`--marktypes always`** + **`--markextensions always`** — every type and extension gets a `// MARK:` separator. Reviewers can navigate.
- **`--organizedeclarations`** is intentionally *off* (no `--enable organizeDeclarations` toggle in conjunction with manual review). Auto-reordering of declarations is too aggressive and conflicts with the documentation order. If you want it on, also turn off `// MARK:` enforcement.

## Pre-commit hook

```bash
# .git/hooks/pre-commit (installed via `make install-hooks`)
#!/usr/bin/env bash
set -e
files_to_format=$(git diff --cached --name-only --diff-filter=ACM | grep '\.swift$' || true)
if [ -z "$files_to_format" ]; then exit 0; fi
echo "$files_to_format" | xargs swiftformat
echo "$files_to_format" | xargs git add
```

This auto-formats staged Swift files and re-stages them. See [`pre-commit.template.md`](pre-commit.template.md) for the integrated hook script.

## CI enforcement

In CI we run `swiftformat --lint .` (check-only). Failure means a file was committed that doesn't match. See [`ci-workflow.template.md`](ci-workflow.template.md).
