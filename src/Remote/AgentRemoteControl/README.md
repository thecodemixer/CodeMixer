# AgentRemoteControl

WebSocket remote control for Codemixer: TLS pairing, framed JSON envelopes,
multicast event fan-out to N clients, and the loopback client the Mac GUI uses
in Mode B. This target is **macOS-only** and must not import SwiftUI.

Read [`docs/architecture.md`](../../../docs/architecture.md) §4 and §4.1 for
deployment modes and the two senses of **remote client**. Pattern background:
[`docs/reference/patterns/headless-remote-duality.md`](../../../docs/reference/patterns/headless-remote-duality.md).

---

## The two senses of "remote client"

| Sense | Type / symbol | Direction | Question it answers |
| --- | --- | --- | --- |
| **Client role** | `RemoteEngineClient` | Consumer → server | "How does this process send `AgentCommand`s and fold `AgentEvent`s over the wire?" |
| **Connected-peer count** | `RemoteControlServer.connectedClientCount` | Server observes attachments | "How many WebSocket peers are connected right now?" |

In **Mode B**, the Mac GUI holds a `RemoteEngineClient` (client role) *and*
counts as one peer in the daemon's `connectedClientCount`. In **Mode A** with
remote access enabled, the GUI still uses in-process `AgentEngine`; only
*external* peers increment the count.

---

## Layout

```
src/Remote/
├── AgentRemoteControl/          # this library target
│   ├── README.md                # this file
│   ├── RemoteControlServer.swift    # WSS listener, per-connection actors
│   ├── ClientConnection.swift       # one peer's read/write lifecycle
│   ├── RemoteEngineClient.swift     # client-role `AgentEngineCommandPort`
│   ├── RemoteRuntimeCoordinator.swift  # shared GUI/daemon bootstrap
│   ├── PairingService.swift         # PIN + bearer tokens
│   ├── PairedDeviceStore.swift      # persisted paired devices
│   ├── CertificateManager.swift     # self-signed TLS identity
│   ├── HTTPSidecarServer.swift      # :8422 health, attachments, diagnostics
│   ├── BonjourAdvertiser.swift      # `_codemixer._tcp` when LAN is on
│   └── External/                    # Network.framework / Security wrappers
└── CodemixerDaemon/             # thin `@main` — engine + server, no SwiftUI
```

Port numbers, hosts, and paths have a single owner: `RemoteDefaults` in
`AgentCore`.

---

## Server path (`RemoteControlServer`)

Accepts WebSocket connections on `RemoteDefaults.webSocketPort` (8421). Each
`ClientConnection`:

1. Optionally pairs (`ClientFrame.pair`) or authenticates (`ClientFrame.auth`).
2. Subscribes with `ClientFrame.subscribe(lastSeenEventID:)` — the bus replays
   from the ring buffer or returns `checkpointExpired`.
3. Receives live `ServerFrame.event` fan-out from `MulticastEventBus`.
4. Dispatches `ClientFrame.command` into `AgentEngine.send(_:)`.

`observeClientCount(_:)` notifies when `connections.count` changes. The GUI
wires this to `EngineViewModel.setConnectedRemoteClients`; the daemon uses it
for idle exit.

Started from:

- **`codemixerd`** — always, on loopback (TLS off by default).
- **`Codemixer.app`** — only when the user enables **Settings → Remote → Enable
  remote access** (`Bootstrap+Remote.startRemote`).

---

## Client path (`RemoteEngineClient`)

Implements `AgentEngineCommandPort` for any wire consumer:

| Caller | Configuration | Purpose |
| --- | --- | --- |
| `Bootstrap.connectDaemonBackedUI` | `.init(reconnect: .daemon)` | Mode B loopback GUI |
| Future iOS / CLI tools | address + TLS + bearer token | LAN remote control |
| Tests | `InMemoryNetworkTransport` / fakes | `RemoteEngineClientTests`, E2E |

On `connect()`: handshake, subscribe, decode `ServerFrame`s into local
`bus.publish`. On disconnect with `reconnect` set: exponential backoff until
`maxAttempts` or success.

Stored on `Bootstrap.remoteClient` when Mode B probe succeeds. **Not** the same
as `connectedRemoteClients` (that is the server's peer count).

---

## GUI integration map

| File | Responsibility |
| --- | --- |
| `CodemixerApp/Bootstrap.swift` | Mode B probe; sets `remoteClient`, binds `EngineViewModel` to it |
| `CodemixerApp/Bootstrap+Remote.swift` | Opt-in server start; `observeClientCount` → view model |
| `AgentUI/ViewModel/EngineViewModel.swift` | `connectedRemoteClients` for toolbar chip |
| `AgentUI/Components/Primitives.swift` | `ConnectedClientsChip` (visible when count > 0) |
| `AgentUI/Settings/SettingsView.swift` | Pairing, LAN toggle, LaunchAgent, connected count |

---

## Wire surface

Client ↔ server frames live in `AgentProtocol` (`ClientFrame`, `ServerFrame`).
Domain events cross the boundary through `WireCodec` only. Parity is enforced by
`tests/Remote/RemoteParityTests` and `RemoteControlE2ETests`.

HTTP sidecar (port 8422): `GET /v1/health` (includes `clients` count),
`POST /v1/attachments`, `GET /v1/diagnostics/silent`. See root `README.md`
**Headless mode**.

---

## Tests

| Suite | Path |
| --- | --- |
| Client handshake, reconnect, command results | `tests/Remote/AgentRemoteControlTests/RemoteEngineClientTests.swift` |
| Pairing, TLS, sidecar, E2E ordering | `tests/Remote/AgentRemoteControlTests/RemoteControlE2ETests.swift` |
| Wire round-trip + command dispatch parity | `tests/Remote/RemoteParityTests/` |

Run: `swift test --no-parallel --filter RemoteEngineClient`

---

## Tripwires

- **No SwiftUI** in this target — enforced by `scripts/check-no-swiftui-imports.swift`.
- **No adapter imports** — `AgentRemoteControl` depends on `AgentCore` +
  `AgentProtocol` only; adapters register at app/daemon entry points.
- **Do not add a GUI fast path** — Mode B GUI must use `RemoteEngineClient`, not
  direct `AgentEngine` method calls across processes.
