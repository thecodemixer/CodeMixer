import Foundation
import Testing

import AgentCore
import AgentTestSupport
@testable import ClaudeCode

@Suite("Claude session catalog importer")
struct ClaudeSessionCatalogImporterTests {
    @Test("title extracts from user message with text blocks")
    func titleFromTextBlocks() {
        let data = Data(
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"block title"}]}}"#.utf8
        )

        let metadata = ClaudeSessionCatalogImporter.parse(headOf: data)

        #expect(metadata.title == "block title")
    }

    @Test("last activity uses newest transcript timestamp")
    func lastActivityUsesTranscriptTimestamp() {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = Date(timeIntervalSince1970: 1_800_000_000)
        let transcript = """
        {"type":"user","uuid":"u1","timestamp":"\(iso(old))","message":{"role":"user","content":"old"}}
        {"type":"assistant","uuid":"a1","timestamp":"\(iso(recent))","message":{"role":"assistant","content":[{"type":"text","text":"reply"}]}}
        """
        let fallback = Date(timeIntervalSince1970: 1_600_000_000)

        let activity = ClaudeSessionCatalogImporter.lastActivity(
            in: Data(transcript.utf8),
            fallback: fallback
        )

        #expect(activity == recent)
    }

    @Test("summaries order sessions by transcript activity")
    func summariesOrderByTranscriptActivity() throws {
        let fileSystem = InMemoryFileSystem()
        let workspace = TestPaths.underTemporary("claude-summary-workspace")
        let claudeDirectory = TestPaths.underTemporary("claude-summary-home")
        let projects = ClaudeProjectPaths.projectDirectory(
            for: workspace,
            claudeDirectory: claudeDirectory
        )
        try fileSystem.createDirectory(at: projects, withIntermediates: true)
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_800_000_000)
        try fileSystem.writeAtomically(
            userRecord(id: "older", text: "older", timestamp: older),
            to: projects.appendingPathComponent("older.jsonl")
        )
        try fileSystem.writeAtomically(
            userRecord(id: "newer", text: "newer", timestamp: newer),
            to: projects.appendingPathComponent("newer.jsonl")
        )

        let summaries = ClaudeSessionCatalogImporter.summaries(
            workspace: workspace,
            claudeDirectory: claudeDirectory,
            fileSystem: fileSystem
        )

        #expect(summaries.map(\.id) == ["newer", "older"])
    }

    @Test("full import maps every visible transcript block into replay events")
    func fullImportMapsConversationEvents() async throws {
        let fileSystem = InMemoryFileSystem()
        let workspace = TestPaths.underTemporary("claude-import-workspace")
        let claudeDirectory = TestPaths.underTemporary("claude-import-home")
        let projects = ClaudeProjectPaths.projectDirectory(
            for: workspace,
            claudeDirectory: claudeDirectory
        )
        try fileSystem.createDirectory(at: projects, withIntermediates: true)
        let transcript = """
        {"type":"user","uuid":"user-1","sessionId":"session-1","timestamp":"2026-07-28T06:00:00Z","message":{"role":"user","content":"Imported prompt"}}
        {"type":"assistant","uuid":"assistant-1","sessionId":"session-1","timestamp":"2026-07-28T06:00:01Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Imported reasoning"},{"type":"text","text":"Imported reply"}]}}
        {"type":"assistant","uuid":"tool-start","sessionId":"session-1","timestamp":"2026-07-28T06:00:02Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-1","name":"Read","input":{"file_path":"README.md"}}]}}
        {"type":"tool_result","uuid":"tool-end","sessionId":"session-1","timestamp":"2026-07-28T06:00:03Z","tool_use_id":"tool-1","content":[{"type":"text","text":"contents"}],"is_error":false}

        """
        try fileSystem.writeAtomically(
            Data(transcript.utf8),
            to: projects.appendingPathComponent("session-1.jsonl")
        )
        let progress = ImportProgressRecorder()

        let imported = await ClaudeSessionCatalogImporter.importSessions(
            workspace: workspace,
            inputs: .init(
                claudeDirectory: claudeDirectory,
                fileSystem: fileSystem,
                clock: FakeClock(),
                random: FakeRandomSource()
            )
        ) { completed, total in
            await progress.record(completed: completed, total: total)
        }

        let session = try #require(imported.first)
        expectImportedVisibleBlocks(session)
        #expect(await progress.values == [.init(completed: 1, total: 1)])
    }
}

private func expectImportedVisibleBlocks(_ session: ImportedSession) {
    #expect(session.id == "session-1")
    #expect(session.title == "Imported prompt")
    #expect(session.events.contains {
        if case .userTurn(_, let text) = $0 { return text == "Imported prompt" }
        return false
    })
    #expect(session.events.contains {
        if case .assistantText(_, _, let text, true) = $0 {
            return text == "Imported reply"
        }
        return false
    })
    #expect(session.events.contains {
        if case .thinkingChunk(_, let text) = $0 {
            return text == "Imported reasoning"
        }
        return false
    })
    #expect(session.events.contains {
        if case .toolStart(let id, let name, _, _) = $0 {
            return id == "tool-1" && name == "Read"
        }
        return false
    })
    #expect(session.events.contains {
        if case .toolEnd(let id, true, let output, _) = $0 {
            return id == "tool-1" && output.summary.contains("contents")
        }
        return false
    })
}

private actor ImportProgressRecorder {
    struct Value: Equatable {
        let completed: Int
        let total: Int
    }

    private(set) var values: [Value] = []

    func record(completed: Int, total: Int) {
        values.append(.init(completed: completed, total: total))
    }
}

private func userRecord(id: String, text: String, timestamp: Date) -> Data {
    Data(
        """
        {"type":"user","uuid":"\(id)","timestamp":"\(iso(timestamp))","message":{"role":"user","content":"\(text)"}}
        """.utf8
    )
}

private func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}
