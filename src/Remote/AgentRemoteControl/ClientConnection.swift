import Foundation
import OSLog
import AgentCore
import AgentProtocol

/// One client's session on the remote-control bus. Owns the bidirectional
/// message pump: engine → wire as `ServerFrame.event`; wire → engine as
/// `AgentCommand`.
///
/// Transport-agnostic — works against any `NetworkConnection`. In production
/// this is a TLS WebSocket; in tests it's a deterministic in-process pipe.
///
/// **Subscription lifecycle**: the sender only starts when the client sends a
/// `subscribe` frame. This avoids a race where the initial eager sender would
/// deliver history events before the client has a chance to declare its
/// `lastSeenEventID` checkpoint. Clients that send commands without subscribing
/// first still receive `result` frames; they just don't receive `event` frames.
///
/// **Reconnect-with-replay**: when a `subscribe` frame includes
/// `lastSeenEventID`, the bus replays only the events the client missed —
/// O(missed) rather than O(full-history). After the replay slice, the server
/// sends `ServerFrame.subscribed(latestEventID:outcome:)` so the client knows the
/// delta is complete and can update its own checkpoint.
final class ClientConnection: @unchecked Sendable {

    let id: UUID

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Client")
    private let connection: any NetworkConnection
    private let engine: any AgentEngineCommandPort
    private let bus: MulticastEventBus
    private let pairing: PairingService
    private let requireAuth: Bool
    private let onDeath: @Sendable (UUID) -> Void
    private let cancelLock = NSLock()
    private var cancelled = false
    private var authed: Bool
    private let decoder: JSONDecoder
    /// Serializes JSON encoding across the receiver and sender tasks.
    /// Foundation's `.iso8601` date strategy has shared mutable formatter
    /// state on some builds; concurrent event + command-result encodes have
    /// SIGSEGV'd under remote-control tests.
    private let frameEncoder = FrameSendEncoder()
    private var subscription: MulticastEventBus.Subscription?
    private var senderTask: Task<Void, Never>?
    private var receiverTask: Task<Void, Never>?

    init(id: UUID,
         connection: any NetworkConnection,
         engine: any AgentEngineCommandPort,
         bus: MulticastEventBus,
         pairing: PairingService,
         requireAuth: Bool,
         onDeath: @escaping @Sendable (UUID) -> Void) {
        self.id = id
        self.connection = connection
        self.engine = engine
        self.bus = bus
        self.pairing = pairing
        self.requireAuth = requireAuth
        self.onDeath = onDeath
        self.authed = !requireAuth

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func start() {
        // Only the receiver starts here. The sender starts lazily when the
        // client sends a `subscribe` frame — this avoids a race between
        // eager history replay and a checkpoint the client declares later.
        receiverTask = Task { [weak self] in
            await self?.authenticateFromMetadata()
            await self?.runReceiver()
        }
    }

    func cancel() {
        cancelLock.lock()
        guard !cancelled else {
            cancelLock.unlock()
            return
        }
        cancelled = true
        cancelLock.unlock()
        senderTask?.cancel()
        receiverTask?.cancel()
        if let sub = subscription {
            Task { [bus, sub] in await bus.unsubscribe(sub.id) }
        }
        Task { await connection.close() }
    }

    // MARK: - Pumps

    private func authenticateFromMetadata() async {
        guard requireAuth, let token = connection.metadata.bearerToken else { return }
        authed = await pairing.validateToken(token) != nil
    }

    private func runSender(stream: AsyncStream<MulticastEventBus.HistoryEntry>) async {
        for await entry in stream {
            guard !Task.isCancelled else { return }
            let wire = WireCodec.encode(entry.event)
            await send(.event(id: entry.id, event: wire))
        }
    }

    private func runReceiver() async {
        while !Task.isCancelled {
            let payload: Data?
            do { payload = try await connection.receive() }
            catch {
                log.warning("recv error id=\(self.id, privacy: .public) error=\(String(describing: error), privacy: .public)")
                onDeath(id); return
            }
            guard let payload else { onDeath(id); return }

            if let mismatch = versionProblem(in: payload) {
                await send(.versionMismatch(supported: [WireVersion.current]))
                await SilentDiagnostics.shared.record(
                    kind: .wireVersionRejected,
                    owner: "ClientConnection",
                    summary: "rejected client frame with unsupported wire version",
                    details: String(describing: mismatch)
                )
                log.warning("rejecting frame with v=\(String(describing: mismatch), privacy: .public)")
                continue
            }
            guard let frame = try? decoder.decode(ClientFrame.self, from: payload) else { continue }
            await dispatch(frame)
        }
    }

    private enum VersionProblem: CustomStringConvertible {
        case missing
        case unsupported(WireVersion)

        var description: String {
            switch self {
            case .missing: return "missing"
            case .unsupported(let version): return "\(version.rawValue)"
            }
        }
    }

    private struct VersionEnvelope: Decodable { let v: WireVersion? }

    private func versionProblem(in data: Data) -> VersionProblem? {
        guard let envelope = try? decoder.decode(VersionEnvelope.self, from: data) else { return nil }
        guard let v = envelope.v else { return .missing }
        return v == WireVersion.current ? nil : .unsupported(v)
    }

    private func send(_ frame: ServerFrame) async {
        // `send` is called from both the receiver task (command results) and
        // the sender task (subscribed event frames). Route encoding through
        // `frameEncoder` so those tasks cannot race inside Foundation's JSON
        // writer / shared `.iso8601` date formatting.
        guard let payload = await frameEncoder.encode(frame) else { return }
        try? await connection.send(payload)
    }

    private func dispatch(_ frame: ClientFrame) async {
        switch frame {
        case .ping(let id):
            await send(.pong(for: id))

        case .pair(let pin, let name):
            let outcome = await pairing.attemptPair(pin: pin, deviceName: name)
            switch outcome {
            case .success(let token, _):
                authed = true
                await send(.paired(token: token))
            case .invalidPIN:
                await send(.pairFailed(reason: .invalidPIN))
            case .expiredPIN:
                await send(.pairFailed(reason: .expiredPIN))
            case .rateLimited:
                await send(.pairFailed(reason: .rateLimited))
            case .lockedOut:
                await send(.pairFailed(reason: .lockedOut))
            }

        case .auth(let token):
            if await pairing.validateToken(token) != nil {
                authed = true
                await send(.paired(token: token))
            } else {
                await send(.pairFailed(reason: .invalidPIN))
            }

        case .subscribe(let lastSeenEventID):
            // Tear down any existing sender so we don't deliver stale events
            // alongside the fresh replay.
            senderTask?.cancel()
            if let existing = subscription {
                await bus.unsubscribe(existing.id)
            }

            let (newSub, outcome) = await bus.subscribeWithOutcome(after: lastSeenEventID)
            let latestID = await bus.lastPublishedID
            subscription = newSub
            // Capture the stream by value so the sender task never races the
            // receiver task on the `subscription` property.
            let stream = newSub.stream

            // Send the ack before starting the sender. The client uses
            // `latestEventID` as its checkpoint for the *next* reconnect.
            await send(.subscribed(latestEventID: latestID, outcome: wireOutcome(outcome)))

            senderTask = Task { [weak self] in await self?.runSender(stream: stream) }
            log.notice("client \(self.id, privacy: .public) subscribed after=\(String(describing: lastSeenEventID), privacy: .public) outcome=\(String(describing: outcome), privacy: .public)")

        case .snapshot(let kind):
            guard authed else {
                await send(.pairFailed(reason: .invalidPIN))
                return
            }
            await sendSnapshot(kind)

        case .command(let id, let command):
            guard authed else {
                let err = WireAgentError(code: "not_paired", message: "Pair before sending commands.")
                await send(.result(for: id, ok: false, error: err))
                return
            }
            do {
                try await engine.send(command)
                await send(.result(for: id, ok: true, error: nil))
            } catch let error as AgentError {
                await send(.result(for: id,
                                   ok: false,
                                   error: WireAgentError(code: error.code,
                                                         message: error.userMessage)))
            } catch {
                await send(.result(for: id,
                                   ok: false,
                                   error: WireAgentError(code: "unknown",
                                                         message: String(describing: error))))
            }
        }
    }

    private func sendSnapshot(_ kind: SnapshotKind) async {
        let checkpoint = await bus.lastPublishedID
        let sub = await bus.subscribe(after: checkpoint)
        do {
            try await engine.send(.requestSnapshot(kind))
        } catch {
            await bus.unsubscribe(sub.id)
            return
        }

        for await entry in sub.stream {
            guard !Task.isCancelled else {
                await bus.unsubscribe(sub.id)
                return
            }
            if case .snapshotReady(let snapshotKind, let payload) = entry.event,
               snapshotKind == kind {
                await send(.snapshot(kind: kind, payload: payload))
                await bus.unsubscribe(sub.id)
                return
            }
        }
        await bus.unsubscribe(sub.id)
    }

    private func wireOutcome(_ outcome: MulticastEventBus.SubscribeOutcome) -> SubscribeReplayOutcome {
        switch outcome {
        case .fresh: return .fresh
        case .resumed: return .resumed
        case .checkpointExpired: return .checkpointExpired
        }
    }
}

/// Actor-isolated JSON encoding for outbound `ServerFrame`s.
///
/// Keeps Foundation's non-thread-safe encoder / `.iso8601` formatting off the
/// concurrent receiver+sender path in `ClientConnection`.
private actor FrameSendEncoder {
    func encode(_ frame: ServerFrame) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(frame)
    }
}
