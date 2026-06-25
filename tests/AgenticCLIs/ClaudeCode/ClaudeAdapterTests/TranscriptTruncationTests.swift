import Foundation
import Testing
import AgentCore
import AgentTestSupport
import ClaudeCode


@Suite("ClaudeAdapter — transcript truncation")
struct TranscriptTruncationTests {

    // MARK: - Helpers

    private func makeAdapter(claudeDir: URL) -> ClaudeAdapter {
        let env = FakeEnvironment(home: claudeDir.deletingLastPathComponent())
        // FakeEnvironment.claudeDirectory = home/.claude, so we need home = parent of claudeDir
        // and claudeDir = home + ".claude"
        return ClaudeAdapter(environment: env, fileSystem: SystemFileSystem())
    }

    private func prepareJSONL(
        lines: [String],
        sessionID: String,
        workspace: URL,
        claudeDir: URL
    ) throws -> URL {
        let dir = ClaudeProjectPaths.projectDirectory(for: workspace,
                                                      claudeDirectory: claudeDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(sessionID).jsonl")
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: - Tests

    @Test("truncates JSONL at the exact user-turn UUID boundary")
    func truncatesAtUserTurnBoundary() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codemixer-trunc-\(UUID().uuidString)", isDirectory: true)
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let turnID = UUID().uuidString
        let sessionID = UUID().uuidString
        let workspace = URL(fileURLWithPath: "/tmp/test-ws")

        let jsonlURL = try prepareJSONL(
            lines: [
                "{\"type\":\"user\",\"uuid\":\"\(turnID)\",\"message\":{\"role\":\"user\"}}",
                "{\"type\":\"assistant\",\"uuid\":\"GHOST-LINE\",\"message\":{\"role\":\"assistant\"}}",
            ],
            sessionID: sessionID,
            workspace: workspace,
            claudeDir: claudeDir
        )

        let adapter = ClaudeAdapter(environment: FakeEnvironment(home: home))

        let ok = await adapter.truncateTranscript(
            afterUserTurnID: turnID,
            sessionID: sessionID,
            workspace: workspace
        )

        #expect(ok == true)
        let remaining = try String(contentsOf: jsonlURL, encoding: .utf8)
        #expect(remaining.contains(turnID))
        #expect(!remaining.contains("GHOST-LINE"))
    }

    @Test("UUID that appears inside message text does not anchor the truncation point")
    func uuidInMessageBodyIsNotAnchor() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codemixer-trunc-\(UUID().uuidString)", isDirectory: true)
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let targetID = UUID().uuidString
        let otherID = UUID().uuidString
        let sessionID = UUID().uuidString
        let workspace = URL(fileURLWithPath: "/tmp/test-ws")

        // otherID appears in the message body of the first record — must NOT match.
        // targetID is the `uuid` field of the second record — MUST match.
        let jsonlURL = try prepareJSONL(
            lines: [
                "{\"type\":\"user\",\"uuid\":\"record-a\",\"message\":{\"role\":\"user\",\"content\":\"\(targetID)\"}}",
                "{\"type\":\"user\",\"uuid\":\"\(targetID)\",\"message\":{\"role\":\"user\"}}",
                "{\"type\":\"assistant\",\"uuid\":\"\(otherID)\",\"message\":{\"role\":\"assistant\"}}",
            ],
            sessionID: sessionID,
            workspace: workspace,
            claudeDir: claudeDir
        )

        let adapter = ClaudeAdapter(environment: FakeEnvironment(home: home))

        let ok = await adapter.truncateTranscript(
            afterUserTurnID: targetID,
            sessionID: sessionID,
            workspace: workspace
        )

        #expect(ok == true)
        let remaining = try String(contentsOf: jsonlURL, encoding: .utf8)
        // Both the body-mention record AND the uuid-match record are kept.
        #expect(remaining.contains("record-a"))
        #expect(remaining.contains(targetID))
        // The assistant record that came after is gone.
        #expect(!remaining.contains(otherID))
    }

    @Test("returns false when target UUID is not present as a uuid field")
    func returnsFalseForAbsentUUID() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codemixer-trunc-\(UUID().uuidString)", isDirectory: true)
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let sessionID = UUID().uuidString
        let workspace = URL(fileURLWithPath: "/tmp/test-ws")

        _ = try prepareJSONL(
            lines: ["{\"type\":\"user\",\"uuid\":\"some-other-uuid\"}"],
            sessionID: sessionID,
            workspace: workspace,
            claudeDir: claudeDir
        )

        let adapter = ClaudeAdapter(environment: FakeEnvironment(home: home))
        let ok = await adapter.truncateTranscript(
            afterUserTurnID: "not-in-file",
            sessionID: sessionID,
            workspace: workspace
        )

        #expect(ok == false)
    }

    @Test("returns false when the JSONL file does not exist")
    func returnsFalseForMissingFile() async {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codemixer-trunc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let adapter = ClaudeAdapter(environment: FakeEnvironment(home: home))
        let ok = await adapter.truncateTranscript(
            afterUserTurnID: UUID().uuidString,
            sessionID: "nonexistent",
            workspace: URL(fileURLWithPath: "/tmp/test-ws")
        )
        #expect(ok == false)
    }
}
