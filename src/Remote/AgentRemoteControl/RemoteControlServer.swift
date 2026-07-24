import Foundation
import OSLog
import AgentCore
import AgentProtocol

/// WebSocket front-end to the engine.
///
/// All network IO flows through a `NetworkTransport`; production uses
/// `LiveNetworkTransport` (optionally wrapped in `LoggingNetworkTransport`),
/// tests use `InMemoryNetworkTransport`. Each accepted connection becomes a
/// long-lived `ClientConnection` that subscribes to the engine's
/// `MulticastEventBus` and dispatches inbound commands.
public actor RemoteControlServer {

    public enum BindHost: Sendable {
        case loopback
        case lan
    }

    public struct Configuration: Sendable {
        public var host: BindHost
        public var port: UInt16
        public var requireAuth: Bool
        public var useTLS: Bool
        public var webSocketPath: String

        public init(host: BindHost = .loopback,
                    port: UInt16 = RemoteDefaults.webSocketPort,
                    requireAuth: Bool = false,
                    useTLS: Bool = true,
                    webSocketPath: String = RemoteDefaults.webSocketPath) {
            self.host = host
            self.port = port
            self.requireAuth = requireAuth
            self.useTLS = useTLS
            self.webSocketPath = webSocketPath
        }
    }

    public enum ServerError: Error, Sendable {
        case listenerFailed(String)
        case tlsConfigurationFailed(String)
    }

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "RemoteControl")
    private let engine: any AgentEngineCommandPort
    private let bus: MulticastEventBus
    private let pairing: PairingService
    private let certificates: CertificateManager?
    private let transport: any NetworkTransport
    private let random: any RandomSource
    private var listener: NetworkListenerHandle?
    private var connections: [UUID: ClientConnection] = [:]
    private var lastFingerprint: String?
    private var acceptTask: Task<Void, Never>?
    private var clientCountObserver: (@Sendable (Int) -> Void)?

    public init(engine: any AgentEngineCommandPort,
                bus: MulticastEventBus,
                pairing: PairingService,
                certificates: CertificateManager? = nil,
                transport: any NetworkTransport = LiveNetworkTransport(),
                random: any RandomSource = SystemRandomSource()) {
        self.engine = engine
        self.bus = bus
        self.pairing = pairing
        self.certificates = certificates
        self.transport = transport
        self.random = random
    }

    public func start(configuration: Configuration = Configuration()) async throws {
        let options = try await makeOptions(useTLS: configuration.useTLS)
        let address: NetworkAddress = switch configuration.host {
        case .loopback: .loopback(port: configuration.port)
        case .lan:      .lan(port: configuration.port)
        }

        let handle: NetworkListenerHandle
        do {
            handle = try await transport.listen(on: address, options: options)
        } catch {
            throw ServerError.listenerFailed(error.localizedDescription)
        }
        self.listener = handle

        acceptTask = Task { [weak self] in
            for await connection in handle.connections {
                await self?.accept(connection: connection,
                                   requireAuth: configuration.requireAuth,
                                   expectedPath: configuration.webSocketPath)
            }
        }
        log.notice("remote control server listening port=\(handle.port, privacy: .public) host=\(String(describing: configuration.host), privacy: .public) auth=\(configuration.requireAuth, privacy: .public)")
    }

    public func stop() async {
        acceptTask?.cancel()
        acceptTask = nil
        await listener?.cancel()
        listener = nil
        for c in connections.values {
            // `cancel()` internally unsubscribes from the bus (if subscribed).
            c.cancel()
        }
        connections.removeAll()
        notifyClientCount()
    }

    public var certificateFingerprint: String? { lastFingerprint }

    /// Registers an observer notified whenever the connected-peer count
    /// changes (connect, disconnect, or shutdown). Fires immediately with the
    /// current count. Drives `EngineViewModel.connectedRemoteClients` and
    /// Settings → Remote. See `docs/architecture.md` §4.1.
    public func observeClientCount(_ observer: @escaping @Sendable (Int) -> Void) {
        clientCountObserver = observer
        observer(connections.count)
    }

    private func notifyClientCount() {
        clientCountObserver?(connections.count)
    }

    /// Number of WebSocket peers currently attached (server-side count).
    /// Mode B: includes the loopback Mac GUI. Daemon idle-exit uses this.
    public var connectedClientCount: Int { connections.count }
    public var boundPort: UInt16? { listener?.port }

    public func reconfigure(_ configuration: Configuration) async throws {
        await stop()
        try await start(configuration: configuration)
    }

    // MARK: - Internals

    private func makeOptions(useTLS: Bool) async throws -> NetworkOptions {
        guard useTLS, let manager = certificates else {
            return .plainWebSocket
        }
        let bundle = try await manager.loadOrCreate()
        lastFingerprint = bundle.sha256Fingerprint
        log.notice("TLS cert fingerprint=\(bundle.sha256Fingerprint, privacy: .public)")
        return NetworkOptions(kind: .webSocket, tls: .server(identity: bundle.identity))
    }

    private func accept(connection: any NetworkConnection,
                        requireAuth: Bool,
                        expectedPath: String) async {
        if let path = connection.metadata.path, path != expectedPath {
            log.warning("rejecting connection id=\(connection.id, privacy: .public) path=\(path, privacy: .public)")
            await connection.close()
            return
        }
        let id = random.uuid()
        let client = ClientConnection(id: id,
                                      connection: connection,
                                      engine: engine,
                                      bus: bus,
                                      pairing: pairing,
                                      requireAuth: requireAuth) { [weak self] dead in
            Task { await self?.remove(dead) }
        }
        connections[id] = client
        client.start()
        notifyClientCount()
    }

    private func remove(_ id: UUID) async {
        if let client = connections.removeValue(forKey: id) {
            // Subscription cleanup is handled by `ClientConnection.cancel()`.
            client.cancel()
            notifyClientCount()
        }
    }
}
