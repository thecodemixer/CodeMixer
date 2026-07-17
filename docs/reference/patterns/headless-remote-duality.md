# Pattern: Headless + remote duality

**Scope.** Architecting one engine that runs identically inside a GUI process (in-process) and a headless daemon process (background), with a network protocol used both by remote clients and — verbatim — by the GUI when talking to the daemon. The GUI becomes "just another client," so the multi-client behaviours fall out for free.

**When to use.** Any product that wants:

- Long-running background work after the GUI quits.
- A mobile companion app over local network.
- Scriptable / automatable behaviour.
- Multi-window or multi-user coherence.

**When not to use.** Strict single-process products. Apps that aren't allowed to spawn background daemons (some App Store sandboxed contexts).

---

## The two deployment modes

**Mode A — In-process (default).**

```
┌──────────────────────────────────────────┐
│  GUI app                                  │
│   └─→ Engine (actor, in-process)          │
│        └─→ Subsystems                      │
│                                            │
│  AgentRemoteControl (optional, off)        │
└──────────────────────────────────────────┘
```

**Mode B — Daemon + GUI + Remote.**

```
┌──────────────────────────────────────────┐
│  GUI app                                  │
│   └─→ Loopback WebSocket client of daemon │
└─────────────────┬────────────────────────┘
                  │ ws://127.0.0.1:8421/v1/ws  (daemon default; wss when TLS on)
                  ▼
┌──────────────────────────────────────────┐
│  Daemon (codemixerd)                      │
│   └─→ Engine (actor)                       │
│        └─→ Subsystems                      │
│   └─→ RemoteControlServer                  │
│   └─→ HTTPSidecarServer (:8422)            │
└──────────────────┬───────────────────────┘
                   │ ws/wss://lan:8421  (paired; TLS recommended for LAN)
                   ▼
              ┌─────────────┐
              │ Phone client│
              └─────────────┘
```

The user toggles modes through one setting. Mode A is default; Mode B activates when the user enables a LaunchAgent (or systemd unit) for the daemon.

---

## The load-bearing property

> *In Mode B, the GUI is just another remote client.*

There is **no GUI fast path.** The GUI sends `Command` frames over loopback the same way the phone sends them over LAN. It subscribes to `Event` frames the same way. It pays the encoding cost for every interaction.

**Terminology.** *Remote client* also names connected WebSocket peers counted by `RemoteControlServer` — in Mode B that count includes the GUI itself. See [architecture.md §4.1](../../architecture.md) and [`src/Remote/AgentRemoteControl/README.md`](../../../src/Remote/AgentRemoteControl/README.md).

This sounds wasteful. It pays for itself:

- **Multi-client coherence is automatic.** If the GUI couldn't drop into client mode cleanly, you'd need separate paths for "in-process" vs "remote" updates, with synchronisation between them. With the duality, there's one path.
- **Test surface is shared.** The phone and GUI both enter through the same typed command port, so behaviour can be tested at the engine seam and then once again over the wire.
- **Parity is layered.** `RemoteParityTests` (see [wire-domain-boundary](wire-domain-boundary.md)) guard protocol shape; engine tests cover command side effects; remote E2E tests cover command results and ordering seen by network clients.

---

## The engine has no opinion about mode

```swift
public actor Engine: CommandPort {
    public let bus: MulticastEventBus
    private var subsystems: SubsystemSet?

    public init(seams: Seams = .live) { … }

    public func start(...) async throws { … }
    public func shutdown(reason:) async { … }
    public func send(_ command: Command) async throws { … }
}
```

The engine doesn't know whether it's inside a GUI or a daemon. It accepts commands, emits events. The only place "mode" is observable to the engine is via the count of bus subscribers — which the engine inspects only for idle-exit logic.

---

## The daemon binary

A single-file executable target wires the engine, the adapter (or adapter registry), and the remote-control server. No SwiftUI imports — checked by CI:

```swift
// Remote/CodemixerDaemon/main.swift
import AgentCore
import AgentRemoteControl
import ClaudeCode
import AgentProtocol
import OSLog

@main
struct CodemixerDaemon {
    static func main() async throws {
        let log = Logger(subsystem: "com.codecave.Codemixer", category: "Daemon")
        log.notice("daemon starting pid=\(getpid(), privacy: .public)")

        let engine = Engine()
        let server = RemoteControlServer(engine: engine,
                                         pairing: pairing,
                                         certificates: certificates,
                                         transport: transport,
                                         random: seams.random)
        try await server.start(configuration: .init(
            host: .loopback,
            port: RemoteDefaults.webSocketPort,  // 8421
            requireAuth: false,
            useTLS: false                        // plain ws on loopback; enable for LAN
        ))

        Task {
            var consecutiveIdleChecks = 0
            while true {
                try? await Task.sleep(for: DaemonDefaults.idleCheckInterval)
                let clients = await runtime.server?.connectedClientCount ?? 0
                let engineState = await engine.currentState
                let isIdle = clients == 0 && (engineState == .stopped || engineState == .stopping)
                consecutiveIdleChecks = isIdle ? consecutiveIdleChecks + 1 : 0
                if consecutiveIdleChecks >= DaemonDefaults.idleExitAfterChecks {
                    await runtime.stop()
                    await engine.shutdown(reason: .naturalExit)
                    exit(0)
                }
            }
        }
        // … await signal handling …
    }
}
```

**Enforcing no SwiftUI:** `codemixerd` target dependencies exclude `AgentUI`; `scripts/check-no-swiftui-imports.swift` catches accidental imports.

---

## Idle exit

A daemon that never quits is a resource leak. `CodemixerDaemon` self-exits when:

- 0 connected remote clients **and**
- `engine.currentState` is `.stopped` or `.stopping` **and**
- this has been true for `DaemonDefaults.idleExitAfterChecks` consecutive checks at `DaemonDefaults.idleCheckInterval` apart (10 × 60s = **10 minutes**).

There is no separate `IdleExitMonitor` type — the loop lives inline in `src/Remote/CodemixerDaemon/main.swift`.

The LaunchAgent / systemd unit sets `KeepAlive` to restart only on **unsuccessful** exit, so the idle exit is not auto-restarted. Next GUI launch spawns the daemon again.

---

## The GUI's mode probe

`Bootstrap.start()` in `CodemixerApp` probes Mode B when `CODEMIXER_UI_BACKEND=daemon` or the LaunchAgent is installed:

```swift
if await connectDaemonBackedUI(adapter:) { return }
await SilentDiagnostics.shared.record(kind: .modeBFallback, ...)
// fall back to in-process AgentEngine
```

`connectDaemonBackedUI` uses `RemoteEngineClient` on loopback — same wire as any remote peer. Failure is silent to the user (journal entry only).

The UI layer's view models see the same `AgentEngineCommandPort` whether in-process or remote. Switching modes tears down the in-process engine and reconnects to the daemon — view models bind to the same command port abstraction.

---

## Loopback bridging — bytes are identical to LAN

The GUI sends frames over `ws://127.0.0.1:8421/v1/ws` when talking to the daemon (plain WebSocket by default) or `wss://127.0.0.1:8421/v1/ws` when the embedded server has TLS enabled. The phone sends them over `wss://192.168.1.42:8421/v1/ws` on LAN. The bytes are identical. The pairing flow differs (loopback may skip PIN when auth is off; LAN requires PIN — see [lan-pairing-and-auth](lan-pairing-and-auth.md)).

**TLS policy**

- `RemoteDefaults.webSocketPort` (8421) and `RemoteDefaults.sidecarPort` (8422) are owned in `Core/AgentCore/RemoteDefaults.swift` — do not hardcode elsewhere.
- `codemixerd` defaults to plain `ws://` on loopback (`useTLS: false`) for local development.
- The GUI embedded remote server defaults to `useTLS: true` when the user enables remote access from Settings.
- LAN clients should use TLS (`wss://`) with fingerprint pinning; see [lan-pairing-and-auth](lan-pairing-and-auth.md).

---

## Server-side coherence

Two clients running side by side — GUI on Mac, app on phone — see the same engine state because:

- Both subscribe to the same `MulticastEventBus`.
- Both emit `Command`s that the engine serialises.
- "First-responder wins" semantics resolve concurrent commands (see [event-sourced-typed-port-core](event-sourced-typed-port-core.md)).
- Activity timing is server-resolved (see [coherent-activity-heartbeat](coherent-activity-heartbeat.md)).

Clients never disagree about *what* the engine is doing or *when* a turn started. They may disagree about cosmetics (text wrap, scroll position) but never about state.

---

## Lifecycle scenarios

| Scenario | What happens |
| --- | --- |
| User launches GUI, daemon not running | GUI starts in-process engine. Mode A. |
| User toggles "Run in background" | GUI installs LaunchAgent, bootstraps daemon, reconnects via loopback. Mode B. |
| User quits GUI in Mode B | Daemon continues. Engine state persists. Phone still connected. |
| User relaunches GUI in Mode B | GUI connects to daemon, subscribes with `lastSeenEventID: nil` (fresh fold), bus replays last 500 events. UI shows current state. |
| Network drop on phone | Bus keeps the queue alive for 60 s; on reconnect with stored `lastSeenEventID`, missed events replay. |
| Daemon crashes | LaunchAgent `KeepAlive` restarts. GUI's WS connection reconnects on health check. |
| User toggles "Run in background" off | GUI tears down daemon (`launchctl bootout`), spawns in-process engine. |

The engine, in all of these, behaves identically.

---

## Operating-system hooks

Different platforms have different daemon stories:

| Platform | Mechanism |
| --- | --- |
| macOS | `launchctl bootstrap gui/$UID <plist>` for per-user agents. `~/Library/LaunchAgents/<bundleID>.daemon.plist`. |
| Linux | `systemctl --user enable <unit>`; user service unit. |
| Windows | Task Scheduler entry running as the user. (Background services require admin; avoid.) |
| iOS / iPadOS | No traditional daemon; long-running background tasks via `BGTaskScheduler`. The remote-control client is the *only* shape here. |

The engine code is unchanged across these; only the bootstrap script differs.

---

## Anti-patterns

| Anti-pattern | Why it's bad |
| --- | --- |
| The GUI has direct method access to `Engine` in Mode B | Re-introduces the fast path; multi-client coherence breaks. The GUI must go through the proxy. |
| The daemon imports a UI framework "just for a small utility" | Sandbox / signing / start-up surprises. CI must enforce. |
| Mode toggle requires re-launching the GUI | Confusing; do it live by tearing down `EngineConnection` and re-resolving. |
| Daemon never exits | Wastes resources. Idle-exit + LaunchAgent restart is the right shape. |
| Loopback uses plaintext, LAN uses TLS | Acceptable when loopback is auth-off and LAN uses TLS + PIN. Document both modes in tests. |
| Engine `@MainActor`-isolated | Daemon can't schedule it; you can't deploy Mode B. Plain `actor`. |

---

## Codemixer instance

- `Engine` ↔ `AgentEngine` (in `Core/AgentCore/Engine/AgentEngine.swift`).
- `EngineRemoteProxy` ↔ planned client in `AgentUI` (post-v1.1 when daemon-backed UI is exercised in production).
- `RemoteControlServer` ↔ `Remote/AgentRemoteControl/RemoteControlServer.swift`.
- Daemon binary ↔ `codemixerd` SPM product (`swift build --product codemixerd`).
- LaunchAgent plist template ↔ `Resources/com.codecave.Codemixer.daemon.plist`.

See [docs/architecture.md §§4, 22](../../architecture.md) for the Codemixer-specific narrative.

---

## Minimum viable adoption

1. Make sure your engine is a plain `actor`, not `@MainActor`.
2. Ship the remote-control server with a loopback bind from day one.
3. Define `CommandPort` and have both `Engine` and `EngineRemoteProxy` conform.
4. Have the GUI talk to its engine through `CommandPort`, not directly.
5. Add a daemon executable target. Wire engine + server. CI-grep for UI frameworks.
6. Add idle-exit when the daemon is built. Default 10 min.
7. Add a one-toggle setting that installs / removes the LaunchAgent.
8. Test: launch GUI, toggle on, quit GUI, reconnect GUI — state survives.

When the mobile client is built later, it imports the portable wire module and you're done.
