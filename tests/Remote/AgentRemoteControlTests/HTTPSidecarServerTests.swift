import Foundation
import Testing
@testable import AgentRemoteControl
@testable import AgentCore
import AgentTestSupport

@Suite("HTTPSidecarServer — health and attachment endpoints", .serialized)
struct HTTPSidecarServerTests {

    @Test("GET /v1/health returns JSON with ok=true")
    func healthEndpoint() async throws {
        let (server, transport, tmpDir) = try await makeServer()
        defer {
            Task { await server.stop() }
            try? FileManager.default.removeItem(at: tmpDir)
        }
        let port = await server.boundPort
        #expect(port != nil)

        let response = try await get(transport: transport, port: port!, path: "/v1/health")
        #expect(response.status == 200)
        let json = try #require(try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(json["ok"] as? Bool == true)
        #expect(json["version"] as? String == "1.0-test")
    }

    @Test("GET /v1/health response includes uptime and clients fields")
    func healthContainsUptimeAndClients() async throws {
        let (server, transport, tmpDir) = try await makeServer(clientCount: 2)
        defer {
            Task { await server.stop() }
            try? FileManager.default.removeItem(at: tmpDir)
        }
        let port = await server.boundPort!
        let response = try await get(transport: transport, port: port, path: "/v1/health")
        let json = try #require(try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(json["clients"] as? Int == 2)
        #expect(json["uptimeSeconds"] != nil)
    }

    @Test("POST /v1/attachments stores body and returns id + path")
    func attachmentUpload() async throws {
        let (server, transport, tmpDir) = try await makeServer()
        defer {
            Task { await server.stop() }
            try? FileManager.default.removeItem(at: tmpDir)
        }
        let port = await server.boundPort!
        let body = Data("hello attachment".utf8)
        let response = try await post(transport: transport, port: port,
                                      path: "/v1/attachments",
                                      body: body,
                                      headers: ["X-Codemixer-Filename": "spec.md"])
        #expect(response.status == 200)
        let json = try #require(try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let id = try #require(json["id"] as? String)
        let path = try #require(json["path"] as? String)
        #expect(!id.isEmpty)
        #expect(path.hasSuffix("spec.md") || path.contains("spec"))
        // Verify the file was actually written
        #expect(FileManager.default.fileExists(atPath: path))
        let written = try? Data(contentsOf: URL(fileURLWithPath: path))
        #expect(written == body)
    }

    @Test("GET /v1/unknown returns 404")
    func unknownRoute() async throws {
        let (server, transport, tmpDir) = try await makeServer()
        defer {
            Task { await server.stop() }
            try? FileManager.default.removeItem(at: tmpDir)
        }
        let port = await server.boundPort!
        let response = try await get(transport: transport, port: port, path: "/v1/unknown")
        #expect(response.status == 404)
    }

    @Test("stop() shuts down the listener; boundPort becomes nil")
    func stopClosesListener() async throws {
        let (server, _, tmpDir) = try await makeServer()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let portBefore = await server.boundPort
        #expect(portBefore != nil)

        await server.stop()
        let portAfter = await server.boundPort
        #expect(portAfter == nil)
    }

    // MARK: - Helpers

    private func makeServer(clientCount: Int = 0) async throws
        -> (HTTPSidecarServer, any NetworkTransport, URL)
    {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-sidecar-\(UUID().uuidString)", isDirectory: true)
        let net = InMemoryNetwork()
        let info = ServerInfo(versionLabel: "1.0-test", clientCount: clientCount)
        let server = HTTPSidecarServer(attachmentsDirectory: tmpDir,
                                       serverInfo: info,
                                       transport: net.transport)
        try await server.start(configuration: .init(host: .loopback, port: 0))
        return (server, net.transport, tmpDir)
    }

    private struct SimpleResponse {
        let status: Int
        let body: Data
    }

    private func get(transport: any NetworkTransport,
                     port: UInt16,
                     path: String) async throws -> SimpleResponse {
        let conn = try await transport.connect(to: .loopback(port: port), options: .plainTCP)
        defer { Task { await conn.close() } }
        let req = "GET \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        try await conn.send(Data(req.utf8))
        let data = try await conn.receive() ?? Data()
        return parseHTTPResponse(data)
    }

    private func post(transport: any NetworkTransport,
                      port: UInt16,
                      path: String,
                      body: Data,
                      headers: [String: String] = [:]) async throws -> SimpleResponse {
        let conn = try await transport.connect(to: .loopback(port: port), options: .plainTCP)
        defer { Task { await conn.close() } }
        var extraHeaders = ""
        for (k, v) in headers { extraHeaders += "\(k): \(v)\r\n" }
        let reqHead = "POST \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.count)\r\n\(extraHeaders)Connection: close\r\n\r\n"
        var req = Data(reqHead.utf8)
        req.append(body)
        try await conn.send(req)
        let data = try await conn.receive() ?? Data()
        return parseHTTPResponse(data)
    }

    private func parseHTTPResponse(_ data: Data) -> SimpleResponse {
        guard let raw = String(data: data, encoding: .utf8),
              let headerEnd = raw.range(of: "\r\n\r\n") else {
            return SimpleResponse(status: 0, body: data)
        }
        let headerPart = String(raw[..<headerEnd.lowerBound])
        let bodyPart = String(raw[headerEnd.upperBound...])
        let statusLine = headerPart.components(separatedBy: "\r\n").first ?? ""
        let statusCode = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
        return SimpleResponse(status: statusCode, body: Data(bodyPart.utf8))
    }
}
