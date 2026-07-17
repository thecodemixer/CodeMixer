# External integration wrappers

Every Apple/system framework call in Codemixer goes through a single wrapper class. Business code never imports `Foundation.Process`, `Security.SecItem*`, `CoreServices.FSEventStream*`, `Network.NWListener`/`NWConnection`, `AVFoundation`, `Speech`, `UserNotifications`, or `Foundation.NetService` directly.

The two exceptions are themselves wrappers:

- `Core/AgentCore/Network/LiveNetworkTransport.swift` — the wrapper for `Network.framework` for outbound/inbound TCP and WebSocket.
- `CPosixBridge` — the C shim wrapping `posix_spawn`, `openpty`, `waitpid`.

This document is the frozen public-API contract for every wrapper. **Add or change a wrapper only by editing this table first.**

---

## `ProcessRunner`

**File**: `src/Core/AgentCore/External/ProcessRunner.swift`
**Wraps**: `Foundation.Process`
**Consumers**:
- `CertificateManager` — `SystemPaths.openssl` `req` and `pkcs12` invocations.
- `GitReverter` — `SystemPaths.env git ...` invocations.
- `GitDiffEngine` — `SystemPaths.git` diff/status invocations.

**Public API**:

```swift
public actor ProcessRunner {
    public struct Result: Sendable, Equatable {
        public let stdout: Data
        public let stderr: Data
        public let exitCode: Int32
    }

    public enum ProcessError: Error, Sendable, Equatable {
        case spawnFailed(detail: String)
        case nonZeroExit(code: Int32, stderr: String)
        case executableNotFound(path: String)
    }

    public init()

    /// Run `executable` with `arguments`, optionally inside `cwd`, with `env`
    /// (nil means inherit). Returns on child exit. Captures stdout + stderr.
    /// Throws `executableNotFound` if `executable` does not exist or is not
    /// executable; `spawnFailed` if `Process.run()` throws; `nonZeroExit` if
    /// the process exits with a non-zero status code.
    public func run(executable: URL,
                    arguments: [String],
                    cwd: URL? = nil,
                    env: [String: String]? = nil) async throws -> Result
}
```

**Lifetime**: each `run` is one-shot.
**Threading**: actor; caller awaits.

---

## `StdioJSONRPCTransport`

**File**: `src/Core/AgentCore/External/StdioJSONRPCTransport.swift`
**Wraps**: `Foundation.Process` for a long-lived stdin/stdout/stderr agent session.
**Consumers**:
- `AgentEngine` through `LiveAgentTransportFactory` when an adapter declares `.stdioJSONRPC` (Codex App Server) or `.agentClientProtocol` (ACP client adapter).

**Public API**: internal `AgentTransport` conformance.

```swift
public actor StdioJSONRPCTransport: AgentTransport {
    public nonisolated let outboundBytes: AsyncStream<Data>
    public nonisolated let bellEvents: AsyncStream<Void>
    public nonisolated var terminalSnapshot: (any TerminalSnapshotting)? { nil }

    public init(launch: AgentTransportLaunchSpec) throws
    public func write(_ data: Data) async throws
    public func interrupt() async
    public func close() async
}
```

**Lifetime**: one long-lived process per agent session. Stdout is the adapter
input stream; stderr is kept as a bounded diagnostic tail and never surfaced as
agent output.
**Threading**: actor; readability handlers bounce into actor methods.

---

## `ACPTerminalProcess`

**File**: `src/AgenticCLIs/AgentClientProtocol/External/ACPTerminalProcess.swift`
**Wraps**: `Foundation.Process` for a short-lived reverse-terminal subprocess.
**Consumers**:
- `ACPTerminalSession` when an ACP agent server calls `terminal/create`.

**Public API**:

```swift
public actor ACPTerminalProcess {
    public struct Snapshot: Sendable {
        public let output: String
        public let exitCode: Int32?
        public let truncated: Bool
    }

    public func start(executable: URL, arguments: [String], cwd: URL?,
                      environment: [String: String]?) throws
    public func snapshot() -> Snapshot
    public func waitForExit() async -> Int32?
    public func kill()
    public func release()
}
```

**Lifetime**: one new process per `terminal/create` (not reused). Output is
bounded; callers poll via `terminal/output` and tear down with `kill`/`release`.
**Threading**: actor; process pipes are drained on a background queue.

---

## `CertificateIdentityImporter`

**File**: `src/Remote/AgentRemoteControl/External/CertificateIdentityImporter.swift`
**Wraps**: `Security.SecPKCS12Import`, `SecIdentityCopyCertificate`, `SecCertificateCopyData`.
**Consumers**:
- `CertificateManager.loadOrCreate` — imports the persisted P12 archive into a `SecIdentity` and derives the SHA-256 fingerprint for pairing.

**Public API**:

```swift
public enum CertificateIdentityImporter {
    public enum ImportError: Error, Sendable { ... }
    public struct Bundle: @unchecked Sendable { ... }

    public static func importIdentity(p12Data: Data, password: String) throws -> Bundle
}
```

---

## `KeychainStore`

**File**: `src/Core/AgentCore/External/KeychainStore.swift`
**Wraps**: `Security.SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete`.
**Consumers**:
- `PairedDeviceStore.loadAll` / `save` / `deleteToken` — paired-device records.
- `CertificateManager.{readPassword,storePassword,deletePassword}` — P12 archive password.

**Public API**:

```swift
public actor KeychainStore {
    public enum KeychainError: Error, Sendable, Equatable {
        case osStatus(OSStatus)
        case notFound
    }

    public struct Entry: Sendable, Equatable {
        public let account: String
        public let data: Data
    }

    public init()

    /// Returns the data stored at `(service, account)`, or nil if missing.
    public func read(service: String, account: String) -> Data?

    /// Atomically replace any existing entry at `(service, account)`.
    public func write(service: String, account: String, data: Data) throws

    /// No-op if missing.
    public func delete(service: String, account: String)

    /// All entries for a service. Used by stores that key by random tokens
    /// (e.g. PairedDeviceStore) and need to enumerate all records.
    public func enumerate(service: String) -> [Entry]

    /// Delete every entry for the service. Test/admin reset path.
    public func deleteAll(service: String)
}
```

**Lifetime**: stateless. One shared instance per process is fine.
**Threading**: actor.

---

## `FSEventsStream`

**File**: `src/Core/AgentCore/External/FSEventsStream.swift`
**Wraps**: `CoreServices.FSEventStream*`.
**Consumers**:
- `FSEventsWatcher` — adds gitignore filtering and kind decoding on top.

**Public API**:

```swift
public actor FSEventsStream {
    public struct RawEvent: Sendable {
        public let path: String
        public let flags: FSEventStreamEventFlags
        public let observedAt: Date
    }

    public enum FSEventsError: Error, Sendable, Equatable {
        case streamCreateFailed
    }

    public nonisolated let events: AsyncStream<RawEvent>

    public init(paths: [String], debounce: TimeInterval = 0.2)

    public func start() throws
    public func stop()
}
```

**Lifetime**: one stream per workspace.
**Threading**: actor; `events` is consumed from any task.

---

## `NetworkTransport.unixSocket` (extension)

**File**: extends `src/Core/AgentCore/Network/NetworkTransport.swift` + `src/Core/AgentCore/Network/LiveNetworkTransport.swift` + `src/Core/AgentCore/Network/InMemoryNetworkTransport.swift`.
**Wraps**: `Network.NWListener` / `NWConnection` for Unix-domain sockets (so `HookServer` stops touching `NWListener` directly).
**Consumers**:
- `HookServer` — UDS listener for per-session hook callbacks.

**Public API additions**:

```swift
public enum NetworkAddress {
    // existing cases…
    case unixSocket(path: String)   // NEW
}
```

`LiveNetworkTransport` adds a branch in `listen(on:options:)` that builds `NWParameters(unix:)` for `.unixSocket`. `InMemoryNetworkTransport` shares a path → mailbox map similar to its port table.

**`port` field on the returned `NetworkListenerHandle`**: for unix sockets this is `0` (irrelevant).

**Lifetime**: same as TCP listener.
**Threading**: same.

---

## `BonjourBroadcaster`

**File**: `src/Remote/AgentRemoteControl/BonjourBroadcaster.swift`
**Wraps**: `Network.NWListener.Service` + TXT record building (the existing `BonjourAdvertiser` is renamed/refactored). Note: not `Foundation.NetService` — the existing code uses NWListener-as-service.
**Consumers**:
- `CodemixerDaemon` — advertises the daemon's pairing service.

**Public API**:

```swift
public actor BonjourBroadcaster {
    public struct Configuration: Sendable {
        public var serviceType: String     // e.g. "_codemixer._tcp"
        public var name: String            // e.g. "Codemixer"
        public var port: UInt16
        public var txt: [String: String]
    }

    public enum BroadcastError: Error, Sendable, Equatable {
        case listenFailed(detail: String)
    }

    public init()

    public func start(_ configuration: Configuration) throws
    public func stop()
    public func updateTXT(_ txt: [String: String])
}
```

The existing `BonjourAdvertiser` becomes a thin policy layer that constructs the `Configuration` from `(deviceName, port, pairingState, certificateFingerprint)` and forwards to the broadcaster.

**Lifetime**: one broadcaster per daemon.
**Threading**: actor.

---

## `SpeechCapture`

**File**: `src/AgentUI/External/SpeechCapture.swift`
**Wraps**: `AVFoundation.AVAudioEngine` + `Speech.SFSpeechRecognizer` + `Speech.SFSpeechAudioBufferRecognitionRequest`.
**Consumers**:
- `VoiceInputService` — drives the composer's mic button + waveform.

**Public API**:

```swift
@MainActor
public final class SpeechCapture {
    public enum Event: Sendable {
        case partial(String)
        case final(String)
        case audioLevel(Float)
        case error(String)
    }

    public enum CaptureError: Error, Sendable, Equatable {
        case unauthorized
        case recognizerUnavailable
        case engineStartFailed(detail: String)
    }

    public init()

    /// Request `SFSpeechRecognizer.authorization`. Returns `true` on authorized.
    public func requestAuthorization() async -> Bool

    /// Start audio engine + recognition task. Returns a stream of events.
    /// Throws `CaptureError` on failure to start.
    public func start() throws -> AsyncStream<Event>

    /// Stop audio engine + recognition task; flush any partial transcript as
    /// the stream's final `.final` event before finishing.
    public func stop()
}
```

`VoiceInputService` consumes the stream and maps `Event` cases onto its own observable state (`partialTranscript`, `latestTranscript`, `audioLevels`).

**Lifetime**: one capture per `VoiceInputService` instance.
**Threading**: `@MainActor`; events delivered on the main actor.

---

## `SpeechSynthesis`

**File**: `src/AgentUI/External/SpeechSynthesis.swift`
**Wraps**: `AVFoundation.AVSpeechSynthesizer` + `AVSpeechUtterance`.
**Consumers**:
- `TTSService` — assistant bubble playback.

**Public API**:

```swift
@MainActor
public final class SpeechSynthesis {
    public init()

    public private(set) var isSpeaking: Bool { get }

    /// Enqueue an utterance with the given rate / pitch.
    public func speak(_ text: String, rate: Float, pitch: Float)
    public func pause()
    public func resume()
    public func stop()
    /// Stop the current utterance at the next word boundary.
    public func skipParagraph()
}
```

`TTSService` keeps `currentBubbleID` and the markdown-stripping logic; it just hands cleaned text to `SpeechSynthesis.speak` per paragraph.

**Lifetime**: one per TTSService.
**Threading**: `@MainActor`.

---

## `SystemNotifications`

**File**: `src/AgentUI/External/SystemNotifications.swift`
**Wraps**: `UserNotifications.UNUserNotificationCenter` + `AppKit.NSSound`.
**Consumers**:
- `UserNotificationBridge` — bus → notification routing.

**Public API**:

```swift
@MainActor
public final class SystemNotifications {
    public init()

    /// Request `.alert + .sound` authorization. Fire-and-forget.
    public func requestPermission()

    /// System bell.
    public func bell()

    /// Post a banner notification immediately.
    public func post(title: String, body: String)
}
```

`UserNotificationBridge` keeps its bus-tail logic; it just calls `SystemNotifications` for the actual OS interaction.

**Lifetime**: one per bridge.
**Threading**: `@MainActor`.

---

## What "wrapper" does not mean

These wrappers are not protocol seams. They have one production implementation each. Tests exercise them against the real OS via happy paths. If a test needs to assert behaviour without the OS, it tests the consumer of the wrapper, not a fake of the wrapper.

The point is to **localise** every framework dependency so:
1. Future iOS / iPadOS / visionOS targets diff at the wrapper, not throughout business code.
2. A grep for `Foundation.Process` returns exactly one file.
3. When Apple deprecates an API, the wrapper is the only file that changes.
