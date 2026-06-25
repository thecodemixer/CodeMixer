# Pattern: IPC server / listener

**Scope.** Building a small, well-behaved local-IPC server using `NWListener` over Unix-domain sockets (for in-machine IPC) or loopback TCP (when sockets aren't an option), with framed JSON envelopes, per-client actor lifecycle, graceful shutdown, and disciplined path conventions. The result: a sidecar process can talk to the host engine with the same wire shape a remote client would use.

**When to use.** Any system with a *helper process* that needs to push events to the main app: shell hooks, browser-extension daemons, OS extensions, language-server-like processes, native messaging hosts.

**When not to use.** Cross-machine communication (use TLS WebSocket — see [headless-remote-duality](headless-remote-duality.md)). Pure parent-child stdin/stdout flows (just use the file descriptors). High-throughput streaming (use shared memory / `mach_port`).

---

## Transport choice

| Transport | When to use |
| --- | --- |
| **Unix domain socket (`AF_UNIX`)** | Same-machine IPC. Permissions on the socket path control access. Fast, no kernel network stack. **Default for `[macOS]` / `[Linux]`.** |
| **Loopback TCP (`127.0.0.1`)** | Same-machine when sockets aren't ergonomic (Windows pre-1803, some sandboxed contexts). Slightly slower; needs port selection. |
| **`NWListener` with `.unix(path:)`** | Apple platforms — `Network.framework` wraps both transports cleanly. Same API for both. |

Codemixer uses `NWListener` with `.unix(path:)`. The pattern below uses that idiom; substituting loopback TCP changes one line.

---

## Socket path conventions

```swift
public enum SocketPaths {
    public static func hookSocket(pid: pid_t) -> String {
        let dir = (ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp")
        return "\(dir.trimmingTrailingSlash())/codemixer-hook-\(pid).sock"
    }
}
```

**Rules:**

- **`$TMPDIR`** on macOS (per-process, per-session, ACL-restricted). Falls back to `/tmp` on Linux.
- **PID suffix** prevents collisions between multiple instances of the same app.
- **Length cap**: Unix socket paths are 104 chars on macOS, 108 on Linux. `$TMPDIR` on macOS can be long; check before bind.
- **Cleanup**: remove the file on startup (stale from a crashed prior run) and on shutdown. `unlink(socketPath)`.

---

## The framing convention — newline-delimited JSON

For most local-IPC, NDJSON is simpler than length-prefixed framing:

```
{"v":1,"type":"hook","name":"PreToolUse","payload":{...}}\n
{"v":1,"type":"hook","name":"PostToolUse","payload":{...}}\n
```

**Rules:**

- One JSON document per line (`\n`-terminated).
- No embedded newlines in payloads (escape as `\n` if needed).
- Reader buffers until newline, decodes, repeats.
- Producer flushes after each frame.

When payloads grow large enough to make NDJSON awkward (≥ 64 KB / frame), switch to length-prefixed:

```
[4 bytes big-endian length][JSON payload]...
```

Length-prefixed is universally robust but slightly more code. NDJSON is `grep`-able and human-readable on the wire. Codemixer uses NDJSON for hooks.

---

## The server actor

```swift
import Network
import OSLog

public actor HookServer {

    public typealias OnFrame = @Sendable (HookEnvelope) async -> Void

    public struct HookEnvelope: Sendable {
        public let eventName: String
        public let payloadJSON: Data
        public let stdout: NWConnection?      // nil if the producer doesn't expect a reply
    }

    private let log = Logger(subsystem: "com.codecave.Codemixer", category: "Hook")
    private let path: String
    private let onFrame: OnFrame

    private var listener: NWListener?
    private var clients: [UUID: HookClient] = [:]

    public init(path: String, onFrame: @escaping OnFrame) {
        self.path = path
        self.onFrame = onFrame
    }

    public func start() async throws {
        try? FileManager.default.removeItem(atPath: path)   // stale socket from prior run

        let params = NWParameters()
        params.requiredInterfaceType = .other               // unix-domain on Apple
        params.allowLocalEndpointReuse = true

        let endpoint = NWEndpoint.unix(path: path)
        let listener = try NWListener(using: params, on: endpoint)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }

        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.onListenerState(state) }
        }

        listener.start(queue: .global(qos: .userInitiated))
        log.notice("hook listener started path=\(self.path, privacy: .public)")
    }

    public func stop() async {
        listener?.cancel()
        listener = nil
        for (_, client) in clients { await client.close() }
        clients.removeAll()
        try? FileManager.default.removeItem(atPath: path)
    }

    private func accept(_ connection: NWConnection) async {
        let id = UUID()
        let client = HookClient(id: id, connection: connection, onFrame: onFrame) { [weak self] cid in
            Task { await self?.removeClient(cid) }
        }
        clients[id] = client
        await client.start()
    }

    private func removeClient(_ id: UUID) async {
        clients[id] = nil
    }

    private func onListenerState(_ state: NWListener.State) async {
        switch state {
        case .ready:        log.notice("hook listener ready")
        case .failed(let e): log.error("hook listener failed reason=\(String(describing: e), privacy: .public)")
        case .cancelled:    log.notice("hook listener cancelled")
        default:            break
        }
    }
}
```

**Properties:**

- One actor for the listener, one actor per client. Connections are isolated; one slow client cannot stall others.
- `actor`, not `@MainActor`. The listener has no UI concerns.
- `Logger` everywhere; never `print`.
- `stop()` is idempotent and removes the socket file.

---

## The per-client actor

```swift
public actor HookClient {

    private let id: UUID
    private let connection: NWConnection
    private let onFrame: HookServer.OnFrame
    private let onClose: (UUID) -> Void

    private var buffer = Data()
    private var isClosed = false

    public init(id: UUID, connection: NWConnection,
                onFrame: @escaping HookServer.OnFrame,
                onClose: @escaping (UUID) -> Void) {
        self.id = id
        self.connection = connection
        self.onFrame = onFrame
        self.onClose = onClose
    }

    public func start() async {
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.onState(state) }
        }
        connection.start(queue: .global(qos: .userInitiated))
        await readLoop()
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onClose(id)
    }

    private func readLoop() async {
        while !isClosed {
            do {
                let chunk = try await receiveOnce(maxBytes: 64 * 1024)
                guard !chunk.isEmpty else { await close(); return }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer.prefix(upTo: nl)
                    buffer.removeSubrange(...nl)
                    if let envelope = decode(line) {
                        await onFrame(envelope)
                    }
                }
            } catch {
                await close()
                return
            }
        }
    }

    private func receiveOnce(maxBytes: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxBytes) { data, _, isComplete, error in
                if let error { continuation.resume(throwing: error); return }
                if let data { continuation.resume(returning: data); return }
                if isComplete { continuation.resume(returning: Data()); return }
                continuation.resume(returning: Data())
            }
        }
    }
}
```

**Properties:**

- One reader loop per client. Backpressure is implicit: NWConnection doesn't deliver another chunk until the current `receive` completes.
- 64 KB read window — large enough to absorb small bursts, small enough to bound memory per client.
- Newline-delimited framing in the loop.
- Decode failures *drop the frame* and log; never crash the loop.
- `close()` is idempotent.

---

## Bidirectional flow — sending responses

When the producer expects a reply (e.g. a shell-hook waiting for a yes/no), the connection becomes bidirectional:

```swift
extension HookClient {
    public func respond(_ data: Data) async {
        guard !isClosed else { return }
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}
```

**Convention:** the response is also newline-delimited JSON. Producer's hook script reads one line of stdout.

---

## Authentication for local IPC

For same-machine IPC over Unix-domain sockets, the OS handles permissions via the socket file's mode bits:

- Socket file is created with mode `0o600` (owner read+write only).
- Same UID → trusted by default.
- Cross-UID access requires the user's explicit consent (and a UID check in the server).

For loopback TCP, **authentication is mandatory** — any process on the machine can connect:

- The producer presents a shared secret (bearer token, see [lan-pairing-and-auth](lan-pairing-and-auth.md)) in the first frame.
- Mismatch → close immediately, log `unauthenticated remote=\(peer)`.

Codemixer's hook server uses Unix sockets and trusts the file permissions; no per-frame auth needed.

---

## Graceful shutdown

```swift
public func shutdown() async {
    log.notice("hook listener shutting down")

    // 1. Stop accepting new connections.
    listener?.cancel()

    // 2. Drain in-flight reads — give clients up to 2 seconds.
    try? await withTimeout(.seconds(2)) {
        await waitForClientsToFinish()
    }

    // 3. Force-close anything still around.
    for (_, client) in clients { await client.close() }
    clients.removeAll()

    // 4. Clean up the socket file.
    try? FileManager.default.removeItem(atPath: path)
}
```

**Properties:**

- New connections stop first; existing ones get a grace window.
- A timeout prevents shutdown from hanging on a stuck client.
- Socket file is always removed — stale sockets are a foot-gun on next launch.

---

## Path-conflict recovery

If `bind(2)` fails with `EADDRINUSE`, two scenarios:

- A prior run crashed and left a stale socket. Recovery: `unlink(path)` and retry once.
- Another instance is genuinely running. Recovery: pick a new path (`-2` suffix), retry up to 3 times, then fail loudly.

```swift
private func bindWithRetries() async throws -> NWListener {
    var pathAttempt = path
    for attempt in 0..<3 {
        try? FileManager.default.removeItem(atPath: pathAttempt)
        do {
            return try NWListener(using: params, on: .unix(path: pathAttempt))
        } catch {
            log.warning("bind failed attempt=\(attempt) path=\(pathAttempt, privacy: .public)")
            pathAttempt = "\(path).\(attempt + 1)"
        }
    }
    throw HookError.socketBindFailed(path: path, errno: errno)
}
```

The actual bound path is published through `socketPath` so the producer can find it (e.g. via the launched subprocess's environment variable).

---

## Anti-patterns

| Anti-pattern | Why it's bad | Fix |
| --- | --- | --- |
| Single shared connection actor | One slow client stalls everyone | Per-client actor. |
| Length-prefixed framing for tiny payloads | More code than NDJSON; not faster | NDJSON unless payloads grow > 64 KB. |
| `NWConnection.send` without continuation | The send completes asynchronously; you can't sequence responses | Await the completion. |
| Trusting peer identity without a UID check on loopback TCP | Any local process can impersonate | Either Unix sockets (file perms) or bearer-token auth. |
| Stale socket files surviving crashes | EADDRINUSE on next launch | Unlink on startup. |
| `print(...)` for IPC debug | Goes nowhere in release | `Logger` per [structured-logging-with-privacy](structured-logging-with-privacy.md). |
| No shutdown timeout | Hangs forever on a stuck client | `withTimeout` wrapper. |
| Socket bound to a public path (`/tmp`) on shared-user systems | Other users may read | `$TMPDIR` on macOS (per-user); mode `0o600`. |

---

## Codemixer instance

- `HookServer` ↔ `Core/AgentCore/Hooks/HookServer.swift`.
- `HookSocketHandle` ↔ the per-client interface exposed to the adapter.
- Socket path ↔ `$TMPDIR/codemixer-hook-<pid>.sock`.

See [docs/architecture.md §9, §10](../../architecture.md) for the Codemixer narrative on hook-based event ingestion.

---

## Minimum viable adoption

1. Pick a framing (NDJSON for small payloads, length-prefixed for big).
2. Pick a transport (Unix-domain socket for same-machine, loopback TCP otherwise).
3. Build the listener actor + per-client actor (~ 150 lines total).
4. Add socket-path conflict recovery (stale-socket unlink, numbered retry).
5. Add graceful shutdown with a timeout.
6. Test: open, send 100 frames, close mid-frame, reopen — no leaks, no stale sockets.
7. Test: 10 simultaneous producers; one of them sleeps mid-frame; the others continue uninterrupted.

The result: a local sidecar process can push events to the host with the same robustness a remote client gets, in a few hundred lines.
