# Codemixer Style Guide

This is the engineering aesthetic for Codemixer. It describes how we *write* code, not just what code we write. It exists because lint rules catch only the cheapest mistakes; the difference between a codebase that ages well and one that decays is taste, and taste needs to be written down.

Read this once, fully, before opening your editor. Re-read the *Pre-merge review checklist* (§26) every time you raise a pull request. The reference exemplar `PTYHost.swift` is this document made concrete — when you cannot articulate why something feels wrong, open `PTYHost` side-by-side; the contrast usually makes the answer obvious.

[docs/architecture.md](../architecture.md) is the canonical *how-and-where the system is put together*. This file is the canonical *how code reads*. [docs/style/visual-style.md](visual-style.md) is the canonical *how the product looks and behaves on screen*. When they conflict, `architecture.md` wins on structural decisions, this file wins on how code reads, and `visual-style.md` wins on visuals.

---

## Contents

1. [The soul — seventeen principles](#1-the-soul--seventeen-principles)
2. [The reference exemplar — `PTYHost`](#2-the-reference-exemplar--ptyhost)
3. [Hard rules (lint-enforceable)](#3-hard-rules-lint-enforceable)
4. [Naming conventions](#4-naming-conventions)
5. [Swift idiom](#5-swift-idiom)
6. [View aesthetic (SwiftUI)](#6-view-aesthetic-swiftui)
7. [Test aesthetic](#7-test-aesthetic)
8. [Documentation & DocC](#8-documentation--docc)
9. [Access control](#9-access-control)
10. [Protocol design](#10-protocol-design)
11. [Async & concurrency patterns](#11-async--concurrency-patterns)
12. [Logging](#12-logging)
13. [Error handling](#13-error-handling)
14. [Codable & wire encoding](#14-codable--wire-encoding)
15. [Extensions & namespace hygiene](#15-extensions--namespace-hygiene)
16. [Memory & references](#16-memory--references)
17. [Performance & measurement](#17-performance--measurement)
18. [Security as code style](#18-security-as-code-style)
19. [Observability](#19-observability)
20. [Configuration & preferences](#20-configuration--preferences)
21. [Localization](#21-localization)
22. [Refactoring discipline](#22-refactoring-discipline)
23. [Commit, branch, and PR aesthetic](#23-commit-branch-and-pr-aesthetic)
24. [Git hygiene beyond commits](#24-git-hygiene-beyond-commits)
25. [Tooling](#25-tooling)
26. [Pre-merge review checklist](#26-pre-merge-review-checklist)
27. [Boring is beautiful](#27-boring-is-beautiful)
28. [Adopting Swift language features](#28-adopting-swift-language-features)
29. [The meta-process — how this document evolves](#29-the-meta-process--how-this-document-evolves)
30. [Glossary](#30-glossary)
31. [When in doubt](#31-when-in-doubt)

---

## Platform applicability

This guide is written to be reusable across SwiftUI projects on every Apple platform. Most rules are platform-agnostic: language idiom, concurrency, testing, naming, documentation, error handling, security mindset, git, and review rhythm transfer wherever Swift runs.

A handful of items reference a specific OS — concrete paths, framework names, or system apps that exist on one platform. Those are tagged inline with an applicability marker:

- **[macOS]** — applies only when targeting macOS.
- **[iOS / iPadOS / visionOS]** — applies only on the noted mobile platforms.
- **[Apple cross-platform]** — applies wherever the relevant framework ships (most cases).

Where a rule shows a macOS example, the *principle* is universal; only the concrete API or path differs on iOS. Translate by using the platform-appropriate equivalent (e.g., `FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask)` resolves correctly on both). When in doubt, the **principle** wins, not the platform-specific incantation.

---

## 1. The soul — seventeen principles

These are not lint rules. They are reviewed by eye, and a pull request that violates them is refused merge regardless of how green CI is. Each principle has a rationale and a concrete example.

### 1.1 Files open with the public surface first

The reader's eye should land on **what the type does** before it lands on **how it does it**. The shape of a file is:

```
1. File-level doc comment (one paragraph: what this file owns, who calls it, lifecycle)
2. Public type declaration + its public properties
3. Public init
4. Public methods (lifecycle first, then primary behavior, then queries)
5. Private state
6. Private helpers
7. Nested types
8. deinit
```

The reader who has never seen this file before should be able to answer "what does this thing do" by reading the top 30 lines.

**Why:** the alternative (private helpers first, public surface buried at the bottom) forces every reader to read the entire file to find the entry point. A reader's time is the most expensive resource in software engineering.

See `PTYHost.swift`, the reference exemplar.

### 1.2 Types encode invariants, not just data

A type is a proof. If a `Session` cannot exist without an `id`, its `id` is non-optional even if it complicates construction. If an `AgentState` cannot be both `.idle` and `.runningTool`, those are cases of one enum, not two booleans.

**Tools:** enums with associated values, phantom types, non-empty collections, `Result`, the `Either`-shaped enum.

**Anti-pattern:**

```swift
struct Connection {
    var isConnecting: Bool
    var isConnected: Bool
    var lastError: Error?
    var stream: AsyncStream<Data>?
}
```

**Good:**

```swift
enum Connection {
    case idle
    case connecting(attempt: Int)
    case connected(stream: AsyncStream<Data>)
    case failed(Error)
}
```

The compiler now refuses to let you check `lastError` while `isConnected == true`.

**Why:** invalid states that can be represented will be reached. Encoding invariants in the type system means the compiler is your spec-enforcer.

### 1.3 A function's signature is its specification

A senior reader infers behavior from the signature alone. If you need a doc-comment to explain what a function *does*, the name is wrong. Doc-comments are for what the signature *cannot* express: preconditions, ownership, side effects, threading guarantees, error semantics.

**Good:**

```swift
/// Sends `bytes` to the master file descriptor. Blocks the caller until the kernel
/// accepts every byte. Cancellation: cooperative; throws `CancellationError` if the
/// surrounding task is cancelled mid-write.
public func write(_ bytes: Data) async throws(PTYError)
```

**Anti-pattern doc-comment:**

```swift
/// Writes the bytes.
public func write(_ bytes: Data) async throws(PTYError)
```

That comment is noise — the name said the same thing.

### 1.4 Boundaries are crisp

Every module's responsibility fits in one sentence. If you cannot write it, the module is wrong.

- `PTYHost` owns the master file descriptor and serializes reads and writes against it.
- `AgentEngine` orchestrates an `AgentAdapter`'s lifecycle and fans events out to clients.
- `MulticastEventBus` broadcasts events to N subscribers with bounded buffering and a replay ring buffer.
- `StatusPhraseResolver` picks the user-facing status phrase from competing signals by priority.

If you find yourself writing "and also" in the description, split the module.

### 1.5 Abstractions earn their keep

No `protocol` until you have two non-test implementations OR a clear test seam. No `<T>` generic until concrete duplication forces it. No `enum` "extensibility point" until a second variant is on the immediate horizon.

**Why:** premature abstraction is the same disease as premature optimization, just better-dressed. An interface invented before its second caller exists encodes the *first* caller's assumptions as the interface's contract. The second caller arrives and the interface doesn't fit, and now you have an interface AND a workaround.

**Rule:** two callers is not enough to extract. Three is.

The exception: protocols that exist as test seams (`Clock`, `RandomSource`, `Environment`, `FileSystem`). These have exactly one production implementation and one fake, but the test seam justifies the interface.

### 1.6 Time, randomness, environment, and the file system are injected

Production domain code never calls `Date()`, `Int.random`, `ProcessInfo.processInfo.environment`, or `FileManager.default`. These are all wrapped in protocols:

```swift
public protocol Clock: Sendable {
    var now: Date { get }
    func sleep(for duration: Duration) async throws
}

public protocol RandomSource: Sendable {
    func next<T: FixedWidthInteger>(in range: Range<T>) -> T
}

public protocol Environment: Sendable {
    func value(for name: String) -> String?
}

public protocol FileSystem: Sendable {
    func read(_ url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func exists(_ url: URL) -> Bool
    func remove(_ url: URL) throws
}
```

Live implementations live in `Core/AgentCore/Seams/Live*.swift`. Deterministic fakes live in `AgentTestSupport/Fake*.swift`.

**Why:** tests that depend on the wall clock are flaky tests. Tests that exercise heartbeats, timeouts, or retries are impossible to write correctly without an injected clock. We make all such tests millisecond-fast and deterministic by construction.

A custom SwiftLint rule rejects `Date()`, `Int.random`, `ProcessInfo.processInfo.environment`, and `FileManager.default` in any file outside `Core/AgentCore/Seams/Live*.swift`.

### 1.7 Errors are stories, not strings

A typed error enum carries everything a debugger or a user needs to understand what went wrong.

**Bad:**

```swift
enum PTYError: Error { case spawnFailed(String) }
throw PTYError.spawnFailed("oops")
```

**Good:**

```swift
public enum PTYError: Error, Sendable, Codable {
    case openptyFailed(errno: Int32, posixDescription: String)
    case spawnFailed(executable: String, errno: Int32, posixDescription: String)
    case writeFailed(errno: Int32, bytesAttempted: Int)
    case alreadyClosed
}

throw PTYError.spawnFailed(
    executable: binary.path,
    errno: errno,
    posixDescription: String(cString: strerror(errno))
)
```

The error carries the executable path, the errno, the human description — everything we'd want to log or surface. And because it's `Codable`, the same typed error crosses the WebSocket boundary; the phone sees the *same* error the engine raised.

**Pinned:**
- No `throws -> any Error`. Use Swift 6.2 typed throws (`throws(SomeError)`).
- No `try?` to swallow errors. If you can recover, write the recovery; if you can't, propagate.
- No `try!` outside test fixtures.
- Errors are `Codable` if they can cross the network boundary.

### 1.8 Logging is structured

`import os.Logger`, never `print`. Levels are deliberate:

- `debug` — chatty internals, off in release by default
- `info` — routine lifecycle events
- `notice` — rare and meaningful
- `error` — something is broken

Privacy levels are explicit on every interpolation:

```swift
log.notice("Spawned agent pid=\(pid, privacy: .public) workspace=\(workspace.path, privacy: .private)")
log.error("Hook decode failed: \(error, privacy: .public)")
```

Full conventions in §12.

### 1.9 Tests are specifications, not coverage targets

Tests describe behavior. Their names are English sentences. Their bodies are arrange / act / assert separated by single blank lines.

**Bad:**

```swift
@Test func testPTY1() {
    let host = try PTYHost()
    let data = "hello".data(using: .utf8)!
    try await host.write(data)
}
```

**Good:**

```swift
@Test("PTYHost.write enqueues bytes to master and resolves when drained")
func writeResolvesAfterDrain() async throws {
    let host = try PTYHost(clock: FakeClock(), log: .testing)

    try await host.write(Data("hello\n".utf8))

    let received = try await host.outboundBytes.first(timeout: .seconds(1))
    #expect(received == Data("hello\n".utf8))
}
```

The test name tells the reader what the test proves. The body proves it. Full discipline in §7.

### 1.10 Resource cleanup is symmetric and obvious

For every acquire there is a release, and the release is visually obvious in the same scope.

**`defer` for in-function symmetric cleanup:**

```swift
let fd = open(path, O_RDONLY)
guard fd >= 0 else { throw ... }
defer { close(fd) }
// ... use fd ...
```

**`deinit` precondition for reference types and actors that own resources:**

```swift
deinit {
    precondition(
        state == .closed,
        "PTYHost deinit while \(state) — call close() before dropping the last reference"
    )
}
```

The precondition is a contract: if you drop the last reference without closing, the program faults. We'd rather find that in debug than ship it.

**Why:** the reader should never have to scan the whole file to learn who frees what.

### 1.11 Concurrency boundaries are deliberate

- `actor` for any type that owns serialized mutable state.
- `@MainActor` *only* where SwiftUI demands it (inside the UI layer; never in domain modules).
- Structured `async let` and `withTaskGroup` over unstructured `Task {}`. Unstructured tasks exist at exactly three places: app lifecycle (`@main`), `NWListener` connection accept handlers, and signal source callbacks. Nowhere else.
- Every `nonisolated(unsafe)` and every `@unchecked Sendable` carries a comment that **proves** the safety, not just asserts it.

```swift
/// Safety: mutable state is protected by `lock`; callbacks never access it
/// without first taking the same lock.
final class SwiftTermDelegateBridge: @unchecked Sendable { ... }
```

Every `@unchecked Sendable` or `nonisolated(unsafe)` must carry a local proof-comment explaining the ownership or locking rule that makes it safe. Deep treatment in §11.

### 1.12 Whitespace is punctuation

- Single blank line between method groups. Never two. Never zero.
- Methods within a type are ordered by importance, not alphabetically: lifecycle (init, deinit) → primary behavior → query accessors → private helpers.

The reader should be able to scan the type's method list and know what it does in priority order.

### 1.13 Imports tell a story

Three groups, blank-line separated:

```swift
import Foundation
import os

import SwiftTerm

import AgentCore
import AgentProtocol
```

System frameworks first, alphabetically. SPM dependencies second, alphabetically. Local modules third, alphabetically. No unused imports. No `import Foundation` if the Swift standard library covers what you need.

### 1.14 Magic numbers go to a named constant

```swift
// Bad
if segment.confidence < 0.6 { ... }

// Good
private static let confidenceFloor: Float = 0.6
// ...
if segment.confidence < Self.confidenceFloor { ... }
```

Even better, hoist user-tunable constants into `Theme` or `Constants` so they live in one file.

### 1.15 Naming honours English

Method calls should read aloud as sentences. Argument labels supply prepositions.

- `engine.send(.cancelCurrentTurn)` not `engine.sendCancelCurrentTurnCommand()`
- `host.write(bytes, to: master)` not `host.writeBytes(bytes, master: master)`
- `parser.feed(buffer)` not `parser.processInputData(data: buffer)`
- Booleans are predicate phrases: `isAltScreen`, `hasPendingPrompt`.
- Async functions get no suffix; the `async` keyword tells the reader.
- Types are nouns. Methods are imperative verbs.
- Avoid `Manager`, `Handler`, `Helper`, `Util`, `Service`. They are placeholders for missing names. Find the real one: `PTYHost`, not `PTYManager`. `ChildReaper`, not `ChildProcessHandler`.

### 1.16 No dead code, ever

A file with commented-out blocks does not pass review. Git is the archive. If you might need the old version, `git log -p path/to/file` will find it.

The same goes for `TODO` comments without an issue link. Either write `// TODO(#123): …` or delete the comment.

### 1.17 Premature DRY is the enemy

Two callers is not the extraction threshold. Three is. When you see duplication between exactly two call sites, ask: *do these two sites have the same reason to change?* If yes, extract. If no, leave the duplication — coupling them now is more expensive than the duplication.

**Why:** the moment you extract a shared helper, the helper becomes a coupling point. The first caller drives its design. The second arrives needing slightly different behavior; you parameterize. The third arrives and the helper has three modes and an `if first { ... } else if second { ... }` body, and changing any one caller forces you to reason about the other two.

The cost of duplication is low; the cost of bad abstraction is high. Wait for evidence.

---

## 2. The reference exemplar — `PTYHost`

Before any other module ships, `PTYHost` is built to perfection. Its file header reads:

```swift
/// Reference style exemplar — see /docs/style/code-style.md.
```

Every subsequent module is reviewed against the question: *does this read like `PTYHost`?* When a reviewer cannot articulate what's wrong with a piece of code, they open `PTYHost.swift` side-by-side and the contrast usually makes the answer obvious.

`PTYHost` carries every aesthetic in this document:

- File-level doc paragraph
- Public surface first, private state second, helpers third
- Typed error enum (`PTYError`)
- Injected `Clock` and `Logger`
- Structured concurrency (actor + `AsyncStream.makeStream`)
- `deinit` precondition
- Logging with explicit privacy levels
- Full doc-comments on every public symbol describing contracts (not implementation)
- Golden Swift Testing suite with deterministic fixtures

When this file is done, it is the answer to "show me what good looks like."

---

## 3. Hard rules (lint-enforceable)

Checked by SwiftLint, SwiftFormat, custom scripts, and CI. A pull request that violates any of these fails the build.

- **One public type per file.** File name == type name. No `Models.swift` grab bags.
- **Soft file cap 200 lines, hard cap 400.**
- **Soft function cap 30 lines, hard cap 60.**
- **No `// MARK: -` clutter.** If you need section dividers, the file is too big.
- **No comments that describe *what* code does.** Comments only for *why*.
- **No `Manager` / `Handler` / `Helper` / `Util` / `Service` suffixes** (with the noted exception for genuinely-named services like `PairingService`).
- **No force unwraps (`!`)** outside trivial literals. No `try!` outside test fixtures. No `as!` ever.
- **No `Any` or `[String: Any]`.** Always typed.
- **No direct framework calls outside `External/` wrappers.** Forbidden anywhere except `*/External/*.swift`, `*/Network/LiveNetworkTransport.swift`, `*/Network/InMemoryNetworkTransport.swift`, and `**/CPosixBridge/**`. See §18.5 for the full rationale. Specifically:
    - `Foundation.Process` → use `ProcessRunner`
    - `Security.SecItem*` → use `KeychainStore`
    - `CoreServices.FSEventStream*` → use `FSEventsStream`
    - `Network.NWListener` / `NWConnection` → use `NetworkTransport`
    - `Foundation.NetService` / Bonjour `NWListener.Service` → use `BonjourBroadcaster`
    - `AVFoundation.AVSpeechSynthesizer` → use `SpeechSynthesis`
    - `AVFoundation.AVAudioEngine` + `Speech.SFSpeechRecognizer` → use `SpeechCapture`
    - `UserNotifications.UNUserNotificationCenter` → use `SystemNotifications`
    - `Foundation.URLSession` (for our own networking) → use `NetworkTransport`

    Enforced by `scripts/check-direct-framework-calls.swift` in CI.
- **No `print`.** Use `os.Logger`.
- **No `Date()`, `Int.random`, `ProcessInfo.processInfo.environment`, `FileManager.default`** outside `Core/AgentCore/Seams/Live*.swift` and `*/External/*.swift`.
- **No `nonisolated(unsafe)` or `@unchecked Sendable`** without a proof-comment.
- **No singletons** except `AdapterRegistry.shared` (justified as a discovery point).
- **No protocol with one production implementation** unless it's a test seam.
- **Errors are typed.** Swift 6.2 `throws(SomeError)` where the surface allows.
- **`TODO` without an issue link is deleted in review.** `// TODO(#123): …` or nothing.
- **No commented-out code in main.**
- **No two consecutive blank lines.**
- **Function parameter count ≤ 5.**
- **One `padding`, one `background`, one `clipShape`** per SwiftUI view — never lasagna.
- **No `fileprivate`** without justification (see §9).
- **No `internal` keyword** — it's the default; spelling it explicitly is noise.
- **`final class`** for every non-actor reference type. Inheritance requires written justification.

---

## 4. Naming conventions

- **Types**: nouns. `PTYHost`, `AgentEvent`, `DiffHunk`. Not `IPTYThing`, `EventData`, `DiffHunkObject`.
- **Methods**: imperative verbs. `resize(rows:cols:)`, not `setSize(rows:cols:)`. `parse(_:)`, not `parseInput(input:)`.
- **Booleans**: predicate phrases. `isAltScreen`, `hasPendingPrompt`, `canCancel`.
- **Async**: no `Async` suffix; the keyword tells the reader.
- **Generic placeholders**: meaningful, not `T`. `func register<Adapter: AgentAdapter>(_:)`.
- **File names**: match the public type. `PTYHost.swift` declares `PTYHost`.
- **Test names**: read as sentences. `writeResolvesAfterDrain`, `decoderRejectsMalformedFrame`.
- **Acronyms**: lowercase except when leading. `pty` everywhere except `PTYHost`. `jsonDecoder`, `JSONDecoder`. `url`, `URL`. `id`, `ID`.
- **Underscore-prefix** is forbidden. Private state has no decoration.
- **Hungarian notation** is forbidden. `bytesData: Data` is wrong; just `bytes`.
- **Plural for collections, singular for elements.** `events: [AgentEvent]`, `event: AgentEvent`. Never `eventList`, `eventArray`.
- **Enum cases**: lowerCamelCase, no `case` prefix repetition. `case running` not `case stateRunning`.
- **Static factories**: `make…` for constructors that aren't `init`. `AsyncStream.makeStream()`.
- **Configurable defaults**: declare them as named static constants, not parameter defaults, when more than one caller would supply the same value.

---

## 5. Swift idiom

- Prefer **value types** unless reference semantics are essential.
- Prefer **enums with associated values** over flag soups.
- Prefer **`guard`** early returns over nested `if`.
- Prefer **trailing closure** for single closures, **named** when multiple.
- Prefer **`some View`** over `AnyView`; `AnyView` only when erasing for `ForEach` of heterogeneous content.
- Prefer **`@Observable`** + `@Environment(\.someClass)` over `@EnvironmentObject` / `ObservableObject`.
- Prefer **pure functions** for parsing; the parser actor is just a serial queue around them.
- Prefer **small, composable views**; if a SwiftUI view has more than 5 `@State` properties, extract a view model.
- Prefer **`for try await`** over manual stream iteration.
- Prefer **`withCheckedThrowingContinuation`** over completion handlers when bridging legacy APIs.
- Prefer **`[String]`** over `Array<String>`, **`[String: Int]`** over `Dictionary<String, Int>`.
- Prefer **`Duration`** over `TimeInterval`.
- Use **`Result.success(...)`** over manual tuples for fallible synchronous APIs that can't `throw`.
- Use **`switch`** over chained `if let`/`if case let` when matching multiple cases.
- Use **`@frozen public enum`** for wire-protocol enums where exhaustive matching outside the module is desirable (we own the schema).
- Use **`@usableFromInline`** only when measurement proves cross-module inlining matters.
- Use **`borrowing` / `consuming` ownership modifiers** only where measurement justifies the readability cost.

---

## 6. View aesthetic (SwiftUI)

- A view's `body` reads top-to-bottom like prose. If you need to scroll to read one view, extract pieces.
- One `padding`, one `background`, one `clipShape` per stack, in that order, at the end. No lasagna.
- View modifiers are **vertical**, one per line. Easier to diff, easier to scan.
- Colors come from `Theme` (an enum namespace), not `Color.red` sprinkled inline.
- Spacing comes from `Theme.spacing` (`s4 / s8 / s12 / s16 / s24 / s32 / s48 / s64`), not magic numbers inline.
- **Every interactive element has `.accessibilityLabel(_:)`** matching its visible text or `.help` value. Icon-only buttons fail review without one. `scripts/check-a11y.swift` enforces this in CI.
- **`#Preview { ... }`** for every view, ideally with a `MockAdapter` fixture state. Not optional.
- **`@Observable` view models** for any view with logic; views are dumb projections.
- **Bindings** flow down; events flow up via closures or `AgentCommand`. Two-way bindings are restricted to native `TextField`-shaped controls.
- **Layout containers** are explicit: `VStack(alignment:spacing:)`. Never rely on default spacing — name it.

**Good:**

```swift
struct AssistantBubbleView: View {
    let block: AssistantTextBlock

    var body: some View {
        ProseText(block.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.spacing.s16)
            .background(Theme.surface.bubble, in: .rect(cornerRadius: 12))
    }
}
```

**SwiftUI anti-patterns we refuse:**

- `Color.red`, `Color(.systemRed)`, `Color(red: 0.95, green: 0.2, blue: 0.2)` outside `Theme.swift`
- Magic spacing: `.padding(16)`, `.padding(.top, 24)` outside `Theme.swift`
- View modifiers on one line: `Text("x").padding().background(.red).clipShape(...)`
- Implicit `@State` in views that are larger than ~80 lines — extract a view model
- `GeometryReader` for anything except absolute-positioned overlays
- View body that conditionally returns different view types without `Group` or `@ViewBuilder`

---

## 7. Test aesthetic

We use **Swift Testing** (`@Test`, `#expect`, `#require`), not XCTest.

### Structure

```swift
@Test("HeartbeatActivityMonitor emits noEventGap every 500ms while busy")
func heartbeatTickRate() async throws {
    let clock = FakeClock()
    let monitor = HeartbeatActivityMonitor(clock: clock)
    await monitor.enterTurn()

    clock.advance(by: .milliseconds(500))
    let firstGap = try await monitor.events.first(timeout: .milliseconds(10))

    #expect(firstGap == .noEventGap(turnID: monitor.currentTurnID, elapsed: .milliseconds(500)))
}
```

### Rules

- **Names read as English sentences.** The reader knows what the test proves before reading the body.
- **One behavior per test.** Multiple `#expect`s are fine if they all describe the same behavior.
- **Arrange / Act / Assert separated by single blank lines.** Single-section tests don't need separation; multi-section tests do.
- **Time, randomness, environment, FS always injected** via `AgentTestSupport` fakes. Tests run in milliseconds.
- **Golden fixtures** live in `tests/.../Fixtures/` and are version-controlled. A fixture is part of the spec.
- **Property-based tests** for codecs (`AgentEventWire` round-trips, `AgentCommand` JSON, regex parsers). Use `@Test(arguments:)` with generated cases.
- **`#require`** for setup that must succeed before the test can proceed; `#expect` for the behavior being tested.
- **Test parameters** via `@Test(arguments:)` for table-driven cases — never copy-paste a test body to vary one argument.
- **No `Thread.sleep`** in tests, ever. Use `FakeClock.advance(by:)` or `withCheckedContinuation`.
- **No `XCTSkip`**. If the test cannot run in this configuration, restructure or remove.
- **`@Test(.disabled("reason"))`** is allowed but requires a linked issue.

### Fixture organization

```
tests/Remote/RemoteParityTests/
├── WireCodecParityTests.swift
├── CommandDispatchParityTests.swift
└── Fixtures/                      # golden wire-frame JSON (version-controlled)
    └── README.md

tests/AgenticCLIs/ClaudeCode/ClaudeAdapterTests/
├── ClaudeHookDecoderTests.swift   # inline JSONL / hook payloads in test sources
├── TranscriptTailerTests.swift
└── …

tests/Core/AgentCoreTests/
├── PTYHostTests.swift             # no on-disk fixtures — uses /bin/echo, /bin/cat
└── …
```

- **Wire goldens** live under `tests/Remote/RemoteParityTests/Fixtures/` (processed as SPM resources).
- **Parser / hook / transcript payloads** are usually inline in the matching suite under `tests/Core/…`, `tests/AgenticCLIs/…`, or `tests/Remote/…`.
- When a suite needs binary or large on-disk data, add a co-located `Fixtures/` subfolder next to that suite and hide paths behind a static factory (e.g. `Fixtures.helloWorldSession()`).

### What we do not test

- Pixel-perfect SwiftUI snapshots (flaky across OS versions). We assert "no crash + key text present."
- Platform UI rendering (covered by manual QA).
- Network round-trips to real servers (covered by integration tests in a separate CI lane).

### Performance tests

- Use `swift-collections-benchmark` or measure explicitly with `ContinuousClock`.
- Live in `tests/.../Benchmarks/`, run on a separate CI job (not blocking).
- Have a baseline tracked in git; PRs that regress baseline ≥10% require justification.

---

## 8. Documentation & DocC

Our public surface is documented for **DocC**. Every public symbol has a doc-comment that explains *contract*, not *implementation*. Internal symbols may have doc-comments where they aid the next reader.

### Anatomy of a good doc-comment

```swift
/// Sends `bytes` to the master file descriptor.
///
/// Blocks the caller until the kernel accepts every byte. The actor serializes
/// concurrent writers; the call returns in submission order, not write order.
///
/// - Parameter bytes: the payload to write. May be empty (no-op).
/// - Throws: `PTYError.writeFailed` if the kernel refuses the write;
///           `PTYError.alreadyClosed` if `close()` has been called;
///           `CancellationError` if the surrounding task is cancelled.
public func write(_ bytes: Data) async throws(PTYError)
```

Structure:

1. **One-sentence summary**, ending in a period. Reads as a noun phrase or imperative.
2. **One paragraph of context** about lifecycle, threading, or invariants — only if the signature alone doesn't tell the whole story.
3. **`- Parameter` / `- Returns` / `- Throws`** sections in that order. Skip them if the names speak for themselves.
4. **Optional `## Example`** Markdown section for non-obvious usage.
5. **Optional `## See Also`** linking to related symbols.

### Anti-patterns

- Repeating the function name in the summary: `/// Writes the bytes.` (delete; the name is `write(_ bytes:)`).
- Describing the implementation: `/// Calls write(2) in a loop.` (delete; readers can read the body).
- Doc-commenting trivial getters: `/// Returns the count.` (delete).

### DocC ergonomics

- **Symbol links** in prose: `` `PTYHost.write(_:)` `` — DocC renders these as navigable links.
- **Code samples** in triple-backtick fences with `swift` syntax tag.
- **`@available(...)`** annotations are added precisely where needed; never blanket-applied to a whole module. Use the platform list your project targets (e.g., `@available(macOS 14, iOS 17, *)`).
- **`@_documentation(visibility: internal)`** to hide a public-by-necessity symbol from generated docs (we own the type but don't want it in the docs).
- **Tutorials** (`.tutorial` files) are reserved for the README path — not maintained per-symbol.

### Doc generation

DocC catalogs live in `src/<Target>/Documentation.docc/`. Each public target has one. CI builds docs and treats DocC warnings as errors. Symbol coverage is checked: ≥90% of public symbols carry a non-trivial doc-comment.

### File-level doc comments

Every Swift file starts with a file-level paragraph:

```swift
/// Owns the master file descriptor of a pseudo-terminal and serialises
/// all reads and writes against it. Construct with a workspace and an
/// initial window size; the host is hot from `init` and yields bytes
/// on `outboundBytes`. Always `close()` before the last reference is
/// dropped — `deinit` will fault otherwise.
```

This is the first thing the reader sees, before any imports.

---

## 9. Access control

The default is **internal** (the absence of an access keyword). We never write the word `internal`.

Decision rules:

- **`public`** — exposed to consumers of the module. Every `public` symbol is a contract the team commits to. Adding `public` is a deliberate act; reviewing PRs that introduce `public` is a checklist item.
- **`package`** — visible across modules within the same Codemixer package, but not to external consumers (relevant for `Codemixer`'s internal targets). Use it when one target needs to consume another's symbol without expanding the public API. We expect to use `package` heavily for cross-target glue.
- **internal** (default) — within the target. The lazy default.
- **`private`** — within the type or extension. Default for any state or helper that has no consumer outside the type.
- **`fileprivate`** — generally avoided. Its existence usually means the file should be split. Allowed only when an extension at file scope needs access to private members of a type also defined in the file, and splitting the file would harm cohesion. Requires a one-line justification comment.

### Examples

```swift
public actor PTYHost {                  // module-API entry point
    public let outboundBytes: AsyncStream<Data>   // contract

    package let masterFD: Int32         // visible to AgentRemoteControl for inspection
                                        // but not to external SDK consumers

    private let io: DispatchIO          // implementation detail
    private var state: State            // implementation detail
}
```

### Anti-patterns

- `internal` written explicitly. Just remove the keyword.
- `public` on a property that doesn't need to be a contract. Demote.
- `fileprivate` because you couldn't think of where to put a helper. Move the helper into the type as `private` or split the file.
- `open class` — we never inherit across modules. `public final class` instead.

---

## 10. Protocol design

Protocols are the most-abused tool in Swift. Pinned rules:

### When to write a protocol

1. **A genuine test seam** with one production impl and one fake (`Clock`, `RandomSource`, `FileSystem`, `Environment`, `AgentAdapter`).
2. **A polymorphic boundary** with ≥2 production implementations (`AgentAdapter` — Claude today, Codex tomorrow).
3. **A capability witness** that lets the compiler enforce a constraint generically (`Sendable`, `Hashable`).

If your motivation is none of the above, write a struct or enum.

### Protocol shape

- **Small surface.** A protocol with 12 methods is a class in disguise. Split.
- **Names describe a role**, not a hierarchy. `AgentAdapter`, not `AgentAdapterBase`. `Clock`, not `ClockProtocol`.
- **`associatedtype`** with constraints when you need type-level polymorphism. Use `where` clauses to keep call sites readable.
- **Default implementations** in protocol extensions are allowed but treated as a hazard — they're invisible at call sites and override resolution is subtle. Prefer free functions or a base value type.
- **`Self` constraints** for value-equality-style protocols (`Equatable`, `Hashable`). Never `Self` constraints on cross-module protocols you want to extend later.
- **No PATs (protocols with associated types) at API boundaries** unless the consumer benefits. They're often replaced by `some` / `any` more cheaply.
- **Existential types (`any P`)** for type-erased storage. Generic constraints (`<T: P>`) for performance-critical hot paths. The default is `any`; switch to generic only when measurement proves it matters.

### Anti-patterns

- **Empty marker protocols.** Use a `@frozen enum` or a tagged struct.
- **`AnyObject` constraint** on a protocol to enable `weak` references. Use class-only protocols only when the implementation truly must be a reference type; prefer not to.
- **One-method protocols whose method is a closure equivalent.** `protocol Notifier { func notify() }` can be `let notify: () -> Void`. Pick the closure unless you need testability via mocks (then the protocol earns its keep).
- **Protocol inheritance** more than one level deep. If `A: B: C`, flatten.

### Protocol composition

```swift
public typealias AgentSignal = Sendable & Codable
```

We use composition aliases to name capability bundles.

---

## 11. Async & concurrency patterns

Swift Concurrency is powerful and dangerous. The rules below prevent the dangerous parts.

### Actor or `@MainActor`?

- **`actor`** for serialized mutable state owned by a non-UI component.
- **`@MainActor`** *only* in the UI layer, where SwiftUI requires it.
- **`actor`** is the default; only opt into `@MainActor` for genuine UI work.

### Structured vs unstructured concurrency

- Prefer structured: `async let`, `withTaskGroup`, `withThrowingTaskGroup`, `withDiscardingTaskGroup`. Cancellation flows automatically.
- Unstructured `Task { ... }` is allowed at exactly three sites:
  1. App entry (`@main`).
  2. `NWListener.newConnectionHandler` (each connection is its own root task).
  3. `DispatchSourceSignal` callbacks (signal handlers).
- Every unstructured `Task` has a captured `[weak self]` if `self` is a class/actor reference.
- Every unstructured `Task` either is awaited, stored in a `Set<Task<Void, Never>>` for cancellation, or is documented as fire-and-forget with a justification comment.

### Cancellation

- **Always check** `Task.isCancelled` at logical sub-step boundaries inside long-running tasks.
- **`Task.checkCancellation()`** to early-exit with `CancellationError`.
- **Streams** must surface cancellation: when a consumer's `for await` loop exits, the producer's continuation must `.finish()`.
- **`withTaskCancellationHandler`** wraps any operation whose cancellation requires action (closing a file descriptor, sending a SIGTERM).

```swift
public func write(_ bytes: Data) async throws(PTYError) {
    try await withTaskCancellationHandler {
        // ... the write path ...
    } onCancel: {
        // signal handler; runs synchronously, must be Sendable
        Task { await self.abortPendingWrite() }
    }
}
```

### `AsyncStream` and `AsyncSequence`

- **`AsyncStream.makeStream(of:)`** for producer/consumer with a single producer.
- **`AsyncThrowingStream`** for streams that can fail.
- **Buffering policy** explicit: `.bufferingNewest(_:)` is the default for hot streams (we drop oldest under backpressure). `.unbounded` requires a justification — unbounded buffers are unbounded bugs.
- **One consumer per stream.** Multi-consumer fan-out goes through `MulticastEventBus`.
- **`continuation.finish()`** is always called — in a `defer`, in a deinit, or in an explicit lifecycle hook.

### Actor reentrancy

An actor that `await`s during a method call **releases its isolation** for the duration of the await. Other actor messages can interleave. This is the most-misunderstood part of Swift Concurrency.

- Treat actor methods as cooperative, not atomic.
- If you read state, `await` something, then write state, the read may be stale.
- The fix: **snapshot the state you need before the await**, or restructure to avoid the await between read and write.

```swift
// Bad — `count` may be stale by the time we write
actor Cache {
    var count = 0
    func record() async {
        let old = count
        await Task.sleep(for: .milliseconds(1))   // releases isolation
        count = old + 1                            // race with concurrent record()
    }
}

// Good — no await between read and write
actor Cache {
    var count = 0
    func record() async {
        count += 1
        await Task.sleep(for: .milliseconds(1))
    }
}
```

### Sending parameters & isolation regions

Swift 6's `sending` keyword (and region-based isolation) is used at:

- **`MulticastEventBus.subscribe()`** — yields a `sending` continuation so the subscriber owns it without an extra `Sendable` wrapper.
- **Adapter spawn paths** — sending the spawned `AgentInputs` across the actor boundary.

Wherever `sending` would let us drop a `@Sendable` constraint, we use it.

### `withCheckedThrowingContinuation`

Use only when bridging genuinely-callback-based APIs (legacy delegate-style frameworks, `Network.framework` connection completion). Three rules:

1. **Resume exactly once.** Hold a `resumed` flag if the callback could fire multiple times.
2. **Handle cancellation.** `withTaskCancellationHandler` around the continuation.
3. **Document** the callback's threading and re-entrancy at the call site.

### `Task.detached`

Forbidden except in app entry. Detached tasks lose priority and isolation context, which means they're almost always wrong.

### `DispatchQueue` interop

`DispatchIO` for high-throughput file-descriptor reads is allowed — measurement showed it's the right tool. Beyond that, `DispatchQueue` exists only at framework boundaries that haven't been bridged to Swift Concurrency yet.

### Concurrency safety checklist

Every PR that touches concurrency code answers:

- Is there an `actor` or `@MainActor` annotation on every mutable shared state?
- Does every `Task { }` have a parent or a captured set?
- Does every `AsyncStream` consumer's exit `.finish()` its continuation?
- Does every actor method that awaits between read-and-write re-read after the await?
- Build with `-strict-concurrency=complete` — zero warnings.

---

## 12. Logging

Per-module `Logger` instances. Subsystem is `com.codecave.Codemixer` everywhere; category is the module name.

```swift
private let log = Logger(subsystem: "com.codecave.Codemixer", category: "PTYHost")
```

### Levels

| Level | When |
|---|---|
| `debug` | Chatty internals; off in release by default |
| `info` | Routine lifecycle events (process started, file opened) |
| `notice` | Rare and meaningful (session resumed, daemon restarted) |
| `error` | Something is broken |
| `fault` | Invariant violation; should never happen — use `Logger.fatal` extension |

### Privacy quick reference

| Data | Privacy |
|---|---|
| Process id, port, errno, duration, count | `.public` |
| Prompt text, transcript text, file path, env value | `.private` |
| Session id, agent id (constant-shaped, not user content) | `.public` |
| Workspace path | `.private` |
| Bearer tokens, secrets, PII | `.private` (and never logged above `debug`) |

### The `Logger.fatal` extension

```swift
extension Logger {
    /// Asserts in debug, `os_log_fault`s in release. Use for invariant violations.
    func fatal(_ message: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) -> Never {
        let msg = message()
        self.fault("\(msg, privacy: .public) at \(file, privacy: .public):\(line, privacy: .public)")
        #if DEBUG
        assertionFailure(msg)
        #endif
        // os_log_fault is non-fatal; force termination if we got here
        fatalError(msg, file: file, line: line)
    }
}
```

### Anti-patterns

- `print(...)` — forbidden by lint.
- String interpolation without privacy levels — every interpolation in a `Logger` call MUST carry `privacy:`.
- Sensitive data at `info` or above — even `.private` should be omitted unless the level justifies it.
- Logger as singleton across modules — each module owns its category.

---

## 13. Error handling

### Typed errors per module

`PTYError`, `SpawnError`, `HookError`, `TranscriptError`, `RemoteControlError`, `PairingError`, `DiffError`, etc. Each carries rich associated values. Each is `Codable` if it crosses the network boundary.

```swift
public func resize(rows: Int, cols: Int) throws(PTYError) {
    // ...
}
```

When a function calls into a typed-throws function but doesn't want to propagate the specific type, it widens to `Error`:

```swift
public func setup() async throws {
    try await openpty()   // throws(PTYError) — caller doesn't care which
    try await spawn()     // throws(SpawnError)
}
```

### Error mapping at module boundaries

When an error crosses a module boundary, the receiving module **wraps** it in its own typed enum, preserving the cause:

```swift
public enum AgentEngineError: Error, Sendable, Codable {
    case ptyUnavailable(cause: PTYError)
    case spawnFailed(cause: SpawnError)
    case hookListenerFailed(cause: HookError)
    // ...
}
```

The wrapper preserves the original error verbatim. This means a remote client sees `AgentEngineError.spawnFailed(cause: .spawnFailed(executable: ..., errno: ..., posixDescription: ...))` — full fidelity through the wire.

### User-facing error strings

User-facing messages live in one file per module (`AgentCoreErrorMessages.swift`), not interleaved with error definitions. The file maps each error case to a `LocalizedStringKey`. This keeps localization clean (§21) and lets us tune wording without recompiling the type definitions.

```swift
extension PTYError {
    public var userFacingMessage: LocalizedStringKey {
        switch self {
        case .openptyFailed:       return "Couldn't open a pseudo-terminal."
        case .spawnFailed:         return "Couldn't start the agent process."
        case .writeFailed:         return "Lost the connection to the agent."
        case .resizeFailed:        return "Terminal resize failed."
        case .alreadyClosed:       return "The session was already closed."
        }
    }
}
```

### What to throw vs return

- **Throw** when the failure is the *exception*, not the *expectation*. Network errors throw; "no matching session" returns `nil`.
- **Return `Result`** only for synchronous operations that can't `throw` (delegate callbacks, completion-handler bridges).
- **Optionals** for "nothing here" results, never for errors.

### Forbidden

- `throws -> any Error`
- `try?` to swallow
- `try!` outside `tests/.../Fixtures/`
- `as!` ever
- `Error` instances without typed-enum backing

---

## 14. Codable & wire encoding

### Always-explicit CodingKeys

```swift
public struct AttachmentRef: Codable, Sendable {
    public let id: UUID
    public let kind: Kind

    enum CodingKeys: String, CodingKey {
        case id
        case kind
    }
}
```

Even when the names match. Pinning `CodingKeys` makes wire compatibility a single-file decision.

### Schema versioning

Every wire frame carries a `"v": 1` field. The decoder reads `v` first; unknown versions become a typed `WireError.unsupportedVersion(Int)`.

```swift
public struct ClientFrame: Codable, Sendable {
    public let v: Int
    public let payload: Payload

    public init(payload: Payload) {
        self.v = 1
        self.payload = payload
    }
}
```

Adding a non-breaking field is allowed without bumping `v`. Removing or renaming a field requires bumping `v` and writing a migration decoder.

### Custom `init(from:)`

Write a custom decoder when:
- The wire schema diverges from the in-memory shape (e.g., dates serialized as ISO-8601 strings, durations as nanoseconds).
- Decoding is fallible in a way the synthesized decoder can't express.
- You need to validate invariants at decode time.

Otherwise, let synthesis do its job. Don't write boilerplate.

### Wire DTOs vs domain types

Wire types (`AgentEventWire`, `ClientFrame`, etc.) live in `AgentProtocol` (Foundation-only, no platform deps). Domain types (`AgentEvent`, `AgentState`) live in `AgentCore` and use `URL`, `Date`, `Duration`. A `WireCodec` in `AgentProtocol` translates between them at the network boundary.

```swift
// In AgentProtocol
public struct AgentEventWire: Codable, Sendable {
    public let kind: String
    public let payload: Data
}

// In AgentCore
public enum AgentEvent: Sendable { /* domain shape */ }

extension AgentEvent {
    public func toWire() -> AgentEventWire { /* ... */ }
    public static func from(wire: AgentEventWire) throws -> AgentEvent { /* ... */ }
}
```

Round-trip property tests (in `AgentProtocolTests`) assert `from(wire: event.toWire()) == event` for every case.

### Strategy choices (pinned)

- **`JSONEncoder.keyEncodingStrategy = .useDefaultKeys`** — `CodingKeys` is the contract; don't transform.
- **`JSONEncoder.outputFormatting = .sortedKeys`** in release; `[.prettyPrinted, .sortedKeys]` in debug.
- **`dateEncodingStrategy = .iso8601`** for human-readable timestamps. Numeric epochs are for performance-critical paths only.
- **`dataEncodingStrategy = .base64`** for embedded binary blobs.

### Forbidden

- `[String: Any]` decoding of "unknown" fields. If a field is unknown, error explicitly.
- `JSONSerialization` for typed payloads — `JSONDecoder` always.
- `unkeyedContainer` for fixed-shape data — use `keyedContainer` so the schema is self-documenting.

---

## 15. Extensions & namespace hygiene

### What extensions you may write

- **Extensions of your own types** — add methods that didn't fit in the primary definition, or organize by capability (e.g., `PTYHost+Spawning.swift`).
- **Extensions of your own protocols** — default implementations, but read §10 first.
- **Extensions of stdlib types** in a clearly-named file. `String+ShellQuoting.swift` extending `String` to add `shellQuoted` is OK. The file name signals that the extension is purpose-built and small.

### What extensions you may not write

- **Cross-module retroactive conformances** without `@retroactive` (Swift 6 requires it; we use it sparingly).
- **Extensions of `Optional`** — produces baffling call sites. Use free functions.
- **Extensions of `Any`-shaped types** (`Codable`, `Sendable`) with non-protocol-related additions — they pollute every conforming type.
- **One-off helper extensions in a 500-line `Extensions.swift`** — split per source-type per capability.

### Extension file naming

```
PTYHost+Spawning.swift     ← extension on PTYHost related to spawning
String+ShellQuoting.swift  ← extension on String adding shell-quoting helpers
URL+Workspace.swift        ← extension on URL adding workspace-aware helpers
```

Each extension file is < 100 lines. If it grows beyond that, split by capability or move the helpers into a value type.

### Protocol conformances

- **Conformances declared with the type when natural.** `Equatable`, `Hashable`, `Codable`, `Sendable`.
- **Other conformances in an extension** at the type's primary file or a `+Conformances.swift` companion.
- **Conditional conformances** (`extension Foo: Bar where T: Baz`) are powerful but should be tested.

---

## 16. Memory & references

Swift's ARC is mostly invisible, but a few patterns demand attention.

### `weak` vs `unowned` vs strong

- **strong (the default)**: the lifecycle is the same as or longer than this reference. Most cases.
- **`weak`**: the referenced object may go away before this reference. The reference becomes `nil`. Always `Optional`.
- **`unowned`**: the referenced object will always outlive this reference (we've proved it lexically). Crashes if violated. Use sparingly.

Rule of thumb: **`weak` for ownership boundaries, `unowned` only when the lifecycle is obviously tied (e.g., `self` inside a closure called only during `self`'s lifetime).**

### Closure capture lists

```swift
// Bad — strong cycle if listener is owned by self
nwListener.newConnectionHandler = { connection in
    self.handle(connection)
}

// Good
nwListener.newConnectionHandler = { [weak self] connection in
    Task { await self?.handle(connection) }
}
```

- **Default to `[weak self]`** in any closure that escapes (stored, async, callback).
- **`[unowned self]`** only when the closure is provably called only during `self`'s lifetime AND escapes (otherwise `[weak self]` is free).
- **No capture list** for non-escaping closures (e.g., `forEach`).

### Reference cycles to watch

- **Closures stored on the object that captures `self`.**
- **Delegate patterns** where parent owns child and child holds parent reference. Child's reference must be `weak`.
- **Notification observers** holding tokens — store the token and `NotificationCenter.default.removeObserver(token)` in `deinit`.

### `autoreleasepool`

Almost never needed in Swift. The cases:
- Loops that produce many Foundation `Data`/`NSString` instances in tight inner loops — wrap each iteration in `autoreleasepool { ... }`.
- Otherwise, ignore.

### `deinit` for owned resources

Every reference type (`class`, `actor`) that owns a kernel resource (file descriptor, socket, mach port) has a `deinit` precondition asserting the resource was released. We'd rather crash in debug than leak in release.

---

## 17. Performance & measurement

**Rule zero: measure before optimizing.** Without a benchmark, optimization is decoration.

### Tools

- **`signpost(_:)` / `OSSignposter`** [Apple cross-platform] for tracing in Instruments. We use them at `AgentEngine` lifecycle boundaries and `PTYHost.write` so Instruments traces a session out of the box.
- **`ContinuousClock` / `SuspendingClock`** for in-process timing. `SuspendingClock` for cancellable waits.
- **`tests/.../Benchmarks/`** with `swift-collections-benchmark` style — git-tracked baselines.
- **Instruments** [Apple cross-platform development tool] — Time Profiler for CPU hot paths, Allocations for retain-cycle and leak investigation, System Trace for I/O-bound paths. The tool runs on macOS but can target a connected iOS / iPadOS / visionOS device.

### When to optimize

- A benchmark regressed ≥10% from baseline.
- A profile shows a single function dominating a hot path.
- A user-perceived latency exceeds the budget (composer keypress → render < 16ms, prompt-send → first ShimmerDot < 50ms, etc.).

### Patterns to prefer (with measurement)

- **Algorithm > micro-opt.** `Set` over linear scan of an `Array`. Sorted insertion over post-sort.
- **`reserveCapacity(_:)`** when the final size is known at the start.
- **`ContiguousArray<T>`** in tight loops over Foundation `NSArray`-bridged `Array`s.
- **Copy-on-write awareness**: don't write `var copy = original; copy.append(x); use(copy)` if you can mutate `original` directly.
- **`@inlinable`** for cross-module hot paths, *only* with measurement showing inlining matters and a willingness to pin the implementation across versions.
- **`borrowing` / `consuming`** parameters where copy avoidance matters in inner loops, measured.

### Patterns to avoid

- **String concatenation in loops** — use `String.appending` once or `String(joining:)`.
- **`Sequence.map { ... }.filter { ... }.reduce`** in hot paths — fuse into one loop if the profile demands it. Otherwise, readability wins.
- **`@_optimize(none)` or `@_specialize`** without measurement.
- **Eagerly converting `Data` to `[UInt8]`** when `Data` would do — `Data.withUnsafeBytes` is your friend.

### Latency budgets (Codemixer specific)

| Boundary | Budget | Source of truth |
|---|---|---|
| Composer keypress → render | 16ms | UI thread |
| Send → first ShimmerDot | 50ms | `AgentEngine.send(.sendPrompt(...))` → first emitted event |
| `noEventGap` tick | 500ms ±10ms | `HeartbeatActivityMonitor` |
| WebSocket frame parse | < 1ms typical, < 5ms worst case | `RemoteControlServer` |
| GitDiffEngine refresh | < 100ms for ≤ 100 changed files | `GitDiffEngine` |

CI runs benchmarks against these budgets; regressions block merge.

---

## 18. Security as code style

Security is not a separate concern; it's a way of writing.

### Input validation at boundaries

Every external input (PTY bytes, hook payloads, transcript JSONL, remote WebSocket frames, user prompts) is validated at the boundary that receives it. Internal code may then assume validity.

- **Length caps** on every byte buffer (PTY-byte-buffer cap is 8KB; WebSocket frames are 1MB by default).
- **JSON schema validation** for hook payloads — decode into the typed enum; reject malformed.
- **Regex anchors** for any user-supplied string that becomes an argv (commit hashes, branch names): allowlist regex *before* reaching `agent_posix_spawn`.

### Never `as!` untrusted data

Even after a successful `JSONDecoder.decode(_:from:)`, **don't** cast the result with `as!`. The decoder's contract proves the type; `as!` is a smell saying "I bypassed the contract."

### Secret handling

- **Secrets live in Keychain**, never in `prefs.json`, never in environment variables for our own processes.
- **Bearer tokens** are generated with `SecRandomCopyBytes` (32 bytes).
- **PIN compare** is constant-time (`Data.constantTimeEquals(_:)` helper). Never `==` on a PIN.
- **No secret in logs**, even at `.private`. We pin: secrets are never logged.

### Principle of least authority

The *principle* is universal: each module operates with the minimum capabilities it needs. The *enforcement mechanism* depends on the deployment target.

- **Disabled App Sandbox** [macOS — Codemixer-specific] does not mean "all code can do everything." Each module's contract is the smallest set of operations it needs. On iOS / iPadOS the sandbox is always-on; the same minimisation principle applies at the entitlement layer.
- **TCC purpose strings** [Apple cross-platform — `Info.plist`] are accurate ("Used to dictate prompts to Claude") — no copy-paste boilerplate. Applies on every Apple platform that prompts the user for capability access.
- **Hardened Runtime ON**, no `cs.*` exemptions [macOS]. iOS / iPadOS apps are equivalently restricted by default through code signing and the iOS runtime; no equivalent toggle exists.
- **`agent_posix_spawn`** [macOS — Codemixer-specific] is the only spawn path; no shell mode means no shell injection. iOS / iPadOS / visionOS do not permit arbitrary process spawning at all, so this section does not apply there.

### TLS

- **`NWParameters.tls`** with explicit cipher policy (TLS 1.3 minimum).
- **Self-signed cert** with cert pinning on the mobile client. Cert fingerprint embedded in the pairing QR code.
- **PIN attempts rate-limited** (1/sec, 5-attempt lockout for 5 min).

### Forbidden

- Constructing shell commands by string interpolation.
- Logging full prompt text or transcript text above `debug`.
- Storing secrets in `UserDefaults` or `prefs.json`.
- Disabling certificate validation, ever, even "temporarily for testing."

---

## 18.5 External integration boundaries

> **Rule.** Business code never imports Apple / system frameworks directly to make calls into them. Every call to `Foundation.Process`, `Security.SecItem*`, `CoreServices.FSEventStream*`, `Network.NWListener` / `NWConnection`, `AVFoundation.AVAudioEngine` / `AVSpeechSynthesizer`, `Speech.SFSpeechRecognizer`, `UserNotifications.UNUserNotificationCenter`, `Foundation.NetService`, `Foundation.URLSession` (for our own networking) — anything that crosses the Codemixer / Apple-framework boundary — goes through a single wrapper class.

### Where wrappers live

`src/<Module>/External/<Wrapper>.swift`. One wrapper per external surface; one file per wrapper; one production impl per wrapper. The current set:

| Wraps | Wrapper | Module |
| --- | --- | --- |
| `Foundation.Process` | `ProcessRunner` | `AgentCore` |
| `Security.SecItem*` | `KeychainStore` | `AgentCore` |
| `CoreServices.FSEventStream*` | `FSEventsStream` | `AgentCore` |
| `Network.NWListener` / `NWConnection` | `NetworkTransport` + `LiveNetworkTransport` | `AgentCore` |
| `Network.NWListener.Service` (Bonjour) | `BonjourBroadcaster` | `AgentRemoteControl` |
| `AVFoundation.AVAudioEngine` + `Speech.SFSpeechRecognizer` | `SpeechCapture` | `AgentUI` |
| `AVFoundation.AVSpeechSynthesizer` | `SpeechSynthesis` | `AgentUI` |
| `UserNotifications.UNUserNotificationCenter` + `NSSound` | `SystemNotifications` | `AgentUI` |

### Wrapper shape

A plain `actor` or `final class` (`@MainActor` when the framework requires it), file-level doc comment explaining what is wrapped and why, public surface ≤ 8 methods, typed error enum for failures. Not a protocol — we are not building DI seams here; we are confining the framework surface.

### Why this matters

1. **Portability.** When we add iOS / iPadOS / visionOS targets, the wrapper is the diff point. Business code reads the same.
2. **Auditability.** A grep for `Foundation.Process` returns exactly one file. Security review of every `SecItem*` call site is constant-time.
3. **Replaceability.** When Apple deprecates an API (this happens), the wrapper is the only file that changes.

### What "wrapper" does *not* mean

It is not a protocol seam with a fake implementation. It is not a re-export of every framework type. It is the smallest surface that lets business code express its intent without naming an Apple framework. If you find yourself adding a method that returns a `SecKeyRef` or `NWConnection`, you have the wrong boundary.

### Good / Bad

Good — business code in `CertificateManager` calls the wrapper:

```swift
_ = try await processRunner.run(executable: opensslURL, arguments: [...])
try await keychain.write(service: service, account: account, data: data)
```

Bad — `Foundation.Process` named in business code:

```swift
let process = Process()
process.executableURL = SystemPaths.openssl
process.arguments = [...]
try process.run()
```

### Enforced

`scripts/check-direct-framework-calls.swift` is a self-contained Swift script (run via `#!/usr/bin/env swift`) that scans for the forbidden patterns outside `*/External/*.swift`, `**/Network/Live*.swift`, `**/Network/InMemory*.swift`, and `**/CPosixBridge/**`. It runs in CI as the `framework-isolation` job and locally on `make lint`.

### Exception: `LiveNetworkTransport` and `CPosixBridge`

`Core/AgentCore/Network/LiveNetworkTransport.swift` *is* the wrapper for `Network.framework`. The `CPosixBridge` C shim *is* the wrapper for `posix_spawn` / `openpty` / `waitpid`. These are listed in the allow-list of the CI script.

### When you need a new wrapper

1. Add an entry to the table above.
2. Add the public-API contract to `docs/reference/wrappers.md`.
3. Add the wrapper file under `src/<Module>/External/<Wrapper>.swift`.
4. Add a happy-path smoke test in the matching suite directory — e.g. `tests/Core/AgentCoreTests/ProcessRunnerTests.swift`, `tests/Remote/AgentRemoteControlTests/BonjourBroadcasterTests.swift`, or `tests/AgentUITests/QRCodeRendererTests.swift`.
5. Refactor every direct framework call site to use the wrapper.
6. Add the framework's call pattern to `scripts/check-direct-framework-calls.swift`.

---

## 19. Observability

Beyond logging, we use:

### Metrics

Counters, gauges, and histograms via `swift-metrics` (or a custom thin wrapper). Categories:

- `agent.session.started.count`
- `agent.prompt.latency.ms` (histogram, percentile-pinned)
- `pty.bytes.read.count`
- `hook.events.received.count` (labeled by hook name)
- `remote.clients.connected.gauge`

Metrics are exported via:
- The system log viewer (`os_log` with category `metrics`) in dev — **Console.app** on macOS, the **Xcode log streamer** or `idevicesyslog` for iOS / iPadOS / visionOS devices.
- Optional Prometheus-style HTTP endpoint behind a settings toggle (post-v1).

### Traces

`OSSignposter` at key lifecycle points:

```swift
private let signposter = OSSignposter(subsystem: "com.codecave.Codemixer", category: "AgentEngine")

public func send(_ command: AgentCommand) async throws {
    let signpostID = signposter.makeSignpostID()
    let state = signposter.beginInterval("send", id: signpostID, "command=\(command.kindName)")
    defer { signposter.endInterval("send", state) }
    // ...
}
```

This makes Instruments timeline traces immediately useful.

### Health endpoints

`GET /v1/health` returns `{ "ok": true, "version": "...", "agentRunning": true, "uptimeSeconds": N, "connectedClients": N }`.

### The data-vs-narrative distinction

- **Logs** are narratives — "this happened, then this." Read by a human investigating.
- **Metrics** are aggregates — "this happened N times in the last hour." Read by a dashboard.
- **Traces** are causal — "this caused that, which caused this." Read by an engineer optimizing.

Don't conflate them. A counter is not a log message.

---

## 20. Configuration & preferences

### Storage

Resolve paths via `FileManager` so the same code works on every platform; the concrete location below is shown for macOS.

```swift
let appSupport = try FileManager.default.url(
    for: .applicationSupportDirectory,
    in: .userDomainMask,
    appropriateFor: nil,
    create: true
)
let prefsURL = appSupport
    .appendingPathComponent("com.codecave.Codemixer", isDirectory: true)
    .appendingPathComponent("prefs.json")
```

- **`prefs.json`** at the resolved `prefsURL` — on macOS this is `~/Library/Application Support/com.codecave.Codemixer/prefs.json`; on iOS / iPadOS / visionOS it resolves inside the app's container. Atomic writes via temp + `rename(2)`. Schema-versioned.
- **`SessionStore` JSON** at the same directory for session metadata.
- **Keychain** [Apple cross-platform] for secrets (TLS certs, bearer tokens).
- **`UserDefaults`** is **forbidden** for application config. (It's allowed for system-owned state like window frames [macOS] or SwiftUI `@SceneStorage` — that's not our config.)

### Schema

```swift
public struct Prefs: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var appearance: AppearancePrefs
    public var voice: VoicePrefs
    public var permissions: PermissionPrefs
    public var remote: RemotePrefs
    public var ui: UIPrefs
    // ...
}
```

Every nested struct is `Codable` with explicit `CodingKeys` (§14). Defaults are defined as a single `Prefs.default` static.

### Migration

When the schema changes, increment `schemaVersion` and write a migrator in `PrefsMigrator.swift`:

```swift
public enum PrefsMigrator {
    public static func migrate(_ data: Data) throws -> Prefs {
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let version = raw["schemaVersion"] as? Int ?? 0
        switch version {
        case 0:   return try migrateV0toV1(raw)
        case 1:   return try JSONDecoder().decode(Prefs.self, from: data)
        default:  throw PrefsError.unsupportedSchemaVersion(version)
        }
    }
}
```

Every migration is unit-tested with a golden fixture of the old version.

### Defaults

`Prefs.default` declares every default at one site. Never inline defaults in usage code (`prefs.appearance.alwaysShowControls ?? false` is wrong — `Prefs.default.appearance.alwaysShowControls` is right).

---

## 21. Localization

Even though v1 ships English-only, the localization seam exists from day one.

### `LocalizedStringKey` everywhere user-facing

```swift
Text("Sign in to Claude")           // OK — LocalizedStringKey by literal
Text(error.userFacingMessage)       // OK — userFacingMessage returns LocalizedStringKey
Text(String(describing: error))     // ⚠ — bypasses localization
Text(verbatim: someDynamicString)   // OK — explicitly verbatim (file paths, names)
```

### Never concatenate localized strings

Bad:

```swift
Text("Hello, ") + Text(userName) + Text("!")
```

Good — use string-format placeholders (`.stringsdict` for plurals):

```swift
Text("Hello, \(userName)!")
```

### Strings file

`src/AgentUI/Resources/Localizable.xcstrings` (Xcode string catalog) — every user-facing string registered. CI fails if a `Text` literal isn't in the catalog.

### Pluralization

`.stringsdict` plural rules for any string with a count:

```swift
Text("^[\(count) file](inflect: true) changed")
```

### Verbatim strings

File paths, URLs, IDs, agent names — these are *not* localized. Use `Text(verbatim:)`.

### Non-Latin scripts

- Use `Locale.current` for date / number formatting.
- Test layouts at extreme widths (German concatenations, Chinese character density).
- Test RTL by toggling `.environment(\.layoutDirection, .rightToLeft)` in previews.

---

## 22. Refactoring discipline

### The Boy Scout rule

Leave the file better than you found it. If you touch a function and notice an obvious naming improvement nearby, fix it — *in a separate commit*. Refactor and feature must not share a commit.

### Refactor vs rewrite

- **Refactor**: change structure without changing behavior. Tests pass before and after with no modifications. Reviewable in < 30 minutes.
- **Rewrite**: change structure AND behavior. Tests change. Requires a fresh design review.

If you find yourself rewriting under the banner of "refactoring," stop and open a separate design discussion.

### Refactor commits

A refactor commit has:
- Imperative subject: `Extract HeartbeatActivityMonitor from AgentEngine`
- Body explaining *why*: what duplication this resolves, what test coverage justifies the move.
- No new tests (the existing tests prove behavior is preserved).
- No new behavior. If reviewers see a behavior change in a refactor commit, that's grounds for refusal.

### When NOT to refactor

- Mid-feature. Land the feature, then refactor in a follow-up.
- Without test coverage. Add tests first, then refactor.
- Because you want to. Refactor in service of a concrete next step — feature, fix, or readability for the next reader.

### Architectural refactors

Anything affecting > 3 files or any public API:
- Discuss in a GitHub issue first.
- Stage in a feature branch, not main.
- Demonstrate one concrete benefit (test added, public API simplified, bug class eliminated) in the PR description.

---

## 23. Commit, branch, and PR aesthetic

The git history is itself a piece of the codebase, and is reviewed with the same care.

### Commits

- **Atomic.** One logical change per commit. Formatting / refactor / feature are separate commits, split via `git rebase -i` before push.
- **Subject = imperative verb, ≤ 50 chars.** `Add HeartbeatActivityMonitor`, not `Added a heartbeat monitor`. No trailing period.
- **Body explains *why*.** Single paragraph wrapped at 72 columns. Diff shows *what*; body explains the constraint, the alternative considered, or the bug fixed. Skip body for trivial commits, never for behavior changes.
- **Never "WIP" / "fix typo" / "fix CI" commits in main.** Squash before merge.

### Branches

- `feat/<short>`, `fix/<short>`, `refactor/<short>`, `test/<short>`, `docs/<short>`, `chore/<short>`.
- Three to five words, lowercase-hyphenated.
- Branch deleted on merge (auto via GitHub setting).
- One PR per branch. If a branch grows two features, split.

### PRs

Description template:

```
## What changed
<one or two sentences>

## Why now
<the trigger / motivation>

## How tested
<what you verified and how — including manual steps for UI changes>

## Risks
<what could go wrong; what to monitor after merge>

## Out of scope
<what this PR deliberately doesn't do>
```

- No screenshots unless the PR is visual.
- No emoji.
- Link to issue (`Closes #123`).
- Self-review before requesting review. Add comments to your own diff explaining the non-obvious choices.

### Review etiquette

- **Suggestions**: phrase as a question or a `Suggestion:` block.
- **Requests**: explicit `Required:` prefix.
- **Approve**: only when every required comment is resolved.
- **Block (request changes)**: only when a required item is unaddressed and the author has had a chance to respond.
- Replies to feedback that ship a fix: respond `Done in <sha>`, not silent commits.

---

## 24. Git hygiene beyond commits

### Rebase, not merge

- **`git rebase main`** to incorporate main into a feature branch.
- **Squash-merge** to main via the GitHub UI; the resulting commit has the PR's title and description.
- **No merge commits** in main. The history is linear.

### Force-push policy

- **Never force-push to main.** Repo settings reject.
- **Force-push to your own feature branch** is allowed but use `--force-with-lease` (refuses if upstream moved).
- **Force-push after review has started** requires a note in the PR — reviewers may have stale comments.

### Tags

- **Release tags**: `v0.1.0`, `v0.2.0`, semantic versioning.
- **Pre-release**: `v0.1.0-alpha.1`, `v0.1.0-beta.3`.
- **Tag commits** are signed.

### `.gitignore`

- IDE files, build outputs, `.DS_Store`, `.swiftpm/`, `.build/`, `DerivedData/`.
- Never `node_modules` (we have no JavaScript).
- Never `*.env` (secrets don't live in files in the repo).

### Submodules

Forbidden. Use SPM.

### LFS

Used only for golden fixtures > 100KB. Most fixtures are small JSON / JSONL and live in git directly.

### Repo settings

- Default branch `main`.
- Branch protection on `main`: require PR, require CI green, require ≥1 review, dismiss stale approvals on push, no force-push, no delete.
- "Automatically delete head branches" enabled.
- "Allow squash merging" only; merge and rebase merges disabled.

---

## 25. Tooling

### SwiftFormat

Checked-in `.swiftformat`:

- 4-space indent
- 100-column line limit
- Trailing-closure preferred
- `--decimalgrouping 3`
- `--wraparguments before-first --wrapcollections before-first`

### SwiftLint

Minimal opinionated `.swiftlint.yml`:

- Most rules as warnings
- Errors only for the egregious: `force_unwrapping`, `force_try`, `large_tuple`, `function_body_length=60`, `file_length=400`, `function_parameter_count=5`
- Custom rules:
  - Reject `Date()`, `Int.random`, `ProcessInfo.processInfo.environment`, `FileManager.default` outside `Core/AgentCore/Seams/Live*.swift`
  - Reject `print(`
  - Reject bare `// TODO` without `(#NNN)`
  - Reject `internal` keyword (it's the default; spelling it is noise)
  - Reject `Color.…` literals outside `Theme.swift`
  - Reject magic numeric padding outside `Theme.swift`

### Pre-commit hook

Runs SwiftFormat (write-mode), SwiftLint (lint-mode), and a fast `swift build -Xswiftc -parse-only` check. No commits without passing.

### CI

GitHub Actions on macOS-14 [macOS — Codemixer ships a macOS app; iOS / iPadOS targets would add an `iOS-latest` simulator job]:

- `swift build -Xswiftc -warnings-as-errors`
- `swift test --warnings-as-errors`
- `-strict-concurrency=complete`
- `scripts/check-a11y.swift` — scans SwiftUI files for icon-only `Button(...)` without `.accessibilityLabel`
- Headless build job — greps the daemon binary's symbol table; fails if any `SwiftUI` symbol present
- DocC build — generated docs must compile without warnings; symbol coverage ≥90% of public surface
- Benchmark job (separate, non-blocking) — reports performance vs baseline; ≥10% regression auto-comments on the PR
- `protocol-only` job — builds `AgentProtocol` with iOS conditional to verify mobile-client portability
- `tests-remote-parity` job — runs the `AgentCommand` ↔ UI ↔ wire-decoder parity guard

### CODEOWNERS

`docs/style/code-style.md` and the `code-quality-tooling` configs (`.swiftformat`, `.swiftlint.yml`) have a style-conscious code-owner who reviews changes to them.

### PR template

`.github/pull_request_template.md` contains the §23 template and the §26 checklist as a collapsed `<details>` section.

---

## 26. Pre-merge review checklist

Every reviewer reads these questions aloud (literally, in their head) before approving:

1. **If I deleted every comment in this PR, would the code still make sense?** If not, the names are wrong.
2. **Are there any new force-unwraps, `try!`, `as!`, `Any`, `[String: Any]`, `print`, `Date()`, `Int.random`?** If yes, why.
3. **Does every new public symbol have a doc-comment that explains the contract, not the implementation?**
4. **Do the test names read as English sentences describing behavior?**
5. **Is the file < 200 lines, every function < 30 lines, every type cohesive?**
6. **Does this match the rhythm of `PTYHost`?**
7. **Would I write this exactly this way in two years?** If not, it's not done.
8. **Are concurrency boundaries deliberate? Any new `Task {}` outside the three legal sites? Any new `@unchecked Sendable` without a proof?**
9. **Are typed errors used wherever they can be? Any `throws -> any Error` introduced?**
10. **Is every privacy level explicit in every new `Logger` call?**
11. **Is every user-facing string a `LocalizedStringKey` (or explicitly `verbatim`)?**
12. **Does this PR introduce a new dependency? If yes — license, size, last-commit date, alternative considered?**

A "no" to any of these is grounds for refusal. The reviewer's job is not to find typos; CI finds typos. The reviewer's job is to ask whether this code earns its place in a codebase meant to last.

---

## 27. Boring is beautiful

The default solution is the boring one. Novelty is a cost.

- **Boring**: `let count = items.count`. **Clever**: `let count = items.reduce(0) { acc, _ in acc + 1 }`.
- **Boring**: `for item in items { ... }`. **Clever**: `items.forEach { ... }` (when the closure is non-trivial).
- **Boring**: a struct. **Clever**: a generic protocol with three associated types and four constraints.
- **Boring**: synchronous code. **Clever**: an `AsyncStream` for what could have been one call.
- **Boring**: explicit if/switch. **Clever**: a result builder.

Novel solutions are sometimes correct. They earn their place by:
- Solving a real problem that the boring solution cannot.
- Being measurably better (benchmarks, line count, readability).
- Coming with thorough tests so the next reader can trust them.

A PR introducing novelty answers in its description: *what does this enable that the boring version cannot?*

---

## 28. Adopting Swift language features

### Policy

- **Production code** uses Swift features that have shipped in a stable Xcode release **for ≥ 6 months**.
- **Tests and seams** may use newer features immediately (they're not on the user's critical path).
- **Macros** must be backed by a measurable simplification — they hide code from the reader, which is a cost.

### Specifically

- **Swift 6 strict concurrency**: required everywhere.
- **Typed throws**: used at every layer that has a stable error vocabulary (most of Codemixer).
- **`borrowing` / `consuming`** parameters: used only with measurement (§17).
- **Macros (Swift 5.9+)**: allowed sparingly. `#expect`, `#require` (Swift Testing) are fine — they're standard library. Custom macros require a design review.
- **Variadic generics**: allowed where they meaningfully simplify a call site.
- **Result builders**: used in established Apple-shipped contexts (SwiftUI). Custom result builders require design review.

### How we evaluate a new feature

When a Swift release lands:
1. Read the proposal and the rationale.
2. Try the feature in a sandbox.
3. Discuss adoption in a tracked issue.
4. If adopted, update this document and the relevant patterns.

---

## 29. The meta-process — how this document evolves

This document is the team's shared aesthetic. Changing it changes the bar for every PR. So:

### Changes require a PR like any code

`docs/style/code-style.md` is reviewed under the same rules as Swift files. Style PRs:

- **Have a concrete example** in the same PR demonstrating the new pattern. Style without code is theory.
- **Have a 24-hour cooling-off period** between approval and merge. We sleep on style changes.
- **Cite the failure mode** the new rule prevents. "We added rule X because PR #Y had problem Z."
- **Cannot be sneaked in** alongside feature changes. Style changes get their own PR.

### Removing a rule

Removing a rule has the same bar as adding one. The PR explains why the rule is no longer load-bearing.

### Disagreeing

If you disagree with a rule:
1. Open an issue describing the disagreement and the proposed alternative.
2. Show a concrete example where the current rule produces worse code.
3. Discuss in the issue, not in PR comments.
4. If the team agrees, the rule changes — via the process above.

Until the rule changes, the rule stands. PRs that ignore the rule are blocked.

### Sources we trust

- The Swift API Design Guidelines (Apple).
- Swift Evolution proposals and rationales.
- Apple's WWDC sessions on Swift concurrency, performance, and tooling.
- Books: *Functional Swift* (Eidhof), *Advanced Swift* (Eidhof / Kim / Wadehra).
- This document.

Sources we mistrust:
- One-off blog posts without measurement.
- LinkedIn hot takes.
- Twitter threads about "best practices" without context.

---

## 30. Glossary

Terms used throughout this document and the rest of the repository docs.

- **Actor reentrancy**: when an `await` inside an actor method releases its isolation, allowing other messages to interleave. The most subtle pitfall of Swift concurrency.
- **Adapter**: a module implementing `AgentAdapter`, specialising the engine for one CLI tool (e.g., `ClaudeCode` shipping `ClaudeAdapter`).
- **AgentCommand**: the typed input enum every interaction surface (UI, voice, remote API) maps to.
- **AgentEvent**: the typed output enum every observer (Mac UI, remote phone) consumes.
- **Bus** (`MulticastEventBus`): the engine-internal fan-out actor that delivers `AgentEvent`s to N subscribers with a replay ring buffer.
- **Codable**: Swift's serialization protocol; used for wire types in `AgentProtocol`.
- **Continuation**: in `AsyncStream.makeStream(of:)`, the producer-side handle that yields values to the stream.
- **Copy-on-write (COW)**: Swift's optimization for value-type collections — copies share storage until mutation forces a copy.
- **DocC**: Apple's documentation compiler; ingests `///` comments and `.docc` catalogs into Xcode docs and a static site.
- **Domain type**: a Codemixer type that uses Foundation conveniences (`URL`, `Date`, `Duration`). Lives in `AgentCore`. Contrasted with *wire type*.
- **Engine** (`AgentEngine`): the `actor` orchestrator that owns the agent process lifecycle and emits events through the bus.
- **Existential type**: `any P` — a box holding a value conforming to protocol `P`. Contrasted with *generic constraint* (`<T: P>`).
- **Fixture**: a version-controlled test input (file, JSON blob) representing a real-world scenario.
- **Heartbeat**: the engine-side `noEventGap` emission, every 500ms during active turns, so clients can render "still working" indicators.
- **Hook** (Claude): a JSON event Claude emits at lifecycle points (e.g., `PreToolUse`). We receive them over a Unix domain socket configured via `--settings`.
- **IntentReveal**: the SwiftUI modifier driving "hidden by default, visible on intent" behavior for secondary actions.
- **JSONL**: newline-delimited JSON; the format Claude uses for transcripts.
- **Lasagna**: the SwiftUI anti-pattern of stacking `.padding().background().padding().background()` — forbidden.
- **Loopback**: the WebSocket connection from the GUI window to a daemon-mode engine on `127.0.0.1`.
- **MulticastEventBus**: see *Bus*.
- **`os.Logger`**: Apple's structured logging API. Replaces `print` in this codebase.
- **PTY** (pseudo-terminal): kernel-level master/slave file-descriptor pair that lets us spawn a CLI in a "fake terminal" without rendering one.
- **Reentrancy**: see *Actor reentrancy*.
- **Replay ring buffer**: bounded FIFO buffer of recent events in the bus; lets reconnecting clients catch up.
- **Sending parameter**: Swift 6's `sending` keyword that transfers a value across an isolation boundary without requiring `Sendable`.
- **Snapshot**: a value-typed read of an actor's state at a point in time, safe to pass across isolation boundaries.
- **Strict concurrency**: `-strict-concurrency=complete`; the compiler enforces `Sendable` and isolation across every boundary.
- **Structured concurrency**: tasks whose lifetimes are bounded by a parent scope (`async let`, `withTaskGroup`). Contrasted with *unstructured* (`Task {}`).
- **Test seam**: a protocol-shaped abstraction whose only justification is testability (`Clock`, `RandomSource`).
- **TTL** (time-to-live): how long a staged upload remains before janitorial cleanup.
- **Token**: in our context, the bearer token issued during pairing — not an LLM token (which is `usage.tokens`).
- **UDS**: Unix domain socket; used for `claude` hook delivery.
- **Wire type**: a `Codable`-only struct living in `AgentProtocol`, designed to cross the network. Foundation-free where possible. Contrasted with *domain type*.
- **Witness**: in Swift generics, the compiler-generated table mapping a generic call to a concrete protocol implementation.

---

## 31. When in doubt

- Read `PTYHost.swift`.
- Ask: *what would the smallest readable form of this look like?*
- Ask: *could I delete a line and lose nothing?*
- Ask: *is this the obvious solution, or am I being clever?*
- Ask: *what will the next reader think when they open this in two years?*

**Clever is the enemy. Obvious is the goal.**

---

*Last revised alongside the current Codemixer architecture docs. To propose changes, see §29.*
