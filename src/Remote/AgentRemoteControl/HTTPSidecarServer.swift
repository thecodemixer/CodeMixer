import Foundation
import OSLog
import AgentCore
import AgentProtocol

/// Tiny HTTP sidecar that companions the WebSocket server.
///
/// Three endpoints:
///   * `GET  /v1/health`                → JSON `{ ok, version, uptime, clients }`
///   * `GET  /v1/diagnostics/silent`    → JSON array of silent-recovery records
///   * `POST /v1/attachments`           → raw body persisted under the engine's tmp dir;
///     responds with `{ id, path }` so the client can reference it from a
///     subsequent command.
///
/// We deliberately keep this minimal — heavier endpoints (cert rotation,
/// pairing dashboard, etc.) live as WebSocket commands, not HTTP routes, so
/// auth + auditing stay in one place.
public actor HTTPSidecarServer {

    public struct Configuration: Sendable {
        public var host: RemoteControlServer.BindHost
        public var port: UInt16

        public init(host: RemoteControlServer.BindHost = .loopback,
                    port: UInt16 = RemoteDefaults.sidecarPort) {
            self.host = host
            self.port = port
        }
    }

    public enum SidecarError: Error, Sendable {
        case listenerFailed(String)
    }

    /// Attachments older than this are deleted by the background janitor.
    public static let attachmentTTL: TimeInterval = 24 * 60 * 60

    /// The janitor sweeps every hour so stale files don't accumulate beyond
    /// two TTL windows even under continuous use.
    public static let janitorInterval: TimeInterval = 60 * 60

    /// `start()`/`stop()` always set or clear the listener and its two
    /// background tasks together; this replaces the three previously
    /// independently-optional fields so "listener without an accept task" is
    /// unrepresentable.
    private enum RunningState {
        case stopped
        case running(listener: NetworkListenerHandle,
                     acceptTask: Task<Void, Never>,
                     janitorTask: Task<Void, Never>)
    }

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "HTTP")
    private let attachmentsDirectory: URL
    private let serverInfo: ServerInfo
    private let transport: any NetworkTransport
    private let clock: any AgentClock
    private let random: any RandomSource
    private let fileSystem: any FileSystem
    private var state: RunningState = .stopped
    private let startedAt: Date

    public init(attachmentsDirectory: URL,
                serverInfo: ServerInfo,
                transport: any NetworkTransport = LiveNetworkTransport(),
                clock: any AgentClock = SystemClock(),
                random: any RandomSource = SystemRandomSource(),
                fileSystem: any FileSystem = SystemFileSystem()) {
        self.attachmentsDirectory = attachmentsDirectory
        self.serverInfo = serverInfo
        self.transport = transport
        self.clock = clock
        self.random = random
        self.fileSystem = fileSystem
        self.startedAt = clock.now()
    }

    public func start(configuration: Configuration = Configuration()) async throws {
        try fileSystem.createDirectory(at: attachmentsDirectory,
                                       withIntermediates: true)
        let address: NetworkAddress = switch configuration.host {
        case .loopback: .loopback(port: configuration.port)
        case .lan:      .lan(port: configuration.port)
        }
        let handle: NetworkListenerHandle
        do {
            handle = try await transport.listen(on: address, options: .plainTCP)
        } catch {
            throw SidecarError.listenerFailed(error.localizedDescription)
        }
        let acceptTask: Task<Void, Never> = Task { [weak self] in
            for await connection in handle.connections {
                let conn = connection
                Task { [weak self] in await self?.handle(conn) }
            }
        }
        let janitorTask: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Int(HTTPSidecarServer.janitorInterval)))
                await self.purgeExpiredAttachments()
            }
        }
        state = .running(listener: handle, acceptTask: acceptTask, janitorTask: janitorTask)
        log.notice("HTTP sidecar listening on port \(handle.port, privacy: .public)")
    }

    public func stop() async {
        guard case .running(let listener, let acceptTask, let janitorTask) = state else { return }
        acceptTask.cancel()
        janitorTask.cancel()
        await listener.cancel()
        state = .stopped
    }

    // MARK: - Janitor

    private func purgeExpiredAttachments() {
        let cutoff = clock.now().addingTimeInterval(-HTTPSidecarServer.attachmentTTL)
        guard let entries = try? fileSystem.contentsOfDirectory(at: attachmentsDirectory) else { return }
        var removed = 0
        for url in entries {
            let mtime = (try? fileSystem.modificationDate(at: url)) ?? .distantFuture
            if mtime < cutoff {
                try? fileSystem.remove(at: url)
                removed += 1
            }
        }
        if removed > 0 {
            log.notice("janitor removed \(removed, privacy: .public) expired attachment(s)")
        }
    }

    func runJanitorOnceForTesting() {
        purgeExpiredAttachments()
    }

    public var boundPort: UInt16? {
        if case .running(let listener, _, _) = state { return listener.port }
        return nil
    }

    // MARK: - Connection handling

    private func handle(_ connection: any NetworkConnection) async {
        let request = await readRequest(from: connection)
        let response = await respond(to: request)
        try? await connection.send(response.serialize())
        await connection.close()
    }

    private func readRequest(from connection: any NetworkConnection) async -> HTTPRequest {
        var buffer = Data()
        while true {
            let chunk = (try? await connection.receive()) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            buffer.append(chunk)
            if let request = HTTPRequest.parse(buffer) {
                return request
            }
        }
        return HTTPRequest(method: "GET", path: "/", headers: [:], body: Data())
    }

    // MARK: - Routes

    private func respond(to request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", RemoteDefaults.healthPath):
            return healthResponse()
        case ("GET", RemoteDefaults.silentDiagnosticsPath):
            return await silentDiagnosticsResponse()
        case ("POST", RemoteDefaults.attachmentsPath):
            return attachmentResponse(body: request.body, headers: request.headers)
        default:
            return HTTPResponse(status: 404,
                                headers: ["Content-Type": "application/json"],
                                body: Data(#"{"error":"not_found"}"#.utf8))
        }
    }

    private func healthResponse() -> HTTPResponse {
        let info = HealthPayload(ok: true,
                                 version: serverInfo.versionLabel,
                                 uptimeSeconds: Int(clock.now().timeIntervalSince(startedAt)),
                                 clients: serverInfo.clientCount)
        return HTTPResponse(status: 200,
                            headers: ["Content-Type": "application/json"],
                            body: encodeJSON(info))
    }

    private func silentDiagnosticsResponse() async -> HTTPResponse {
        let records = await SilentDiagnostics.shared.snapshot()
        return HTTPResponse(status: 200,
                            headers: ["Content-Type": "application/json"],
                            body: encodeJSON(records))
    }

    private func attachmentResponse(body: Data, headers: [String: String]) -> HTTPResponse {
        let id = random.uuid().uuidString
        let suffix = header("X-Codemixer-Filename", in: headers).map { sanitized($0) } ?? "blob"
        let url = attachmentsDirectory.appendingPathComponent("\(id)-\(suffix)")
        do {
            try fileSystem.writeAtomically(body, to: url)
        } catch {
            return HTTPResponse(status: 500,
                                headers: ["Content-Type": "application/json"],
                                body: encodeJSON(ErrorPayload(error: "write_failed",
                                                              detail: error.localizedDescription)))
        }
        let payload = AttachmentPayload(id: id,
                                        path: url.path,
                                        bytes: body.count)
        return HTTPResponse(status: 200,
                            headers: ["Content-Type": "application/json"],
                            body: encodeJSON(payload))
    }

    nonisolated func sanitized(_ filename: String) -> String {
        filename
            .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "._-")).inverted)
            .joined()
            .prefix(64)
            .description
    }

    private nonisolated func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { key, _ in
            key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }

    private nonisolated func encodeJSON<Payload: Encodable>(_ payload: Payload) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload)) ?? Data()
    }
}

private struct HealthPayload: Encodable {
    let ok: Bool
    let version: String
    let uptimeSeconds: Int
    let clients: Int
}

private struct AttachmentPayload: Encodable {
    let id: String
    let path: String
    let bytes: Int
}

private struct ErrorPayload: Encodable {
    let error: String
    let detail: String
}

public struct ServerInfo: Sendable {
    public let versionLabel: String
    public let clientCount: Int
    public init(versionLabel: String, clientCount: Int) {
        self.versionLabel = versionLabel
        self.clientCount = clientCount
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headPart = data.subdata(in: 0..<sep.lowerBound)
        guard let headString = String(data: headPart, encoding: .utf8) else { return nil }
        let lines = headString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let pieces = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard pieces.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLengthHeader = headers.first { key, _ in
            key.caseInsensitiveCompare("Content-Length") == .orderedSame
        }?.value
        let contentLength = Int(contentLengthHeader ?? "0") ?? 0
        let bodyStart = sep.upperBound
        let availableBody = data.count - bodyStart
        guard availableBody >= contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        return HTTPRequest(method: pieces[0], path: pieces[1], headers: headers, body: body)
    }
}

private struct HTTPResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    func serialize() -> Data {
        var headerLines = [String]()
        headerLines.append("HTTP/1.1 \(status) \(reasonPhrase)")
        var combined = headers
        combined["Content-Length"] = "\(body.count)"
        for (k, v) in combined.sorted(by: { $0.key < $1.key }) {
            headerLines.append("\(k): \(v)")
        }
        let head = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    private var reasonPhrase: String {
        switch status {
        case 200: return "OK"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default:  return "OK"
        }
    }
}
