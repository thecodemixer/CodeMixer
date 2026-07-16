import Foundation

/// Top-level frame sent from a client to the server over the WebSocket.
public enum ClientFrame: Sendable, Codable {
    case command(id: UUID, command: AgentCommand)
    /// Subscribe to the event bus.
    ///
    /// - Parameter lastSeenEventID: The `HistoryEntry.id` of the last event the
    ///   client received in a previous connection. When provided, the server
    ///   replays only events that arrived *after* that checkpoint instead of
    ///   re-sending the full ring-buffer. Pass `nil` on a fresh connection.
    case subscribe(lastSeenEventID: UUID? = nil)
    case snapshot(kind: SnapshotKind)
    case ping(id: UUID)
    case pair(pin: String, clientName: String)
    case auth(token: String)

    public var version: WireVersion { .current }
}

/// Result of a checkpointed subscribe — mirrors `MulticastEventBus.SubscribeOutcome`.
public enum SubscribeReplayOutcome: String, Sendable, Codable {
    case fresh
    case resumed
    case checkpointExpired
}

/// Top-level frame sent from the server to a client over the WebSocket.
public enum ServerFrame: Sendable, Codable {
    /// A bus-tagged engine event. `id` is the opaque checkpoint token clients
    /// store and pass back as `subscribe.lastSeenEventID` on reconnect.
    case event(id: UUID, event: AgentEventWire)
    case result(for: UUID, ok: Bool, error: WireAgentError?)
    case snapshot(kind: SnapshotKind, payload: Data)
    case pong(for: UUID)
    case paired(token: String)
    case pairFailed(reason: PairFailureReason)
    case versionMismatch(supported: [WireVersion])
    /// Acknowledgement sent after replaying missed events. `latestEventID` is
    /// the bus ID of the most recently published event at subscribe time;
    /// clients should store this value and send it as `lastSeenEventID` on
    /// their next reconnect. `nil` means the bus has no events yet.
    /// `outcome` tells reconnecting clients whether replay is complete,
    /// resumed from a known checkpoint, or the checkpoint fell out of the ring.
    case subscribed(latestEventID: UUID?, outcome: SubscribeReplayOutcome)

    public var version: WireVersion { .current }
}

/// Reason a pairing attempt was rejected.
public enum PairFailureReason: String, Sendable, Codable {
    case invalidPIN
    case expiredPIN
    case rateLimited
    case lockedOut
}

// MARK: - Codable shape: tagged-union JSON

/// Hand-rolled coding so wire JSON matches the documented schema
/// (`{ "type": "<case>", ... }`), independent of Swift's default
/// `singleValueContainer` synthesis.
extension ClientFrame {
    private enum CodingKeys: String, CodingKey {
        case v, type, id, command, lastSeenEventID, kind, pin, clientName, token
    }
    private enum Tag: String, Codable { case command, subscribe, snapshot, ping, pair, auth }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(WireVersion.self, forKey: .v)
        guard version == .current else {
            throw DecodingError.dataCorruptedError(forKey: .v,
                                                   in: c,
                                                   debugDescription: "Unsupported wire version")
        }
        switch try c.decode(Tag.self, forKey: .type) {
        case .command:
            self = .command(id: try c.decode(UUID.self, forKey: .id),
                            command: try c.decode(AgentCommand.self, forKey: .command))
        case .subscribe:
            self = .subscribe(
                lastSeenEventID: try c.decodeIfPresent(UUID.self, forKey: .lastSeenEventID)
            )
        case .snapshot:
            self = .snapshot(kind: try c.decode(SnapshotKind.self, forKey: .kind))
        case .ping:
            self = .ping(id: try c.decode(UUID.self, forKey: .id))
        case .pair:
            self = .pair(pin: try c.decode(String.self, forKey: .pin),
                         clientName: try c.decode(String.self, forKey: .clientName))
        case .auth:
            self = .auth(token: try c.decode(String.self, forKey: .token))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .v)
        switch self {
        case .command(let id, let cmd):
            try c.encode(Tag.command, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(cmd, forKey: .command)
        case .subscribe(let lastSeenEventID):
            try c.encode(Tag.subscribe, forKey: .type)
            try c.encodeIfPresent(lastSeenEventID, forKey: .lastSeenEventID)
        case .snapshot(let kind):
            try c.encode(Tag.snapshot, forKey: .type)
            try c.encode(kind, forKey: .kind)
        case .ping(let id):
            try c.encode(Tag.ping, forKey: .type)
            try c.encode(id, forKey: .id)
        case .pair(let pin, let name):
            try c.encode(Tag.pair, forKey: .type)
            try c.encode(pin, forKey: .pin)
            try c.encode(name, forKey: .clientName)
        case .auth(let token):
            try c.encode(Tag.auth, forKey: .type)
            try c.encode(token, forKey: .token)
        }
    }
}

extension ServerFrame {
    private enum CodingKeys: String, CodingKey {
        case v, type, id, event, `for`, ok, error, kind, payload,
             token, reason, supported, latestEventID, outcome
    }
    private enum Tag: String, Codable {
        case event, result, snapshot, pong, paired, pairFailed, versionMismatch, subscribed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(WireVersion.self, forKey: .v)
        guard version == .current else {
            throw DecodingError.dataCorruptedError(forKey: .v,
                                                   in: c,
                                                   debugDescription: "Unsupported wire version")
        }
        switch try c.decode(Tag.self, forKey: .type) {
        case .event:
            self = .event(id: try c.decode(UUID.self, forKey: .id),
                          event: try c.decode(AgentEventWire.self, forKey: .event))
        case .result:
            self = .result(for: try c.decode(UUID.self, forKey: .for),
                           ok: try c.decode(Bool.self, forKey: .ok),
                           error: try c.decodeIfPresent(WireAgentError.self, forKey: .error))
        case .snapshot:
            self = .snapshot(kind: try c.decode(SnapshotKind.self, forKey: .kind),
                             payload: try c.decode(Data.self, forKey: .payload))
        case .pong:
            self = .pong(for: try c.decode(UUID.self, forKey: .for))
        case .paired:
            self = .paired(token: try c.decode(String.self, forKey: .token))
        case .pairFailed:
            self = .pairFailed(reason: try c.decode(PairFailureReason.self, forKey: .reason))
        case .versionMismatch:
            self = .versionMismatch(supported: try c.decode([WireVersion].self, forKey: .supported))
        case .subscribed:
            self = .subscribed(
                latestEventID: try c.decodeIfPresent(UUID.self, forKey: .latestEventID),
                outcome: try c.decode(SubscribeReplayOutcome.self, forKey: .outcome)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .v)
        switch self {
        case .event(let id, let e):
            try c.encode(Tag.event, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(e, forKey: .event)
        case .result(let id, let ok, let err):
            try c.encode(Tag.result, forKey: .type)
            try c.encode(id, forKey: .for)
            try c.encode(ok, forKey: .ok)
            try c.encodeIfPresent(err, forKey: .error)
        case .snapshot(let kind, let payload):
            try c.encode(Tag.snapshot, forKey: .type)
            try c.encode(kind, forKey: .kind)
            try c.encode(payload, forKey: .payload)
        case .pong(let id):
            try c.encode(Tag.pong, forKey: .type)
            try c.encode(id, forKey: .for)
        case .paired(let token):
            try c.encode(Tag.paired, forKey: .type)
            try c.encode(token, forKey: .token)
        case .pairFailed(let reason):
            try c.encode(Tag.pairFailed, forKey: .type)
            try c.encode(reason, forKey: .reason)
        case .versionMismatch(let supported):
            try c.encode(Tag.versionMismatch, forKey: .type)
            try c.encode(supported, forKey: .supported)
        case .subscribed(let latestEventID, let outcome):
            try c.encode(Tag.subscribed, forKey: .type)
            try c.encodeIfPresent(latestEventID, forKey: .latestEventID)
            try c.encode(outcome, forKey: .outcome)
        }
    }
}
