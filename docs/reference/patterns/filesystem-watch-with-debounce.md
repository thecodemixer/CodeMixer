# Pattern: Filesystem watch with debounce

**Scope.** Watching a directory tree for file changes (`FSEventStream` on macOS, `inotify` on Linux, `FileSystemWatcher` on Windows) with disciplined debounce windows, ignore-list filtering, batched callbacks, and clean lifecycle. The result: a derived view (diff panel, search index, hot reload) reflects disk state within ~50 ms without thrashing on edit storms.

**When to use.** Any feature that should react to local file changes: diff panel, hot reload, search index, "external editor detected" prompts, project file lists, asset pipelines.

**When not to use.** Watching a single file (use `DispatchSource.makeFileSystemObjectSource`). Watching a network drive (FSEvents on macOS doesn't always fire for SMB/AFP mounts). Watching for content changes (FSEvents tells you a path *might* have changed; if you need to confirm, stat-and-compare).

---

## The four moving parts

1. **A platform-native event source** — `FSEventStreamCreate` on macOS, `inotify_init1` on Linux, `ReadDirectoryChangesW` on Windows.
2. **A debounce window** — coalesce bursts so the consumer doesn't recompute 200 times for a 200-file edit.
3. **An ignore filter** — `.gitignore`, build directories, `.git/`, `node_modules/`, derived artifacts.
4. **A batched callback** — fire once per debounce window with the deduped set of changed paths.

```
       OS event stream  ────►  Raw events (per syscall)
                                 │
                                 ▼
                          Debounce window (50ms typical)
                                 │
                                 ▼
                          Ignore filter (gitignore + project rules)
                                 │
                                 ▼
                          Batched FSEvent emission
                                 │
                                 ▼
                          Consumer (diff engine, indexer, etc.)
```

---

## The watcher actor — macOS

```swift
import CoreServices
import OSLog

public actor FSEventsWatcher {

    public struct FSEvent: Sendable {
        public let path: URL
        public let flags: Flags
        public let timestamp: Date
        public struct Flags: OptionSet, Sendable {
            public let rawValue: UInt32
            public init(rawValue: UInt32) { self.rawValue = rawValue }
            public static let created   = Flags(rawValue: 1 << 0)
            public static let modified  = Flags(rawValue: 1 << 1)
            public static let renamed   = Flags(rawValue: 1 << 2)
            public static let removed   = Flags(rawValue: 1 << 3)
            public static let isDir     = Flags(rawValue: 1 << 4)
        }
    }

    public let events: AsyncStream<[FSEvent]>           // batches

    private let log = Logger(subsystem: "com.codecave.Codemixer", category: "FSEvents")
    private let workspace: URL
    private let debounce: Duration
    private let ignoreFilter: any IgnoreFilter
    private let continuation: AsyncStream<[FSEvent]>.Continuation

    private var stream: FSEventStreamRef?
    private var pending: [FSEvent] = []
    private var flushTimer: Task<Void, Never>?

    public init(workspace: URL,
                debounce: Duration = .milliseconds(50),
                ignoreFilter: any IgnoreFilter = GitIgnoreFilter()) {
        self.workspace = workspace
        self.debounce = debounce
        self.ignoreFilter = ignoreFilter

        var continuation: AsyncStream<[FSEvent]>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingOldest(64)) { c in
            continuation = c
        }
        self.continuation = continuation
    }

    public func start() async throws {
        let context = bridgeContext(self)
        var ctx = FSEventStreamContext(version: 0, info: context,
                                       retain: nil, release: nil, copyDescription: nil)
        let paths = [workspace.path] as CFArray
        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagFileEvents
                 | kFSEventStreamCreateFlagNoDefer
                 | kFSEventStreamCreateFlagUseCFTypes)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, fsEventsBridge, &ctx, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.01, flags
        ) else { throw FSEventsError.create }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .global(qos: .userInitiated))
        FSEventStreamStart(stream)
        log.notice("watcher started workspace=\(self.workspace.path, privacy: .private)")
    }

    public func stop() async {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        flushTimer?.cancel()
        flushTimer = nil
        continuation.finish()
    }

    nonisolated fileprivate func receive(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        Task { [weak self] in await self?.enqueue(paths, flags) }
    }

    private func enqueue(_ paths: [String], _ rawFlags: [FSEventStreamEventFlags]) async {
        let now = Date()
        for (i, path) in paths.enumerated() {
            let url = URL(fileURLWithPath: path)
            if await ignoreFilter.shouldIgnore(url) { continue }
            let flags = FSEvent.Flags(rawFlags[i])
            pending.append(FSEvent(path: url, flags: flags, timestamp: now))
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTimer == nil else { return }
        flushTimer = Task { [weak self] in
            try? await Task.sleep(for: self?.debounce ?? .milliseconds(50))
            await self?.flush()
        }
    }

    private func flush() async {
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        flushTimer = nil
        guard !batch.isEmpty else { return }
        let deduped = dedupe(batch)
        continuation.yield(deduped)
    }

    private func dedupe(_ batch: [FSEvent]) -> [FSEvent] {
        var seen: [URL: FSEvent] = [:]
        for event in batch {
            if let existing = seen[event.path] {
                seen[event.path] = FSEvent(
                    path: event.path,
                    flags: existing.flags.union(event.flags),
                    timestamp: max(existing.timestamp, event.timestamp)
                )
            } else {
                seen[event.path] = event
            }
        }
        return Array(seen.values)
    }
}
```

**Properties:**

- `actor` for serial state. Reads come in on a dispatch queue; the bridge converts to actor-isolated calls.
- `nonisolated fileprivate func receive` is the C-callback shim — small, type-safe, single-purpose.
- `pending` accumulates raw events; `flush` debounces and dedupes.
- `bufferingPolicy: .bufferingOldest(64)` so a slow consumer doesn't accumulate unbounded backlog (drops oldest, signals overflow).

---

## The C-bridge (one-shot boilerplate)

```swift
private func bridgeContext(_ watcher: FSEventsWatcher) -> UnsafeMutableRawPointer {
    Unmanaged.passUnretained(watcher).toOpaque()
}

private let fsEventsBridge: FSEventStreamCallback = {
    _, contextInfo, numEvents, eventPaths, eventFlags, _ in
    guard let info = contextInfo else { return }
    let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
    let flagsBuffer = UnsafeBufferPointer(start: eventFlags, count: numEvents)
    let flags = Array(flagsBuffer)
    watcher.receive(paths, flags)
}
```

**Properties:**

- `Unmanaged.passUnretained` — the watcher's lifetime exceeds the stream's by construction (we cancel the stream before deinit). No retain cycle.
- The callback fires on the dispatch queue we set; it bounces back into actor isolation via `Task { ... }`.
- `@unchecked Sendable` is not required here because the bridge is a `nonisolated fileprivate` method on the actor (Swift's isolation checker accepts this).

---

## The debounce window

50 ms is the empirical sweet spot for Codemixer's diff panel use case:

| Window | Trade-off |
| --- | --- |
| 0 ms (no debounce) | Every syscall fires a recompute. Editing a `package.json` in VS Code (which writes via temp+rename in 4 steps) fires 4×. |
| 10 ms | Catches almost all editor write patterns; UI lag imperceptible. |
| **50 ms** | Catches large checkouts (`git checkout main` with hundreds of files) in one batch. Imperceptible lag. **Codemixer default.** |
| 250 ms | UI feels sluggish; user types a character, sees nothing for a quarter-second. |
| 1 s | Misses transient state ("the file existed for 800 ms then was deleted"). Not appropriate for interactive UIs. |

**Adaptive widening:** under low-power mode, widen to 250 ms; under heavy load (> 1000 events / sec), widen to 500 ms.

---

## The ignore filter

```swift
public protocol IgnoreFilter: Sendable {
    func shouldIgnore(_ url: URL) async -> Bool
}

public actor GitIgnoreFilter: IgnoreFilter {
    private let workspace: URL
    private var cache: [URL: Bool] = [:]

    public init(workspace: URL) { self.workspace = workspace }

    public func shouldIgnore(_ url: URL) async -> Bool {
        if let cached = cache[url] { return cached }

        // Cheap path-based rules first.
        let path = url.path
        let cheap = path.contains("/.git/")
                 || path.contains("/node_modules/")
                 || path.contains("/.build/")
                 || path.contains("/DerivedData/")
                 || path.hasSuffix(".tmp")
                 || path.hasSuffix(".lock")
        if cheap { cache[url] = true; return true }

        // Expensive: `git check-ignore` for everything else.
        let isIgnored = await gitCheckIgnore(url) ?? false
        cache[url] = isIgnored
        return isIgnored
    }

    public func invalidateCache() { cache.removeAll(keepingCapacity: true) }
}
```

**Rules:**

- **Cheap rules first.** Substring checks on the path are fast; `git check-ignore` is a subprocess invocation. Eliminate the obvious cases before spending the syscall.
- **Cache aggressively.** A path's ignore status rarely changes during a session. Invalidate the cache when `.gitignore` itself changes (an FSEvent we *don't* ignore).
- **Batch the slow checks.** Run `git check-ignore --stdin` once per debounce window with all candidate paths, not once per path.

---

## Linux / inotify equivalent

The shape is identical; the source differs:

```swift
#if canImport(Glibc)
import Glibc

public actor INotifyWatcher {
    private let fd: Int32

    public init(workspace: URL, ignoreFilter: any IgnoreFilter) throws {
        fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC)
        guard fd != -1 else { throw FSEventsError.create }
        // Recursively add watches…
    }

    // Read events from `fd` with DispatchSource.makeReadSource;
    // parse inotify_event structs; emit FSEvents identically.
}
#endif
```

Cross-platform projects expose `FSEventsWatcher` as a protocol and implement per-OS.

---

## Lifecycle invariants

- `start()` is called once; calling twice is an error.
- `stop()` is idempotent and safe to call from any context.
- The actor is deallocated after `stop()`; before, deallocation is undefined (the stream holds an unretained reference; deallocating mid-callback crashes).
- On `start()` failure, `stop()` must still be callable safely (it is — internal state is nil).

---

## Anti-patterns

| Anti-pattern | Why it's bad | Fix |
| --- | --- | --- |
| No debounce | Recomputes per syscall; 200-file checkouts trigger 200 redraws. | Always debounce. |
| Debounce window > 100 ms in interactive UIs | Sluggish; users notice. | Stay ≤ 50 ms; widen only under load. |
| `git check-ignore` per event | Subprocess per syscall; CPU bound. | Cache; batch per window. |
| Watching ignored directories | FSEvents *delivers* events from `.git/`; you filter them, but the kernel sent them anyway. | macOS: pass `kFSEventStreamCreateFlagIgnoreSelf` and filter early. |
| Recursive `inotify_add_watch` without watching new subdirs | New folders created mid-session don't get watched. | On any `IN_CREATE` for a directory, add a watch recursively. |
| Forgetting to stop the stream on actor deinit | Use-after-free on the next event. | `stop()` in deinit (or call it explicitly before drop). |
| Treating dedupe as "first-wins" | Loses flag union; `(created, modified)` becomes just `created`. | Union the flags. |
| Emitting raw paths without bounding by workspace | Symlinks can escape the workspace; events from outside leak. | Verify path is under workspace root after canonicalization. |

---

## Codemixer instance

- `FSEventsWatcher` ↔ `Core/AgentCore/FS/FSEventsWatcher.swift`.
- Ignore filter ↔ `Core/AgentCore/FS/GitIgnoreFilter.swift`.
- Consumer ↔ `Core/AgentCore/Diff/GitDiffEngine.swift` — re-runs `git status` on each debounce flush.
- Debounce default ↔ 50 ms (per [docs/architecture.md §19](../../architecture.md)).

---

## Minimum viable adoption

1. Choose your platform source: `FSEventStreamCreate` (macOS), `inotify_init1` (Linux), `FileSystemWatcher` (Windows).
2. Build the watcher actor. Boilerplate is ~ 200 lines; per-platform.
3. Add a debounce window. 50 ms default.
4. Add an ignore filter. Cheap path checks first, expensive `git check-ignore` second, cached.
5. Make the consumer subscribe to `events` as an `AsyncStream<[FSEvent]>` of batches.
6. Test:
   - 1000 files written in 200 ms → one batched callback with deduped paths.
   - Single edit → one callback within debounce + a few ms.
   - `.gitignore` change → cache invalidates; subsequent edits in newly-ignored paths drop.

The result: a derived view that stays in sync with disk state without overreacting to edit storms.
