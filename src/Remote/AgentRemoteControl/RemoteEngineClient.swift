import Foundation
import AgentCore
import AgentProtocol

/// Remote `AgentEngineCommandPort` backed by Codemixer's WebSocket protocol.
///
/// **Client role** — any wire consumer (Mode B Mac GUI, iOS app, scripts).
/// Not to be confused with `RemoteControlServer.connectedClientCount` (how many
/// peers are attached to the server). See `Remote/AgentRemoteControl/README.md`
/// and `docs/architecture.md` §4.1.
///
/// The GUI can bind `EngineViewModel` to this client exactly as it binds to an
/// in-process `AgentEngine`: commands go out as `ClientFrame.command`, events
/// are decoded and republished on `bus`.
public actor RemoteEngineClient: AgentEngineCommandPort {
    public enum ClientError: Error, Sendable, Equatable {
        case disconnected
        case commandRejected(WireAgentError?)
        case versionMismatch([WireVersion])
    }

    /// Bounded exponential backoff for daemon-backed UI reconnect loops.
    public struct ReconnectPolicy: Sendable {
        public var maxAttempts: Int
        public var initialDelay: Duration
        public var maxDelay: Duration

        public init(maxAttempts: Int = 12,
                    initialDelay: Duration = .milliseconds(250),
                    maxDelay: Duration = .seconds(30)) {
            self.maxAttempts = maxAttempts
            self.initialDelay = initialDelay
            self.maxDelay = maxDelay
        }

        public static let daemon = ReconnectPolicy()
    }

    public struct Configuration: Sendable {
        public var address: NetworkAddress
        public var options: NetworkOptions
        /// When set, unexpected disconnects schedule reconnect attempts with
        /// exponential backoff until success or `maxAttempts` is exhausted.
        public var reconnect: ReconnectPolicy?

        public init(address: NetworkAddress = .loopback(port: RemoteDefaults.webSocketPort),
                    options: NetworkOptions = .webSocket(),
                    reconnect: ReconnectPolicy? = nil) {
            self.address = address
            self.options = options
            self.reconnect = reconnect
        }
    }

    public nonisolated let bus: MulticastEventBus

    private let transport: any NetworkTransport
    private let configuration: Configuration
    private let random: any RandomSource
    private let clock: any AgentClock
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var connection: (any NetworkConnection)?
    private var receiverTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pendingCommands: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var pendingSnapshots: [SnapshotKind: CheckedContinuation<Data, any Error>] = [:]
    private var lastSeenEventID: UUID?
    private var subscribed = false

    public init(configuration: Configuration = Configuration(),
                transport: any NetworkTransport = LiveNetworkTransport(),
                bus: MulticastEventBus = MulticastEventBus(),
                random: any RandomSource = SystemRandomSource(),
                clock: any AgentClock = SystemClock()) {
        self.configuration = configuration
        self.transport = transport
        self.bus = bus
        self.random = random
        self.clock = clock

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func connect() async throws {
        try await openConnection(subscribe: true)
    }

    public func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiverTask?.cancel()
        receiverTask = nil
        await connection?.close()
        connection = nil
        subscribed = false
        failPending(ClientError.disconnected)
    }

    public func send(_ command: AgentCommand) async throws {
        try await connect()
        let id = random.uuid()
        try await sendFrame(.command(id: id, command: command))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingCommands[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelPending(id) }
        }
    }

    internal func setLastSeenEventID(_ id: UUID?) {
        lastSeenEventID = id
    }

    // MARK: - Connection lifecycle

    private func openConnection(subscribe: Bool) async throws {
        guard connection == nil else {
            if subscribe, !subscribed {
                try await sendSubscribe()
            }
            return
        }
        let connection = try await transport.connect(to: configuration.address,
                                                     options: configuration.options)
        self.connection = connection
        receiverTask = Task { [weak self, connection] in
            await self?.receiveLoop(connection: connection)
        }
        if subscribe {
            try await sendSubscribe()
        }
    }

    private func sendSubscribe() async throws {
        try await sendFrame(.subscribe(lastSeenEventID: lastSeenEventID))
        subscribed = true
    }

    private func sendFrame(_ frame: ClientFrame) async throws {
        guard let connection else { throw ClientError.disconnected }
        try await connection.send(encoder.encode(frame))
    }

    private func receiveLoop(connection: any NetworkConnection) async {
        while !Task.isCancelled {
            do {
                guard let data = try await connection.receive() else {
                    await handleDisconnect()
                    return
                }
                let frame = try decoder.decode(ServerFrame.self, from: data)
                await handle(frame)
            } catch {
                await handleDisconnect()
                return
            }
        }
    }

    private func handle(_ frame: ServerFrame) async {
        switch frame {
        case .event(let id, let wire):
            lastSeenEventID = id
            _ = await bus.publish(WireCodec.decode(wire))
        case .result(let id, let ok, let error):
            guard let continuation = pendingCommands.removeValue(forKey: id) else { return }
            ok ? continuation.resume() : continuation.resume(throwing: ClientError.commandRejected(error))
        case .versionMismatch(let supported):
            await SilentDiagnostics.shared.record(
                kind: .wireVersionRejected,
                owner: "RemoteEngineClient",
                summary: "server rejected wire version",
                details: supported.map(\.rawValue.description).joined(separator: ",")
            )
            failPending(ClientError.versionMismatch(supported))
        case .subscribed(let latestEventID, let outcome):
            if let latestEventID {
                lastSeenEventID = latestEventID
            }
            if outcome == .checkpointExpired {
                Task { await self.resyncAfterExpiredCheckpoint() }
            }
        case .snapshot(let kind, let payload):
            pendingSnapshots.removeValue(forKey: kind)?.resume(returning: payload)
            _ = await bus.publish(.snapshotReady(kind: kind, payload: payload))
        case .pong, .paired, .pairFailed:
            break
        }
    }

    private func resyncAfterExpiredCheckpoint() async {
        _ = await bus.publish(.engineRestarted)
        let kinds: [SnapshotKind] = [.conversation, .diff, .prefs]
        for kind in kinds {
            do {
                _ = try await requestSnapshot(kind)
            } catch {
                continue
            }
        }
    }

    private func requestSnapshot(_ kind: SnapshotKind) async throws -> Data {
        try await openConnection(subscribe: false)
        return try await withCheckedThrowingContinuation { continuation in
            pendingSnapshots[kind] = continuation
            Task {
                do {
                    try await self.sendFrame(.snapshot(kind: kind))
                } catch {
                    self.pendingSnapshots.removeValue(forKey: kind)?.resume(throwing: error)
                }
            }
        }
    }

    private func handleDisconnect() async {
        await connection?.close()
        connection = nil
        receiverTask?.cancel()
        receiverTask = nil
        subscribed = false
        failPending(ClientError.disconnected)
        scheduleReconnectIfNeeded()
    }

    private func scheduleReconnectIfNeeded() {
        guard let policy = configuration.reconnect else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop(policy: policy)
        }
    }

    private func reconnectLoop(policy: ReconnectPolicy) async {
        var delay = policy.initialDelay
        for _ in 0..<policy.maxAttempts {
            guard !Task.isCancelled else { return }
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled else { return }
            do {
                try await openConnection(subscribe: true)
                return
            } catch {
                delay = min(delay * 2, policy.maxDelay)
            }
        }
    }

    private func cancelPending(_ id: UUID) {
        pendingCommands.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func failPending(_ error: any Error) {
        let continuations = pendingCommands.values
        pendingCommands.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
        let snapshotWaiters = pendingSnapshots.values
        pendingSnapshots.removeAll()
        for continuation in snapshotWaiters {
            continuation.resume(throwing: error)
        }
    }
}
