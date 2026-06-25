<!--
Pre-commit hook template.

Two installation paths:
  1. Plain Git hook (`.git/hooks/pre-commit`) — works for any clone.
  2. Husky or pre-commit framework — works in monorepos with shared hooks.

We document the plain Git approach below since it's tool-free. Adapt as needed.
-->

# Pre-commit hook

A reference pre-commit hook that formats, lints, and runs fast checks on staged Swift files before a commit lands. Aligns with [`swiftformat.template.md`](swiftformat.template.md) and [`swiftlint.template.md`](swiftlint.template.md).

## Installation

Install once per clone:

```bash
make install-hooks
```

Where `install-hooks` in the `Makefile` is:

```makefile
install-hooks:
	@cp scripts/hooks/pre-commit .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "✓ pre-commit hook installed"
```

## The script

Copy the following to `scripts/hooks/pre-commit`:

```bash
#!/usr/bin/env bash
# scripts/hooks/pre-commit
#
# Format and lint staged Swift files. Run fast tests. Bail on failure.

set -e

# ─── Helpers ────────────────────────────────────────────────────────────────
red()    { printf '\033[0;31m%s\033[0m\n' "$1"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$1"; }
blue()   { printf '\033[0;34m%s\033[0m\n' "$1"; }

bail() {
    red "✗ $1"
    red "  Commit aborted. Fix the issue above and re-stage."
    exit 1
}

skip_if_no_files() {
    if [ -z "$1" ]; then
        green "  (no staged $2 files; skipping)"
        return 0
    fi
    return 1
}

# ─── Skip mechanism ─────────────────────────────────────────────────────────
# Allow `git commit --no-verify` to skip; allow per-call skip with an env var.
if [ "${SKIP_PRECOMMIT:-0}" = "1" ]; then
    yellow "⚠ SKIP_PRECOMMIT=1, bypassing checks"
    exit 0
fi

# ─── Determine staged Swift files ───────────────────────────────────────────
staged_swift=$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.swift$' || true)

# ─── 1. SwiftFormat ─────────────────────────────────────────────────────────
blue "▸ SwiftFormat"
if ! skip_if_no_files "$staged_swift" "Swift"; then
    if ! command -v swiftformat >/dev/null 2>&1; then
        bail "swiftformat not installed. Run: brew install swiftformat"
    fi
    # Format the staged files in place; re-add to staging.
    echo "$staged_swift" | xargs swiftformat --quiet
    echo "$staged_swift" | xargs git add
    green "  ✓ formatted"
fi

# ─── 2. SwiftLint (lint mode, fast) ─────────────────────────────────────────
blue "▸ SwiftLint"
if ! skip_if_no_files "$staged_swift" "Swift"; then
    if ! command -v swiftlint >/dev/null 2>&1; then
        bail "swiftlint not installed. Run: brew install swiftlint"
    fi
    # Lint only the staged files (much faster than the whole project).
    if ! echo "$staged_swift" | xargs swiftlint lint --quiet --use-script-input-files; then
        bail "SwiftLint failed. Fix violations above and re-stage."
    fi
    green "  ✓ lint clean"
fi

# ─── 3. Check for forbidden patterns ────────────────────────────────────────
blue "▸ Forbidden patterns"
if ! skip_if_no_files "$staged_swift" "Swift"; then
    # No `print(` outside tests and DocC.
    if echo "$staged_swift" | grep -vE '^tests/|\.docc/' | xargs grep -nE '(?<!Swift\.)\bprint\s*\(' 2>/dev/null; then
        bail "Use Logger, not print(). See structured-logging-with-privacy pattern."
    fi
    # No naked fatalError.
    if echo "$staged_swift" | grep -vE '^tests/' | xargs grep -nE '(?<!Logger\.)\bfatalError\s*\(' 2>/dev/null; then
        bail "Use Logger.fatal(...), not fatalError(...)."
    fi
    # No NSError throws.
    if echo "$staged_swift" | grep -vE '^tests/' | xargs grep -nE 'throw\s+NSError\s*\(' 2>/dev/null; then
        bail "Define a typed Error enum (see typed-errors-and-wire pattern)."
    fi
    green "  ✓ no forbidden patterns"
fi

# ─── 4. Build check (only if Swift files staged) ────────────────────────────
blue "▸ Build (swift build, --debug)"
if ! skip_if_no_files "$staged_swift" "Swift"; then
    if ! swift build --build-tests --quiet 2>&1 | tail -n 20; then
        bail "Build failed. Fix compile errors before committing."
    fi
    green "  ✓ builds"
fi

# ─── 5. Fast tests (only the most affected target) ──────────────────────────
# Optional — uncomment and tune for your project. Skipped by default to keep
# pre-commit < 5 seconds; full tests run in CI.
#
# blue "▸ Tests (smoke)"
# if ! swift test --filter "SmokeTests" --quiet; then
#     bail "Smoke tests failed."
# fi
# green "  ✓ smoke tests pass"

# ─── Done ───────────────────────────────────────────────────────────────────
green "✓ pre-commit checks passed"
exit 0
```

## What the hook checks

| Check | Why | Time |
| --- | --- | --- |
| `swiftformat` (in-place) | Trivial to fix automatically; restage. | < 1 s |
| `swiftlint --quiet` on staged files | Catches style and pattern violations before review. | 1–3 s |
| Forbidden-pattern grep | Belt-and-suspenders for the most-common violations. | < 1 s |
| `swift build --build-tests` | Compile check — catches broken code before it hits CI. | 3–10 s |
| Smoke tests (optional) | Catches obvious regressions. | varies |

Total: **3–15 seconds** for a typical commit. Skip with `SKIP_PRECOMMIT=1 git commit ...` or `git commit --no-verify` if you must.

## Why a plain Git hook (not Husky / pre-commit framework)

- **Zero install.** Anyone with `git`, `swiftformat`, `swiftlint` can use it. No `npm`, no Python, no extra dependency.
- **One file.** Easy to review, easy to audit, easy to fix.
- **No magic.** When the hook fails, the user sees exactly what failed and why.

Larger orgs may prefer [pre-commit](https://pre-commit.com) for cross-language consistency. The shape is the same; replace `scripts/hooks/pre-commit` with a `.pre-commit-config.yaml` listing the same tools.

## CI redundancy

CI runs the same checks (plus the full test suite). The hook is a *fast feedback loop*; CI is the *authority*. They should agree.

## Updating the hook

When you change `swiftformat.template.md`, `swiftlint.template.md`, or add a new forbidden pattern, update this hook too. Document the change in `CHANGELOG.md` under "Changed" so contributors notice on the next pull.

Run `make install-hooks` after pulling changes to the hook script.
