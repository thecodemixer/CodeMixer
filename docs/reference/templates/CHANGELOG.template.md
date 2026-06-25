<!--
CHANGELOG template (Keep a Changelog 1.1.0).

Copy to a new project's repo root as `CHANGELOG.md`. Replace `{ … }` placeholders.
Maintain in reverse chronological order. Group entries under `Added`, `Changed`, `Fixed`, etc.
-->

# Changelog

All notable changes to {Project Name} are documented here.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- {Short entry describing a new capability. Reference issues / PRs at the end: `(#142)`.}

### Changed
- {Backwards-compatible change to existing behaviour.}

### Deprecated
- {Public-API surface scheduled for removal in a future major.}

### Removed
- {API or feature removed in this release.}

### Fixed
- {User-visible bug fix.}

### Security
- {Vulnerability fix. Always include CVE if assigned.}

---

## [1.2.0] — 2026-05-15

### Added
- Voice command palette: every slash command is now invokable by voice with confirmation when confidence < 0.85. (#203)
- `GET /v1/health` endpoint for remote clients to check daemon liveness. (#198)
- `--pair` flag for `{project}d` to print a one-time pairing PIN for new clients. (#191)

### Changed
- Activity indicator now uses a continuous shimmer instead of a discrete dot to better convey "still working." (#205)
- Hook server socket path is now per-PID (`$TMPDIR/codemixer-hook-<pid>.sock`) to allow multiple instances. (#212)
- Strict-concurrency mode upgraded to Swift 6.2; all `@unchecked Sendable` annotations audited. (#218)

### Fixed
- PTY: stale child-process group could survive app crash; now reaped on next startup via a `cpx_killpg` sweep. (#220)
- Diff panel: 50 ms debounce window was being applied per-file instead of per-batch; large checkouts no longer thrash. (#224)
- Remote control: bearer-token rotation removed in-flight tokens before reply was sent. (#229)

### Security
- CVE-2026-XXXX: pairing PIN was logged at `notice` level in debug builds; now redacted. (#233)

---

## [1.1.0] — 2026-03-02

### Added
- Headless daemon mode (`{project}d`) with TLS WSS API. (#150)
- New `IntentReveal` SwiftUI modifier for progressive disclosure across composer toolbars. (#162)

### Changed
- {…}

### Fixed
- {…}

---

## [1.0.0] — 2026-01-18

Initial public release.

### Added
- Native macOS GUI wrapping `claude` over a hidden PTY.
- Side-by-side conversation + diff panel.
- Slash command palette with mouse, keyboard, and voice invocation.

---

[Unreleased]: https://github.com/{org}/{repo}/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/{org}/{repo}/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/{org}/{repo}/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/{org}/{repo}/releases/tag/v1.0.0
