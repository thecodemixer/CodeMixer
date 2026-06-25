import Foundation
import AgentCore
import AgentProtocol

/// Remote `AgentEngineCommandPort` backed by Codemixer's WebSocket protocol.
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

    public struct Configuration: Sendable {
        public var address: NetworkAddress
        public var options: NetworkOptions

        public init(address: NetworkAddress = .loopback(port: RemoteDefaults.webSocketPort),
                    options: NetworkOptions = .webSocket()) {
            self.address = address
            self.options = options
        }
    }

    public nonisolated let bus: MulticastEventBus

    private let transport: any NetworkTransport
    private let configuration: Configuration
    private let random: any RandomSource
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var connection: (any NetworkConnection)?
    private var receiverTask: Task<Void, Never>?
    private var pendingCommands: [UUID: CheckedContinuation<Void, any Error>] = [:]

    public init(configuration: Configuration = Configuration(),
                transport: any NetworkTransport = LiveNetworkTransport(),
                bus: MulticastEventBus = MulticastEventBus(),
                random: any RandomSource = SystemRandomSource()) {
        self.configuration = configuration
        self.transport = transport
        self.bus = bus
        self.random = random

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func connect() async throws {
        guard connection == nil else { return }
        let connection = try await transport.connect(to: configuration.address,
                                                     options: configuration.options)
        self.connection = connection
        receiverTask = Task { [weak self, connection] in
            await self?.receiveLoop(connection: connection)
        }
        try await sendFrame(.subscribe(streams: [.events]))
    }

    public func disconnect() async {
        receiverTask?.cancel()
        receiverTask = nil
        await connection?.close()
        connection = nil
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
        case .event(let wire):
            _ = await bus.publish(WireCodec.decode(wire))
        case .result(let id, let ok, let error):
            guard let continuation = pendingCommands.removeValue(forKey: id) else { return }
            ok ? continuation.resume() : continuation.resume(throwing: ClientError.commandRejected(error))
        case .versionMismatch(let supported):
            failPending(ClientError.versionMismatch(supported))
        case .subscribed, .pong, .snapshot, .paired, .pairFailed:
            break
        }
    }

    private func handleDisconnect() async {
        await connection?.close()
        connection = nil
        receiverTask?.cancel()
        receiverTask = nil
        failPending(ClientError.disconnected)
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
    }
}
