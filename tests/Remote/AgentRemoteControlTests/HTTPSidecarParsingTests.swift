import Foundation
import Testing
@testable import AgentRemoteControl
@testable import AgentCore

@Suite("HTTPSidecarServer — parser and janitor policy", .serialized)
struct HTTPSidecarParsingTests {

    @Test("HTTPRequest.parse waits until the declared Content-Length body is present")
    func parseWaitsForFullBody() throws {
        let partial = Data("""
        POST /v1/attachments HTTP/1.1\r
        Host: localhost\r
        Content-Length: 5\r
        \r
        he
        """.utf8)
        #expect(HTTPRequest.parse(partial) == nil)

        let complete = Data("""
        POST /v1/attachments HTTP/1.1\r
        Host: localhost\r
        Content-Length: 5\r
        \r
        helloextra
        """.utf8)
        let request = try #require(HTTPRequest.parse(complete))
        #expect(request.method == "POST")
        #expect(request.path == "/v1/attachments")
        #expect(String(data: request.body, encoding: .utf8) == "hello")
    }

    @Test("HTTPRequest.parse returns nil without header terminator")
    func parseRequiresHeaderTerminator() {
        let raw = Data("GET /v1/health HTTP/1.1\r\nHost: localhost".utf8)
        #expect(HTTPRequest.parse(raw) == nil)
    }

    @Test("HTTPRequest.parse handles case-insensitive Content-Length with whitespace")
    func parseContentLengthCaseInsensitively() throws {
        let raw = Data("""
        POST /v1/attachments HTTP/1.1\r
        content-length:   4  \r
        X-Codemixer-Filename: spec.md\r
        \r
        body
        """.utf8)

        let request = try #require(HTTPRequest.parse(raw))
        #expect(request.headers["content-length"] == "4")
        #expect(String(data: request.body, encoding: .utf8) == "body")
    }

    @Test("Filename sanitization strips traversal separators and caps length")
    func filenameSanitizationStripsTraversal() {
        let server = HTTPSidecarServer(
            attachmentsDirectory: URL(fileURLWithPath: "/tmp/attachments", isDirectory: true),
            serverInfo: ServerInfo(versionLabel: "test", clientCount: 0),
            transport: InMemoryNetwork().transport
        )
        let sanitized = server.sanitized("../../etc/passwd with spaces and symbols !@#$%^&*()" + String(repeating: "x", count: 80))
        #expect(!sanitized.contains("/"))
        #expect(!sanitized.contains(" "))
        #expect(sanitized.count <= 64)
    }

    @Test("Janitor removes expired attachments and keeps fresh files")
    func janitorRemovesOnlyExpiredAttachments() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codemixer-sidecar-janitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let expired = tmpDir.appendingPathComponent("expired.bin")
        let fresh = tmpDir.appendingPathComponent("fresh.bin")
        try Data("expired".utf8).write(to: expired)
        try Data("fresh".utf8).write(to: fresh)

        let oldDate = Date().addingTimeInterval(-HTTPSidecarServer.attachmentTTL - 60)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: expired.path)

        let server = HTTPSidecarServer(
            attachmentsDirectory: tmpDir,
            serverInfo: ServerInfo(versionLabel: "test", clientCount: 0),
            transport: InMemoryNetwork().transport
        )

        await server.runJanitorOnceForTesting()

        #expect(!FileManager.default.fileExists(atPath: expired.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }
}
