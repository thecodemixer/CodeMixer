# Pattern: Dependency injection seams

**Scope.** Every non-deterministic dependency the codebase touches — current time, randomness, environment, file system — has a protocol seam, a live implementation, and a deterministic test fake. Direct calls to the system APIs are confined to approved seams and `*/External/*.swift` wrappers, enforced by repository policy scripts.

**When to use.** Any codebase that needs to be testable and deterministic. The cost is low (four protocols plus mirrored fakes); the payoff compounds — every async test becomes microsecond-fast, every flaky timing-dependent test becomes a strict property test.

**When not to use.** Tiny scripts. Code that never needs a test. Anything you'll throw away in a week.

---

## The four canonical seams

| Seam | Production | Test fake | Replaces |
| --- | --- | --- | --- |
| `AgentClock` | `SystemClock` | `FakeClock` | `Date()`, `Task.sleep`, `ContinuousClock.now` |
| `RandomSource` | `SystemRandomSource` | `FakeRandomSource` | `Int.random`, `UUID()`, `SecRandomCopyBytes` |
| `AgentEnvironment` | `SystemEnvironment` | `FakeEnvironment` | `ProcessInfo.processInfo.environment`, app-support/cache path lookup, device name |
| `FileSystem` | `SystemFileSystem` | `InMemoryFileSystem` | `FileManager.default`, `Data(contentsOf:)`, `Data.write(to:)` |

Four is the empirically-correct number: not so many that the boilerplate dominates, not so few that meaningful non-determinism leaks through. If you need a fifth, candidates are `Logger`, `Locale`, `Calendar`, `Notifications` — add them only when an actual test forces the issue.

---

## The protocols

```swift
public protocol AgentClock: Sendable {
    func now() -> Date
    func monotonic() -> ContinuousClock.Instant
    func sleep(for duration: Duration) async throws
}

public protocol RandomSource: Sendable {
    func uuid() -> UUID
    func bytes(_ count: Int) -> Data
    func pin(digits: Int) -> String
}

public protocol AgentEnvironment: Sendable {
    var homeDirectory: URL { get }
    var appSupportDirectory: URL { get }
    var cachesDirectory: URL { get }
    var claudeDirectory: URL { get }
    var deviceName: String { get }
    func processEnvironment() -> [String: String]
}

public protocol FileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func isDirectory(at url: URL) -> Bool
    func createDirectory(at url: URL, withIntermediates: Bool) throws
    func readData(at url: URL) throws -> Data
    func readData(at url: URL, fromOffset offset: Int) throws -> Data
    func byteCount(at url: URL) throws -> Int
    func writeAtomically(_ data: Data, to url: URL) throws
    func move(from source: URL, to destination: URL) throws
    func remove(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func modificationDate(at url: URL) throws -> Date
}
```

**Properties to preserve:**

- Every seam is `Sendable`. Implementations are passed across actors.
- Every method that performs IO is `throws` or `async throws`. Tests can inject failures via the fake.
- Methods are intentionally narrow. The shape is "what the codebase needs," not "everything `FileManager` offers."
- No `@available` annotations — protocols target the lowest deployment OS.

---

## Live implementations

Live implementations live beside their protocols in one folder:

```
Core/
└── AgentCore/
    └── Seams/
        ├── Clock.swift
        ├── RandomSource.swift
        ├── Environment.swift
        ├── FileSystem.swift
        └── Seams.swift
```

```swift
public struct SystemClock: AgentClock {
    public init() {}
    public func now() -> Date { Date() }
    public func monotonic() -> ContinuousClock.Instant { ContinuousClock.now }
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public struct SystemFileSystem: FileSystem {
    private let fm = FileManager.default
    public init() {}
    public func fileExists(at url: URL) -> Bool { fm.fileExists(atPath: url.path) }
    public func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }
    // …
}
```

These seams and explicit `*/External/*.swift` wrappers are the only places the system APIs are allowed.

---

## The `Seams` aggregate

To avoid every initializer threading four protocols, define a single value struct that carries all of them:

```swift
public struct Seams: Sendable {
    public var clock: any AgentClock
    public var random: any RandomSource
    public var environment: any AgentEnvironment
    public var fileSystem: any FileSystem

    public init(clock: any AgentClock, random: any RandomSource,
                environment: any AgentEnvironment, fileSystem: any FileSystem) {
        self.clock = clock
        self.random = random
        self.environment = environment
        self.fileSystem = fileSystem
    }

    public static var live: Seams {
        Seams(clock: SystemClock(),
              random: SystemRandomSource(),
              environment: SystemEnvironment(),
              fileSystem: SystemFileSystem())
    }
}
```

Actors and services take `Seams` (or a specific seam) at init. Tests construct their own `Seams` from the fakes.

```swift
public actor Engine {
    private let seams: Seams
    public init(seams: Seams = .live) { self.seams = seams }
}
```

---

## Test fakes

Fakes mirror the protocols but expose seek / advance / preload APIs.

```swift
public final class FakeClock: AgentClock, @unchecked Sendable {

    private let lock = NSLock()
    private var nowValue: Date
    private var monoValue: ContinuousClock.Instant
    private var sleepers: [(deadline: Date, continuation: CheckedContinuation<Void, Error>)] = []

    public init(start: Date = Date(timeIntervalSince1970: 0)) {
        self.nowValue = start
        self.monoValue = ContinuousClock.now
    }

    public func now() -> Date { lock.withLock { nowValue } }
    public func monotonic() -> ContinuousClock.Instant { lock.withLock { monoValue } }

    public func sleep(for duration: Duration) async throws {
        let deadline = lock.withLock { nowValue.addingTimeInterval(TimeInterval(duration.components.seconds)) }
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { sleepers.append((deadline, continuation)) }
        }
    }

    public func advance(by duration: Duration) {
        lock.withLock {
            let interval = TimeInterval(duration.components.seconds)
            nowValue.addTimeInterval(interval)
            monoValue = monoValue.advanced(by: duration)
            let (ready, remaining) = sleepers.partition { $0.deadline <= nowValue }
            sleepers = remaining
            for (_, continuation) in ready {
                continuation.resume()
            }
        }
    }
}

public final class FakeRandomSource: RandomSource, @unchecked Sendable {
    private let lock = NSLock()
    private var queuedUUIDs: [UUID]

    public init(uuids: [UUID] = []) {
        self.queuedUUIDs = uuids
    }

    public func uuid() -> UUID {
        lock.withLock { queuedUUIDs.isEmpty ? UUID() : queuedUUIDs.removeFirst() }
    }

    public func bytes(_ count: Int) -> Data {
        Data(repeating: 0, count: count)
    }

    public func pin(digits: Int) -> String {
        String(repeating: "0", count: digits)
    }
}

public final class InMemoryFileSystem: FileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [URL: Data] = [:]
    private var directories: Set<URL> = []

    public init(preload: [URL: Data] = [:]) {
        self.files = preload
        for url in preload.keys {
            for ancestor in url.allAncestors { directories.insert(ancestor) }
        }
    }

    public func fileExists(at url: URL) -> Bool {
        lock.withLock { files[url] != nil || directories.contains(url) }
    }

    public func writeAtomically(_ data: Data, to url: URL) throws {
        lock.withLock {
            files[url] = data
            for ancestor in url.allAncestors { directories.insert(ancestor) }
        }
    }
    // …
}
```

**Properties:**

- `FakeClock.advance(by:)` resumes any sleepers whose deadlines passed. A test that runs a one-second-debounce algorithm advances the clock by one second and asserts the algorithm fired.
- `FakeRandomSource(uuids: [u1, u2, u3])` pre-loads UUIDs in order; the engine receives them deterministically.
- `InMemoryFileSystem(preload: [...])` preloads a virtual disk; assertions compare the resulting filesystem state to expected.
- All fakes implement `@unchecked Sendable` because they protect their internals with locks; the unchecked annotation is fine here.

---

## Enforcement via policy scripts

The benefit of seams collapses if a contributor reaches for `Date()` "just this once." Enforce with custom lint or policy scripts:

```yaml
# .swiftlint.yml
custom_rules:

  no_direct_date:
    name: "No direct Date()"
    regex: 'Date\(\)'
    message: "Use seams.clock.now() instead of Date()."
    severity: error
    excluded:
      - ".*/Seams/(Clock|RandomSource|Environment|FileSystem)\\.swift"
      - ".*/External/.*\\.swift"
      - ".*/tests/.*"

  no_direct_random:
    name: "No direct random"
    regex: '\.random\(in:|UUID\(\)'
    message: "Use seams.random.uuid(), seams.random.bytes(_:), or seams.random.pin(digits:)."
    severity: error
    excluded:
      - ".*/Seams/RandomSource\\.swift"
      - ".*/External/.*\\.swift"
      - ".*/tests/.*"

  no_direct_environment:
    name: "No direct process environment"
    regex: 'ProcessInfo\.processInfo\.environment'
    message: "Use seams.environment.processEnvironment()."
    severity: error
    excluded:
      - ".*/Seams/Environment\\.swift"
      - ".*/External/.*\\.swift"

  no_direct_file_manager:
    name: "No direct FileManager"
    regex: 'FileManager\.default'
    message: "Use seams.fileSystem APIs."
    severity: error
    excluded:
      - ".*/Seams/FileSystem\\.swift"
      - ".*/External/.*\\.swift"
      - ".*/tests/.*"
```

Tests are excluded so they can construct fakes against the real types if needed; seam implementations and external wrappers are excluded because they *are* the bridge. Everything else is held to the seam.

---

## Tests get faster, more comprehensive, less flaky

Without seams:

```swift
@Test func heartbeatFiresEvery500ms() async throws {
    let monitor = HeartbeatMonitor()
    await monitor.startTurn()
    try await Task.sleep(for: .seconds(2))   // real sleep
    let events = await monitor.collected
    #expect(events.count >= 3)               // probabilistic; flaky
}
```

With seams:

```swift
@Test func heartbeatFiresEvery500ms() async throws {
    let clock = FakeClock()
    let monitor = HeartbeatMonitor(clock: clock)
    await monitor.startTurn()
    clock.advance(by: .milliseconds(2000))   // synchronous
    let events = await monitor.collected
    #expect(events.count == 4)               // deterministic
}
```

The test runs in microseconds; it asserts an exact count; it never flakes. Same pattern applies for random numbers (predictable UUIDs), environment (no shell required), and filesystem (no disk required).

---

## Adopting incrementally

If a codebase isn't currently using seams, adopt in this order:

1. **`AgentClock`** — biggest test-speed win, biggest determinism win.
2. **`RandomSource`** — required as soon as you have UUID-keyed state machines.
3. **`FileSystem`** — required as soon as you persist anything.
4. **`AgentEnvironment`** — required as soon as you read `$HOME`, `$PATH`, etc.

Adopt one seam at a time:

- Add the protocol and live impl.
- Add the lint rule with `severity: warning` first.
- Migrate call sites file-by-file. Tests get faster as you go.
- Once zero call sites remain outside seams, flip the lint rule to `error`.

A codebase the size of Codemixer (~ 8 modules, ~ 80 source files) adopts cleanly in an afternoon.

---

## Codemixer instance

- `AgentClock` ↔ `AgentClock`. Live: `SystemClock`. Fake: `FakeClock` in `AgentTestSupport`.
- `RandomSource` ↔ `RandomSource`. Live: `SystemRandomSource`. Fake: `FakeRandomSource`.
- `AgentEnvironment` ↔ `AgentEnvironment`. Live: `SystemEnvironment`. Fake: `FakeEnvironment`.
- `FileSystem` ↔ `FileSystem`. Live: `SystemFileSystem`. Fake: `InMemoryFileSystem`.
- `Seams` ↔ `Seams` (in `Core/AgentCore/Seams/Seams.swift`).

See [docs/architecture.md §16](../../architecture.md) for the Codemixer-specific narrative.

---

## Anti-patterns

| Anti-pattern | Why it's bad |
| --- | --- |
| Threading individual seams through every initializer (10-param init) | Use the `Seams` aggregate. |
| A "current clock" global with `AgentClock.current = FakeClock()` in tests | Race-prone; surprises in parallel tests. Always inject. |
| Singleton `SystemClock.shared` | Discoverable but breaks the substitution model — tests can't override. |
| Fakes that randomise their own behaviour | Defeats determinism. Fakes are predictable; if you want chaos, build a `ChaosClock` that *seeds* a deterministic PRNG. |
| Adding `Logger` as a seam from day one | YAGNI for most projects. Add it the first time a test wants to assert log output. |
| Using `@TestingEnvironment` decorators or hidden state | Explicit injection is clearer. Decorators hide the contract. |

---

## Minimum viable adoption

1. Drop the four protocols above into a `Seams/` folder.
2. Drop the four live implementations.
3. Define `Seams` value struct with `.live`.
4. Pick one heavy-time-dependent module; refactor it to take `Seams`.
5. Write one deterministic test using `FakeClock.advance`.
6. Add the lint rule with `severity: warning`.
7. Migrate at the pace your reviews tolerate; flip the lint to `error` when zero violations remain.

The work is mechanical; the payoff is permanent.
