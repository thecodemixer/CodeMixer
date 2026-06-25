# Logging conventions

Every module uses `import os` and `Logger` — never `print`.

## Logger categories

| Module | `subsystem` | `category` |
|--------|------------|------------|
| PTY pipeline | `com.codecave.Codemixer` | `PTYHost` |
| Agent engine | `com.codecave.Codemixer` | `Engine` |
| Claude Code | `com.codecave.Codemixer` | per-type (e.g. `ClaudeTranscriptTailer`) |
| Remote control | `com.codecave.Codemixer` | `RemoteControl` |
| HTTP sidecar | `com.codecave.Codemixer` | `HTTPSidecar` |
| Pairing | `com.codecave.Codemixer` | `PairedDeviceStore` |
| Daemon | `com.codecave.Codemixer` | `Daemon` |
| UI view model | `com.codecave.Codemixer` | `EngineViewModel` |

Declare at the top of each file:

```swift
private let log = Logger(subsystem: "com.codecave.Codemixer", category: "CategoryName")
```

## Log levels

| Level | When to use |
|-------|------------|
| `log.debug(...)` | Verbose lifecycle events (each PTY byte chunk, each hook payload). Off in release builds by default. |
| `log.info(...)` | Normal lifecycle events (session started, adapter registered). |
| `log.notice(...)` | Rare, important milestones (server bound, cert fingerprint, daemon exit). Always visible. |
| `log.error(...)` | Something is broken but the process can continue (spawn failed, TLS cert error). |
| `log.fault(...)` | Invariant violated; process is in an unknown state. |

## Privacy levels

All log calls must set an explicit privacy level on interpolated values:

```swift
// Good — public values are explicitly marked.
log.notice("PTY spawned pid=\(pid, privacy: .public) rows=\(rows, privacy: .public)")

// Good — private values are redacted in release logs.
log.debug("prompt text=\(promptText, privacy: .private)")

// Bad — implicit .auto is opaque and unreviewed.
log.info("session \(sessionID)")  // missing privacy label
```

**Rule of thumb:**
- PIDs, exit codes, port numbers, counts, durations → `.public`
- Prompt text, file paths, user data, tokens → `.private`
- Session IDs → `.public` (they're opaque random strings, not PII)

## Forbidden

```swift
// These are lint-checked and will fail CI:
print("something")                   // use log.debug / log.info
NSLog("something")                   // use Logger
os_log("something", log: .default)   // use Logger
```

The `.swiftlint.yml` custom rule `no_print` enforces this.

## Viewing logs

```bash
# Stream live logs from the daemon:
log stream --predicate 'subsystem == "com.codecave.Codemixer"' --level debug

# Filter to a specific category:
log stream --predicate 'subsystem == "com.codecave.Codemixer" AND category == "Engine"'

# Historical (last 1 hour):
log show --predicate 'subsystem == "com.codecave.Codemixer"' --last 1h
```
