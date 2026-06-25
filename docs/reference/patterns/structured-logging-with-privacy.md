# Pattern: Structured logging with privacy

**Scope.** A logger-per-module convention using `os.Logger` (or equivalent), explicit privacy levels on every interpolated field, structured fields readable by Console / `log show` / `OSLogStore`, a fatal escape hatch, and signposts for performance investigations. The result: useful logs in production with no PII leakage, no `print` statements anywhere, and a single grep to find the source of any line.

**When to use.** Any Apple-platform project. The model generalises to `swift-log` / `OSLog` on Linux, but the privacy levels and Console integration are Apple-specific.

**When not to use.** One-shot scripts. CLI tools whose output *is* the product (where `print` is appropriate).

---

## One `Logger` per module, one category per concern

```swift
// Core/AgentCore/Logging.swift
import OSLog

enum Loggers {
    static let engine     = Logger(subsystem: "com.codecave.Codemixer", category: "Engine")
    static let pty        = Logger(subsystem: "com.codecave.Codemixer", category: "PTY")
    static let hook       = Logger(subsystem: "com.codecave.Codemixer", category: "Hook")
    static let bus        = Logger(subsystem: "com.codecave.Codemixer", category: "Bus")
    static let diff       = Logger(subsystem: "com.codecave.Codemixer", category: "Diff")
    static let activity   = Logger(subsystem: "com.codecave.Codemixer", category: "Activity")
}

// At use:
private let log = Loggers.engine
log.notice("engine started workspace=\(workspace.path, privacy: .public)")
```

**Rules:**

- **Subsystem** = reverse-DNS bundle id, identical across the binary.
- **Category** = module + concern. One category per file family, not per-file.
- Loggers are declared once in `Loggers.swift`; files reference them via `private let log = Loggers.engine`.
- A test grep — `grep -RnE 'Logger\(' src/` — should produce exactly one match per module.

---

## Privacy levels on every interpolation

`os.Logger`'s interpolations default to `.private` in release builds — but only if you don't override them. Be explicit:

```swift
log.notice("starting pid=\(pid, privacy: .public) workspace=\(workspace, privacy: .private)")
```

**The convention:**

| Data | Privacy | Rationale |
| --- | --- | --- |
| Process IDs, PIDs, port numbers, errno values, byte counts, durations | `.public` | Diagnostic; no PII. |
| Bundle IDs, agent identifiers, fixed enum values (`stopped(reason: .userCancel)`) | `.public` | Type-safe public values. |
| File paths, URLs (especially in user home), workspace names | `.private` | Reveals identity / project structure. |
| User prompts, transcript content, conversation text | `.private` | Always. |
| Device names from pairing | `.public` | User-chosen, public-ish. |
| Tokens, PINs, secrets, keys | **Never logged** | Not even hashed. |
| Error case names | `.public` | Useful for grep without payload. |
| Error messages from upstream services | `.private` (default) | May contain user data echoed back. |

**Forbidden:**

- No `log.info("\(anything)")` without an explicit privacy tag. A custom SwiftLint rule rejects `\(.*)\)` in `Logger` calls that lack `privacy:`.

---

## Log levels — by frequency, by consequence

`os.Logger` exposes five levels. Use them honestly:

| Level | Per-second budget | When |
| --- | --- | --- |
| `debug` | Unlimited (free in release; stripped) | Verbose tracing; loop counters; per-byte. |
| `info` | < 10 | Per-event highlights; subsystem state changes. |
| `notice` | < 1 | Lifecycle: started / stopped / restarted. **Persisted by default.** |
| `error` | < 0.1 | Recoverable failure; user-visible problem. Persisted. |
| `fault` | per-incident | Programmer error; invariant broken. Persisted; raised in Console. |

**Rule of thumb:** if every call site of a level fires more often than the budget says, drop a level.

---

## Structured fields — `key=value` everywhere

Logs are searchable when they look like:

```
engine started pid=4567 workspace=/Users/h/Code/foo session=a1b2c3
```

Not:

```
Started the engine with PID 4567 for the user's workspace at /Users/h/Code/foo
```

**Convention:**

- Words first; fields second. The reader scans the prose for "what happened."
- Fields are `name=value` (no quotes, no spaces inside values where possible).
- Fields are ordered most-to-least relevant.
- Field names are short, stable, and globally consistent (`pid` everywhere, never `processIdentifier` in some places).

A team that pipes logs through `log show --predicate 'subsystem == "com.codecave.Codemixer"' --info | rg 'engine started'` should always find what it's looking for.

---

## `Logger.fatal` — the only escape hatch

```swift
// Core/AgentCore/Logging+Fatal.swift
import OSLog

extension Logger {
    public func fatal(_ message: @autoclosure () -> String,
                      file: StaticString = #file,
                      line: UInt = #line) -> Never {
        let m = message()
        self.fault("FATAL \(m, privacy: .public)")
        #if DEBUG
        Swift.assertionFailure(m, file: file, line: line)
        #endif
        Foundation.exit(1)
    }
}
```

**Uses:**

- `Logger.fatal("invariant: bus subscriber map missing key after insert")` — programmer error.
- `Logger.fatal("daemon: cannot bind, port held by another process")` — startup impossibility.

**Properties:**

- Always emits a `fault`-level log line (persistent, raised in Console).
- In debug, asserts → test failure → trace in Xcode.
- In release, `exit(1)` — clean shutdown, no zombie children (the reaper has time to fire because we don't `_exit`).
- Never silent.

`fatalError(...)` and `preconditionFailure(...)` are reserved for truly-unreachable code paths (the default of an enum switch over a closed set). All "should never happen but might" goes through `Logger.fatal`.

---

## Signposts for performance

`os.signpost` cuts windows of work into Instruments-readable spans:

```swift
import OSLog

private let signposter = OSSignposter(subsystem: "com.codecave.Codemixer", category: "Engine")

public func processTurn(_ id: UUID) async {
    let span = signposter.beginInterval("Turn", id: signposter.makeSignpostID(), "id=\(id.uuidString, privacy: .public)")
    defer { signposter.endInterval("Turn", span) }
    // …work…
}
```

Open Instruments → File → New → System Trace → Run; signposts appear in the timeline labeled `Turn` with the `id=...` annotation. Indispensable for "why did this take 4 seconds" investigations.

**Rules:**

- One signposter per logging category.
- Signpost names are nouns (`Turn`, `HookRoundtrip`, `Diff`), not verbs.
- Annotations use the same privacy levels as logs.
- Don't signpost hot loops (every byte read); signpost work boundaries.

---

## Health endpoints and observability

For services that run as daemons (see [headless-remote-duality](headless-remote-duality.md)), expose a health endpoint:

```swift
public struct HealthResponse: Codable, Sendable {
    public let version: String
    public let buildSHA: String
    public let uptimeMS: Int64
    public let engineState: String
    public let connectedClients: Int
    public let activeTurnID: String?
    public let lastEventAt: String          // ISO-8601
    public let memoryMB: Int
}
```

Served at `GET /v1/health`. Polled by:

- The GUI before opening a WSS connection (decides mode).
- LaunchAgent / systemd unit health checks.
- Operations dashboards (when applicable).

The endpoint **does not log every probe** (would saturate at one-per-second polling). It does increment a counter so saturation can be detected.

---

## What never gets logged

A hard list:

- **Passwords, PINs, OTPs, API keys, bearer tokens** — never; not even hashed.
- **Full user prompts** — only their byte length and source.
- **Full assistant responses** — only their byte length, model, latency.
- **Transcript content** — paths only, not bodies.
- **Personally-identifying information** — names, addresses, phone numbers. (Device names, set by the user, are an exception — the user opted in.)
- **Wire frames in full** — only the type discriminator and metadata.

A pre-merge review item: *"Show me the logs for this code path and confirm no banned data appears."*

---

## Where the logs go

| Destination | When |
| --- | --- |
| Console.app | Default. `notice` and above persist; `info` only if "Action → Include Info Messages" is on. |
| `log show --predicate '...' --info --last 1h` | CLI investigations. |
| `OSLogStore` programmatic access | Building an in-app "Show recent logs" panel. |
| Crash reports / sysdiagnose | Apple's standard collection for distribution. |
| External SaaS aggregator | **Off by default in Codemixer.** When enabled, ensure privacy levels still hold and the export pipeline strips `.private` fields. |

---

## Anti-patterns

| Anti-pattern | Why it's bad | Fix |
| --- | --- | --- |
| `print(...)` anywhere | Goes nowhere in release; pollutes Xcode console in debug. | `Logger.notice` / `.debug`. CI rejects `print(`. |
| `Logger().info(...)` ad hoc | New subsystem / category per call site; unsearchable. | Define `Loggers.foo` once. |
| Missing `privacy:` interpolation | Defaults to `.private` in release — but easy to slip by passing a `String` precomputed elsewhere. | Lint-enforce. |
| Logging full payloads "for debug" | Survives to production builds; PII leakage. | Conditional `#if DEBUG` only; never in `info` or above. |
| `notice` for per-byte events | Saturates Console; persistent storage fills. | `debug` for high-frequency. |
| Custom log formatters | Defeats Console.app's display. | Stick with `os.Logger`'s native interpolation. |
| Calling `Logger.fatal` for recoverable conditions | Killing the app over user-fixable problems. | Recover, log `error`, surface to UI. |

---

## Codemixer instance

- `Loggers.swift` ↔ in each module's root.
- Subsystem ↔ `com.codecave.Codemixer`.
- Categories ↔ `Engine`, `PTY`, `Hook`, `Bus`, `Diff`, `Activity`, `Remote`, `Pairing`, `UI`, `Daemon`.
- `Logger.fatal` ↔ `Core/AgentCore/Logging+Fatal.swift`.
- Health endpoint ↔ `Remote/AgentRemoteControl/RemoteControlServer.swift` (`GET /v1/health`).

See [docs/architecture.md §23](../../architecture.md) for the Codemixer narrative on observability.

---

## Minimum viable adoption

1. Define `Loggers` enum: one logger per module/concern.
2. Add a SwiftLint rule banning `print(` outside generated code.
3. Add a SwiftLint rule requiring `privacy:` on every `Logger` interpolation.
4. Add the `Logger.fatal` extension; ban naked `fatalError` outside generated code.
5. Audit existing log call sites: privacy levels, structured fields, log level appropriateness.
6. Add signposts to the 3–5 most performance-relevant code paths.
7. Add a `GET /v1/health` endpoint if you have a daemon.

After a sprint, your logs are searchable, your secrets stay secret, and your release builds tell you what they did when something goes wrong.
