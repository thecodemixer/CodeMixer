import Foundation
import OSLog

/// Per-session Unix-domain-socket server that receives hook callbacks from a
/// spawned CLI agent.
///
/// The wire shape is generic: each connection sends a single JSON object
/// followed by EOF; the adapter decides the schema. The server hands the
/// request to its handler and writes the handler's response bytes back on the
/// same connection before closing it.
///
/// Socket path lives at `<env.cachesDirectory>/sockets/<uuid>.sock` and is
/// removed on shutdown. Network I/O goes through `NetworkTransport`; this file
/// does not import `Network.framework`.
public actor HookServer {

    public enum HookServerError: Error, Sendable {
        case listenerFailed(String)
        case socketPathInUse(String)
    }

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "HookServer")
    private let environment: any AgentEnvironment
    private let fileSystem: any FileSystem
    private let random: any RandomSource
    private let transport: any NetworkTransport
    private let socketURL: URL
    private var listener: NetworkListenerHandle?
    private var acceptTask: Task<Void, Never>?
    private let requestContinuation: AsyncStream<HookRequest>.Continuation
    private var pendingResponses: [UUID: any NetworkConnection] = [:]

    /// Outbound stream of hook requests; adapter consumes this and replies via
    /// the bound `HookSocketHandle.respond` closure.
    public nonisolated let requests: AsyncStream<HookRequest>

    public init(environment: any AgentEnvironment,
                fileSystem: any FileSystem,
                random: any RandomSource = SystemRandomSource(),
                transport: any NetworkTransport = LiveNetworkTransport()) throws {
        self.environment = environment
        self.fileSystem = fileSystem
        self.random = random
        self.transport = transport

        let socketsDir = environment.cachesDirectory.appendingPathComponent("sockets",
                                                                            isDirectory: true)
        try? fileSystem.createDirectory(at: socketsDir, withIntermediates: true)
        self.socketURL = socketsDir.appendingPathComponent("\(random.uuid().uuidString).sock")

        var continuation: AsyncStream<HookRequest>.Continuation!
        self.requests = AsyncStream(bufferingPolicy: .bufferingNewest(StreamBufferDefaults.hookRequests)) { c in continuation = c }
        self.requestContinuation = continuation
    }

    /// Path callers pass to the adapter for hook configuration.
    public nonisolated var socketPath: String { socketURL.path }

    /// Begin listening. Returns once the listener is bound.
    public func start() async throws {
        if fileSystem.fileExists(at: socketURL) {
            try fileSystem.remove(at: socketURL)
        }

        let handle: NetworkListenerHandle
        do {
            handle = try await transport.listen(on: .unixSocket(path: socketURL.path),
                                                options: .plainTCP)
        } catch {
            throw HookServerError.listenerFailed(String(describing: error))
        }
        self.listener = handle

        acceptTask = Task { [weak self] in
            for await connection in handle.connections {
                await self?.acceptConnection(connection)
            }
        }
        log.notice("hook server listening at \(self.socketURL.path, privacy: .public)")
    }

    /// Send `data` as the response body for the pending request `id`, then close.
    public func respond(to id: UUID, with data: Data) {
        guard let connection = pendingResponses.removeValue(forKey: id) else { return }
        Task {
            try? await connection.send(data)
            await connection.close()
        }
    }

    /// Stop the listener and remove the socket file.
    public func stop() {
        acceptTask?.cancel()
        acceptTask = nil
        if let listener {
            Task { await listener.cancel() }
        }
        listener = nil
        for conn in pendingResponses.values {
            Task { await conn.close() }
        }
        pendingResponses.removeAll()
        requestContinuation.finish()
        try? fileSystem.remove(at: socketURL)
    }

    /// Bind the adapter's request consumer with a closure that calls back
    /// into this server.
    public func makeHandle() -> HookSocketHandle {
        let weakSelf = self
        return HookSocketHandle(incoming: requests,
                                respond: { id, data in
            await weakSelf.respond(to: id, with: data)
        })
    }

    // MARK: - Connection processing

    private func acceptConnection(_ connection: any NetworkConnection) async {
        let id = random.uuid()
        // The hook protocol sends the JSON request body and half-closes its
        // write side; we read frames until the peer signals EOF (nil).
        var payload = Data()
        while let chunk = try? await connection.receive() {
            payload.append(chunk)
        }
        guard !payload.isEmpty else {
            await connection.close()
            return
        }
        let eventName = extractEventName(from: payload) ?? "Unknown"
        pendingResponses[id] = connection
        requestContinuation.yield(HookRequest(id: id, eventName: eventName, jsonPayload: payload))
    }

    private nonisolated func extractEventName(from payload: Data) -> String? {
        struct EventEnvelope: Decodable { let hook_event_name: String? }
        return (try? JSONDecoder().decode(EventEnvelope.self, from: payload))?.hook_event_name
    }
}
