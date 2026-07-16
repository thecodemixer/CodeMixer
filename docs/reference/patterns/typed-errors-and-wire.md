# Pattern: Typed errors and Codable wire errors

**Scope.** Per-module typed `Error` enums with rich associated values, Swift 6.2 typed throws at narrow surfaces, and `Codable` mirror types so errors raised on the server arrive on the client with the same case and the same context.

**When to use.** Any non-trivial codebase. The cost is one enum per module plus a converter at any network boundary; the payoff is that every `catch` site is exhaustive, every error message is actionable, and every remote client sees the same failure case the engine saw.

**When not to use.** One-shot scripts. Throwaway prototypes. Anything where "print and crash" is acceptable.

---

## The discipline in one paragraph

A function's failure modes are part of its contract. Generic `Error` discards that contract; `enum SomeError: Error` preserves it. Every module owns its error enum. Every error carries enough context to fix the problem from the message alone. Every error that crosses a network boundary has a `Codable` representation that round-trips losslessly.

---

## One enum per module

```swift
public enum PTYError: Error, Sendable {
    case openpty(errno: Int32)
    case nonBlocking(errno: Int32, fd: Int32)
    case spawn(errno: Int32, executable: URL)
    case write(errno: Int32, bytes: Int)
    case alreadyClosed
}

public enum HookError: Error, Sendable {
    case socketBindFailed(path: String, errno: Int32)
    case decode(eventName: String, underlying: any Error)
    case stdoutClosed(connectionID: UUID)
    case unauthenticated(remoteAddress: String?)
}

public enum AgentError: Error, Codable, Sendable {
    case binaryNotFound(agentID: AgentID, hint: String)
    case spawnFailed(errno: Int32, detail: String)
    case authenticationRequired(loginURL: URL?)
    case staleEditTarget(targetID: UUID)
    case permissionTimeout(promptID: UUID, action: PermissionDecision)
    case internalInvariant(detail: String)
    case adapter(domain: String, code: String, message: String)
}
```

**Rules:**

- Module name in the prefix (`PTYError`, not `Error`).
- `Sendable` always; `Codable` only if the type crosses the wire.
- Associated values carry *every* fact a fix-it message would need: errno values, paths, IDs, sizes, line numbers.
- No `case other`. The closed-set property of enums is what we paid for.
- Wire enums decode exhaustively; breaking changes bump `WireVersion` (no `unknown` catch-all).

---

## Swift 6.2 typed throws

When a function's error set is small and closed, use typed throws:

```swift
public func openpty() throws(PTYError) -> (master: Int32, slave: Int32) {
    var m: Int32 = -1
    var s: Int32 = -1
    let r = openpty_swift(&m, &s, nil, nil, nil)
    if r != 0 { throw .openpty(errno: errno) }
    return (m, s)
}

public func writeToHost(_ bytes: Data) throws(PTYError) {
    let n = bytes.withUnsafeBytes { write(masterFD, $0.baseAddress, $0.count) }
    if n < 0 { throw .write(errno: errno, bytes: bytes.count) }
}
```

Callers get exhaustive `catch`:

```swift
do {
    try writeToHost(bytes)
} catch .openpty(let e):
    log.error("openpty failed errno=\(e, privacy: .public)")
} catch .write(let e, let n):
    log.error("write failed errno=\(e, privacy: .public) bytes=\(n, privacy: .public)")
} catch {
    // Exhaustive — compiler proves no other PTYError case exists.
}
```

When the error set is wide or composed across modules (`AgentError` is composed from `PTYError`, `HookError`, etc.), revert to untyped `throws`. Don't force typed throws when the set isn't actually closed.

---

## `localizedDescription` is actionable, not opaque

```swift
extension AgentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let id, let hint):
            return "\(id.displayName) binary not found. \(hint)"
        case .spawnFailed(let errno, let detail):
            return "Could not start the agent (errno \(errno)). \(detail)"
        case .authenticationRequired(let url):
            if let url { return "Sign in required. Open \(url.absoluteString)." }
            return "Sign in required."
        case .staleEditTarget:
            return "This message has already been replaced. Refresh and try again."
        case .permissionTimeout(_, let action):
            return "Permission timed out. Defaulted to \(action.rawValue)."
        case .internalInvariant(let d):
            return "Internal error: \(d). Please report."
        case .adapter(_, let code, let message):
            return "Agent error (\(code)): \(message)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .binaryNotFound: return "Install with `npm i -g @anthropic-ai/claude-code`."
        case .authenticationRequired(let url) where url != nil:
            return "Click the sign-in link to authenticate."
        default: return nil
        }
    }
}
```

**Rule of thumb:** if a user sees the message and can't act on it, the message is wrong. Replace it.

---

## Codable wire errors

When an error crosses a network boundary, it needs a `Codable` representation. Two patterns work:

### Pattern A — make the domain error `Codable` directly

Used when associated values are all `Codable` (strings, ints, UUIDs, URLs, dates, primitive arrays):

```swift
public enum AgentError: Error, Codable, Sendable {
    case binaryNotFound(agentID: AgentID, hint: String)
    case spawnFailed(errno: Int32, detail: String)
    // …
}
```

Easy. The synthesized `Codable` works. Each case becomes a discriminator + payload.

### Pattern B — separate `XxxErrorWire` mirror

Used when domain associated values include non-`Codable` types (e.g. `any Error`, closures, `NSException`):

```swift
public enum HookErrorWire: Codable, Sendable {
    case socketBindFailed(path: String, errno: Int32)
    case decode(eventName: String, underlyingDescription: String)
    case stdoutClosed(connectionID: String)
    case unauthenticated(remoteAddress: String?)
}

public extension HookErrorWire {
    init(_ err: HookError) {
        switch err {
        case .socketBindFailed(let path, let errno): self = .socketBindFailed(path: path, errno: errno)
        case .decode(let name, let underlying):
            self = .decode(eventName: name, underlyingDescription: String(describing: underlying))
        case .stdoutClosed(let id): self = .stdoutClosed(connectionID: id.uuidString)
        case .unauthenticated(let addr): self = .unauthenticated(remoteAddress: addr)
        }
    }
}
```

Pattern B is more work but lossier-by-design — the wire never carries `any Error` because the receiver can't reconstruct it.

---

## The error envelope at the network boundary

Every wire frame that can carry an error uses one envelope:

```swift
public struct WireError: Codable, Sendable, Error {
    public let domain: String           // module name: "agent", "hook", "pty", "remote", "pairing"
    public let code: String             // enum case name: "binaryNotFound", "socketBindFailed"
    public let message: String          // human-readable; localized server-side or untranslated
    public let details: [String: String]? // optional structured context
}
```

The server converts a typed domain error to `WireError` once at the boundary; the client converts `WireError` back into its own typed enum if it has one, or surfaces it as a generic error.

```swift
public enum WireErrorConverter {
    public static func encode(_ error: any Error) -> WireError {
        switch error {
        case let e as AgentError:    return WireError(domain: "agent", code: e.caseName, message: e.localizedDescription ?? "", details: e.details)
        case let e as PairingError:  return WireError(domain: "pairing", code: e.caseName, message: e.localizedDescription ?? "", details: nil)
        // …
        default:                     return WireError(domain: "unknown", code: "unspecified", message: String(describing: error), details: nil)
        }
    }
}
```

---

## `fatalError` is rare; `Logger.fatal` is the standard escape hatch

```swift
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

**Rules:**

- Pure `fatalError(...)` is reserved for genuinely unreachable code (`switch` over a closed enum's exhausted-cases sentinel).
- All other "should never happen" sites use `Logger.fatal`. In debug, the asserter fires (loud during tests); in release, the fault is logged and the process exits cleanly with an audit trail.

---

## Anti-patterns

| Anti-pattern | Why it's bad | Fix |
| --- | --- | --- |
| `throw NSError(domain:..., code:..., userInfo:...)` | Loses type information; `catch` sites become string-matching. | Define a typed enum. |
| `case other(String)` | Defeats the closed-set property; everything tends to land here. | Define real cases. Add new ones when surprised. |
| `throws` on every function "for future-proofing" | Pollutes callers with `try` they don't need. | Add `throws` only when there's an actual error path. |
| Associated values are `String` describing context | The string is lossy; the wire can't pick it apart later. | Use typed associated values (`URL`, `Int32`, `UUID`). |
| `fatalError` in production code paths | Crashes are forever; no audit log. | `Logger.fatal` or recover. |
| `Error.localizedDescription` derived by reflection | Useless ("The operation couldn't be completed"). | Implement `LocalizedError` per case. |
| Catching `any Error` everywhere | Hides real bugs; nothing exhausts. | Catch specific types; let the rest propagate. |
| Same error case used for two semantic situations | `decodeError` for both "JSON malformed" and "schema mismatch". | Split into separate cases. |

---

## Codemixer instance

- `PTYError` — `Core/AgentCore/PTY/PTYError.swift`.
- `AgentError` — `Core/AgentCore/Events/AgentError.swift` (`Codable, Sendable`).
- `PairingError`, `RemoteControlError` — `Remote/AgentRemoteControl/`.
- `WireError` — `Core/AgentProtocol/WireError.swift`.
- Wire conversion in `Remote/AgentRemoteControl/RemoteControlServer.swift` at the frame boundary.

See [docs/architecture.md §24](../../architecture.md) for the Codemixer narrative.

---

## Minimum viable adoption

1. Define one error enum per module. `Sendable` always; `Codable` only if it crosses the wire.
2. Make associated values carry the *facts* (errno, path, ID), not pre-formatted strings.
3. Implement `LocalizedError` on every user-facing enum with actionable messages.
4. Add typed throws (`throws(MyError)`) to narrow-surface functions.
5. At the network boundary, define a `WireError` envelope and one converter.
6. Add a `Logger.fatal` shim; ban naked `fatalError` outside it.
7. CI grep for `NSError(` and `throws ->` (unconstrained throws on new functions) and require review.

After a release cycle, every catch site in the codebase is exhaustive and every error message is fixable from the text alone.
