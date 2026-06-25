# Pattern: Atomic file persistence with schema versioning

**Scope.** Persisting small-to-medium structured data (prefs, sessions, recent-projects, caches, per-project state) as JSON-on-disk via the temp-and-rename pattern, with embedded `schemaVersion` fields, forward-only migrations, and disciplined location conventions. The result: power-loss cannot corrupt a file, future versions can read old files, and old versions fail closed on newer files.

**When to use.** Any project that persists configuration, session state, or caches without a database. The pattern handles thousands of small files cleanly; for larger payloads (> ~10 MB / file), consider SQLite or a real key-value store.

**When not to use.** High-write-rate logs (use append-only log files). Multi-process write contention (use a real DB or a transaction log). Binary blobs > ~10 MB (use Core Data / SQLite / a content-addressable store).

---

## The three properties to preserve

1. **Atomic.** A reader never sees a half-written file. Power loss either preserves the prior content or the new content, never a torn mix.
2. **Versioned.** Every file embeds a `schemaVersion` integer the reader checks before decoding the payload.
3. **Forward-migrating.** Newer versions read older files via explicit migrations; older versions refuse to read newer files and tell the user.

These hold together. Drop one and the system bites you within a release cycle.

---

## The atomic write

```swift
public extension FileSystem {
    func writeAtomically(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try createDirectory(at: parent, intermediates: true)

        let temp = parent.appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
        try data.write(to: temp, options: [.atomic])      // POSIX rename(2) atomicity
        defer { try? remove(at: temp) }                    // clean if rename fails

        if fileExists(at: url) { try remove(at: url) }
        try moveItem(at: temp, to: url)
    }
}
```

**Properties:**

- `Data.write(to:options:.atomic)` already does temp + rename, but doing it manually with an explicit parent-directory ensure and a uniquely-named temp avoids two-writer collisions.
- On macOS / Linux, `rename(2)` is atomic on the same filesystem. Across filesystems it is not — keep temp and final in the same parent directory.
- The fsync story is platform-specific:
  - macOS does not sync the parent directory by default; for *durable* writes (must survive immediate power-loss), follow `data.write` with an explicit `F_FULLFSYNC`.
  - For prefs and session state, the default atomicity is enough — power-loss leaves the prior version intact.

---

## Schema-versioned files

Every file embeds `schemaVersion`:

```swift
public struct PrefsFileV2: Codable, Sendable {
    public let schemaVersion: Int            // always 2 for this struct
    public let theme: String                 // "light", "dark", "auto"
    public let voiceEnabled: Bool
    public let voiceConfidence: Double?
    public let autoResumeThresholdMS: Int64?
    public let permissionsHeadlessTimeoutSeconds: Int
}
```

**Rules:**

- `schemaVersion` is the *first* property — decoders inspect it before trusting anything else.
- Bump the integer for any breaking change: removed field, renamed field, semantic shift of an existing field.
- *Additive* changes (new optional field) do **not** bump. The decoder reads old files unchanged; new code reads the new field via `decodeIfPresent`.

---

## The reader: probe version first, decode second

```swift
public struct VersionProbe: Codable { public let schemaVersion: Int }

public enum PrefsStore {
    public static let currentVersion = 2

    public static func load(from url: URL, fs: any FileSystem) throws -> Prefs {
        let data = try fs.readData(from: url)
        let probe = try JSONDecoder().decode(VersionProbe.self, from: data)

        switch probe.schemaVersion {
        case 1:
            let v1 = try JSONDecoder().decode(PrefsFileV1.self, from: data)
            let v2 = migrate(v1)
            return convert(v2)
        case 2:
            let v2 = try JSONDecoder().decode(PrefsFileV2.self, from: data)
            return convert(v2)
        case let v where v > currentVersion:
            throw PrefsError.fromFuture(version: v, current: currentVersion)
        default:
            throw PrefsError.unknownVersion(version: probe.schemaVersion)
        }
    }
}
```

**Rules:**

- Probe first; decode second. A probe-failure is its own error case ("file isn't structured prefs at all").
- Migrations are explicit per-version transforms. No clever "decode whatever fits" magic.
- Future-version files fail closed with a typed error the UI surfaces:
  > *"This file was created by a newer version of {App}. Update to read it."*

---

## Migrations are forward-only

```swift
public enum PrefsMigrations {
    public static func migrate(_ v1: PrefsFileV1) -> PrefsFileV2 {
        PrefsFileV2(
            schemaVersion: 2,
            theme: v1.darkMode ? "dark" : "light",     // v1 had `darkMode: Bool`
            voiceEnabled: false,                          // v1 didn't have voice
            voiceConfidence: nil,
            autoResumeThresholdMS: v1.autoResumeSeconds.map { Int64($0 * 1000) },
            permissionsHeadlessTimeoutSeconds: 300        // new default
        )
    }
}
```

**Properties:**

- One migration function per version-bump. `v1 → v2`, `v2 → v3`, never `v1 → v3` directly (multi-hop is composed automatically).
- Old `PrefsFileV1` struct is kept in the codebase indefinitely so old files can be migrated even years later.
- Migration is *pure*: takes the old struct, returns the new struct. No I/O, no clocks, no randomness inside migrations (use the `Seams` if you need any — see [dependency-injection-seams](dependency-injection-seams.md)).
- After load, the next save writes the current version. Old files are upgraded in place.

**Backward incompatibility is one-way:** an older binary cannot write to a newer-version file. If a user downgrades, their prefs revert to defaults.

---

## File locations

Pick a *single* root for app-owned persisted state. macOS canonical:

```
~/Library/Application Support/com.codecave.Codemixer/
    ├── prefs.json                # global prefs (singleton)
    ├── recent.json               # recent projects (singleton)
    ├── sessions.json             # last session id per (agent, project)
    └── auto-approval/
        ├── <projectHash>.json    # per-project state
        └── <projectHash>.json
~/Library/Caches/Codemixer/       # deletable; macOS may reclaim
    └── uploads/<sessionID>/<uuid>
```

| Directory | When |
| --- | --- |
| `~/Library/Application Support/<bundleID>/` | App-owned, user-specific, persistent state that should survive macOS reset. |
| `~/Library/Caches/<bundleID>/` | Regeneratable. macOS may delete under disk pressure; design for that. |
| `~/Library/Preferences/` | `UserDefaults`. Avoid for anything complex — too easy to corrupt, not human-inspectable. |
| `~/Library/LaunchAgents/` | LaunchAgent plist (see [headless-remote-duality](headless-remote-duality.md)). |
| Keychain | Secrets only — never prefs. |
| `~/.config/{appname}/` | Linux convention. |

**Path resolution:**

```swift
public enum AppPaths {
    public static var supportRoot: URL {
        try! FileManager.default.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("com.codecave.Codemixer", isDirectory: true)
    }
    public static var cachesRoot: URL {
        try! FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("com.codecave.Codemixer", isDirectory: true)
    }
}
```

All persistence code reaches through `AppPaths`. Tests inject an `InMemoryFileSystem` rooted elsewhere.

---

## Encoder discipline

```swift
public enum PersistenceCodec {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
```

**Rules:**

- `prettyPrinted` + `sortedKeys` means humans can `cat` the file, `git diff` it, and reviewers see stable output.
- ISO-8601 dates everywhere; no Foundation default (which is `secondsSince1970` and locale-bound).
- `withoutEscapingSlashes` keeps `/` readable in paths.
- One encoder/decoder instance per process; reuse them.

---

## Caches expire; persistent state doesn't

Caches need a janitor:

```swift
public actor CacheCleaner {
    public func sweepUploads(olderThan ttl: Duration) async throws {
        let cacheRoot = AppPaths.cachesRoot.appendingPathComponent("uploads")
        let now = Date()
        for sessionDir in try contentsOfDirectory(at: cacheRoot) {
            for file in try contentsOfDirectory(at: sessionDir) {
                let modified = try modificationDate(of: file)
                if now.timeIntervalSince(modified) > Double(ttl.components.seconds) {
                    try remove(at: file)
                }
            }
        }
    }
}
```

**Run on:** app launch, every hour while running. Throttle on slow disks (don't iterate huge directories synchronously).

---

## Concurrent-write safety

The temp + rename pattern is *single-writer safe*. For multi-writer scenarios:

- **Within one process, multiple actors:** route all writes through one persistence actor. Other actors call `await store.save(prefs)`.
- **Across processes (GUI + daemon):** designate one writer (the daemon) and have the GUI read only. Or use a real database.
- **Last-write-wins is the default.** If you need read-modify-write, copy-on-read + version compare-and-swap; or move to a database.

Codemixer routes all persistence through `SessionStore` (a `public actor`); the GUI sends `updatePref` commands that the engine forwards to the store.

---

## Anti-patterns

| Anti-pattern | Why it's bad | Fix |
| --- | --- | --- |
| `Data.write(to: url)` without `.atomic` | Half-written file on crash | Always atomic; or the manual temp+rename. |
| No `schemaVersion` field | Hard to migrate; old code reads garbage | Embed the version. |
| Decode-then-check version | If the payload changed shape, decode crashes before the check | Probe version first. |
| Skipping version bumps for renames | Older binaries decode the new file silently with wrong field values | Bump even for renames. |
| `JSONEncoder()` per write | Slow; not a real bug but unnecessary | Cache the encoder. |
| Storing secrets in prefs | Filesystem leak | Keychain only. |
| Migrations that perform I/O | Non-deterministic; can't test | Migrations are pure functions. |
| Migrations that drop fields | Forward-only means: never lose data the user can't replace | Carry forward; deprecate; remove only after a UI migration prompt. |
| Multi-process writes without coordination | Last-write wins; data loss | Single writer or real DB. |

---

## Codemixer instance

- `SessionStore` ↔ `Core/AgentCore/Sessions/SessionStore.swift`.
- `AppPaths` ↔ `Core/AgentCore/Persistence/AppPaths.swift`.
- `PersistenceCodec` ↔ `Core/AgentCore/Persistence/PersistenceCodec.swift`.
- Prefs DTO ↔ `Core/AgentProtocol/Prefs.swift`.
- Atomic write ↔ `Core/AgentCore/Seams/SystemFileSystem.swift`.

See [docs/architecture.md §20](../../architecture.md) for the Codemixer narrative on persistence.

---

## Minimum viable adoption

1. Decide on a root directory (`~/Library/Application Support/<bundleID>/`).
2. Add `AppPaths` for path resolution.
3. Add `PersistenceCodec` with pretty + sortedKeys + ISO-8601.
4. Add `writeAtomically` to your `FileSystem` seam (see [dependency-injection-seams](dependency-injection-seams.md)).
5. Every persisted struct gets `schemaVersion`, current version pinned.
6. Implement `load(from:)` with the probe-first / decode-second / migrate pattern.
7. Build a cache cleaner if you have a caches directory.
8. Test: kill -9 your process mid-write; reopen; verify prior content survives.

The result: persistent state that survives crashes, version-bumps, and downgrades cleanly — without ever reaching for a database.
