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

    /// Collapses what used to be four independently-mutated fields
    /// (`connection?`, `subscribed`, `receiverTask?`, `reconnectTask?`) into
    /// one value, so "subscribed with no connection" or "reconnecting while
    /// still holding a connection" are unrepresentable rather than merely
    /// avoided by convention.
    private enum ConnectionState {
        case idle
        case connecting
        case connected(connection: any NetworkConnection, receiverTask: Task<Void, Never>, subscribed: Bool)
        case reconnecting(attempt: Int, task: Task<Void, Never>)
    }

    private let transport: any NetworkTransport
    private let configuration: Configuration
    private let random: any RandomSource
    private let clock: any AgentClock
    private let encoder = makeWireFrameEncoder()
    private let decoder = makeWireFrameDecoder()
    private var state: ConnectionState = .idle
    private var pendingCommands: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var pendingSnapshots: [SnapshotKind: CheckedContinuation<Data, any Error>] = [:]
    private var lastSeenEventID: UUID?

    private var currentConnection: (any NetworkConnection)? {
        if case .connected(let connection, _, _) = state { return connection }
        return nil
    }

    private var isSubscribed: Bool {
        if case .connected(_, _, let subscribed) = state { return subscribed }
        return false
    }

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
    }

    public func connect() async throws {
        try await openConnection(subscribe: true)
    }

    public func disconnect() async {
        switch state {
        case .idle, .connecting:
            break
        case .connected(let connection, let receiverTask, _):
            receiverTask.cancel()
            await connection.close()
        case .reconnecting(_, let task):
            task.cancel()
        }
        state = .idle
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
        guard currentConnection == nil else {
            if subscribe, !isSubscribed {
                try await sendSubscribe()
            }
            return
        }
        state = .connecting
        let connection = try await transport.connect(to: configuration.address,
                                                     options: configuration.options)
        let receiverTask: Task<Void, Never> = Task { [weak self, connection] in
            await self?.receiveLoop(connection: connection)
        }
        state = .connected(connection: connection, receiverTask: receiverTask, subscribed: false)
        if subscribe {
            try await sendSubscribe()
        }
    }

    private func sendSubscribe() async throws {
        try await sendFrame(.subscribe(lastSeenEventID: lastSeenEventID))
        if case .connected(let connection, let receiverTask, _) = state {
            state = .connected(connection: connection, receiverTask: receiverTask, subscribed: true)
        }
    }

    private func sendFrame(_ frame: ClientFrame) async throws {
        guard let currentConnection else { throw ClientError.disconnected }
        try await currentConnection.send(encoder.encode(frame))
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
        case .commandSucceeded(let id):
            guard let continuation = pendingCommands.removeValue(forKey: id) else { return }
            continuation.resume()
        case .commandFailed(let id, let error):
            guard let continuation = pendingCommands.removeValue(forKey: id) else { return }
            continuation.resume(throwing: ClientError.commandRejected(error))
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
        if case .connected(let connection, let receiverTask, _) = state {
            await connection.close()
            receiverTask.cancel()
        }
        state = .idle
        failPending(ClientError.disconnected)
        scheduleReconnectIfNeeded()
    }

    private func scheduleReconnectIfNeeded() {
        guard let policy = configuration.reconnect else { return }
        if case .reconnecting(_, let existing) = state { existing.cancel() }
        let task: Task<Void, Never> = Task { [weak self] in
            await self?.reconnectLoop(policy: policy)
        }
        state = .reconnecting(attempt: 0, task: task)
    }

    private func reconnectLoop(policy: ReconnectPolicy) async {
        var delay = policy.initialDelay
        for attempt in 1...policy.maxAttempts {
            guard !Task.isCancelled else { return }
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled else { return }
            recordReconnectAttempt(attempt)
            do {
                try await openConnection(subscribe: true)
                return
            } catch {
                delay = min(delay * 2, policy.maxDelay)
            }
        }
    }

    private func recordReconnectAttempt(_ attempt: Int) {
        guard case .reconnecting(_, let task) = state else { return }
        state = .reconnecting(attempt: attempt, task: task)
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
