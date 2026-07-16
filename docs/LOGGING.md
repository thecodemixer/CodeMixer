# Logging conventions

Every module uses `import os` and `Logger` — never `print`.

Subsystem is always `AppIdentity.logSubsystem` (`com.codecave.Codemixer`).

## Logger categories (production)

| Area | `category` | Typical file |
|------|------------|--------------|
| PTY pipeline | `PTYHost` | `PTY/PTYHost.swift` |
| Child reaper | `ChildReaper` | `PTY/ChildReaper.swift` |
| Shell env | `EnvResolver` | `PTY/ShellEnvironmentResolver.swift` |
| Agent engine | `Engine` | `Engine/AgentEngine.swift` |
| Event bus | `EventBus` | `Bus/MulticastEventBus.swift` |
| Hook UDS | `HookServer` | `Hooks/HookServer.swift` |
| FSEvents | `FSEvents` | `FS/FSEventsWatcher.swift` |
| Git diff | `Diff` | `Diff/GitDiffEngine.swift` |
| Prefs | `PrefsStore` | `Persistence/PrefsStore.swift` |
| Sessions | `SessionStore` | `Persistence/SessionStore.swift` |
| Workspaces | `WorkspaceProjectsStore` | `Persistence/WorkspaceProjectsStore.swift` |
| Silent recovery journal | `SilentDiagnostics` | `Diagnostics/SilentDiagnostics.swift` |
| Claude transcript | `ClaudeTranscriptTailer` | `ClaudeTranscriptTailer.swift` |
| Remote listener | `RemoteControl` | `RemoteControlServer.swift` |
| Per-connection pump | `Client` | `ClientConnection.swift` |
| HTTP sidecar | `HTTP` | `HTTPSidecarServer.swift` |
| TLS identity | `CertificateManager` | `CertificateManager.swift` |
| Paired devices | `PairedDeviceStore` | `PairedDeviceStore.swift` |
| Daemon | `Daemon` | `CodemixerDaemon/main.swift` |

Declare at file scope:

```swift
private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "CategoryName")
```

## SilentDiagnostics

`SilentDiagnostics.shared` mirrors every quiet-recovery action to the system log **and** retains a bounded ring (`StreamBufferDefaults.silentDiagnostics`).

Kinds include: `prefsQuietReset`, `sessionsQuietReset`, `workspacesQuietReset`, `modeBFallback`, `wireVersionRejected`, `certificateRotated`, `permissionDeliveryFailed`, etc.

**Surfaces (opt-in / automation — no toasts):**

- **UI:** Settings → enable "Show Silent Recovery Log" → `SilentDiagnosticsView` sheet.
- **Sidecar:** `GET /v1/diagnostics/silent` on port 8422 (`RemoteDefaults.silentDiagnosticsPath`).
- **Console:** filter `category == "SilentDiagnostics"` or search for `silent ` prefix in messages.

## Log levels

| Level | When to use |
|-------|------------|
| `log.debug(...)` | Verbose lifecycle (PTY chunks, hook payloads). Off in release by default. |
| `log.info(...)` | Normal lifecycle (session started, adapter registered). |
| `log.notice(...)` | Rare milestones (server bound, cert fingerprint, daemon exit, silent recovery). |
| `log.error(...)` | Broken but continuable (spawn failed, TLS import error). |
| `log.fault(...)` | Invariant violated; process may be in unknown state. |

## Privacy levels

All log calls must set an explicit privacy level on interpolated values:

```swift
log.notice("PTY spawned pid=\(pid, privacy: .public) rows=\(rows, privacy: .public)")
log.debug("prompt text=\(promptText, privacy: .private)")
```

**Rule of thumb:**

- PIDs, exit codes, port numbers, counts, durations → `.public`
- Prompt text, file paths, user data, tokens → `.private`
- Session IDs → `.public` (opaque random strings, not PII)

## Forbidden

```swift
print("something")                   // use Logger
NSLog("something")                   // use Logger
os_log("something", log: .default)   // use Logger
```

Prefer `Logger`; there is no SwiftLint `no_print` rule in `.swiftlint.yml` today — review catches `print` in code review.

## Viewing logs

```bash
# Stream live logs from the daemon or app:
log stream --predicate 'subsystem == "com.codecave.Codemixer"' --level debug

# Filter to a specific category:
log stream --predicate 'subsystem == "com.codecave.Codemixer" AND category == "Engine"'

# Silent recovery only:
log stream --predicate 'subsystem == "com.codecave.Codemixer" AND category == "SilentDiagnostics"'

# Historical (last 1 hour):
log show --predicate 'subsystem == "com.codecave.Codemixer"' --last 1h
```
