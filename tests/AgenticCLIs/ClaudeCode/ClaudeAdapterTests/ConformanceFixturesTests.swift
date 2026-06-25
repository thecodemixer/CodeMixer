import Foundation
import Testing
@testable import ClaudeCode
import AgentCore
import AgentProtocol

/// Twin fixture payloads must decode through the production hook decoder.
@Suite("Twin conformance fixtures")
struct ConformanceFixturesTests {

    private let decoder = ClaudeHookDecoder()
    private let fixturesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    @Test("stop-with-last-message fixture yields assistantText and idle")
    func stopWithLastMessage() throws {
        let url = fixturesRoot.appendingPathComponent("hooks/stop-with-last-message.json")
        let data = try Data(contentsOf: url)
        let request = HookRequest(id: UUID(), eventName: "Stop", jsonPayload: data)
        let events = decoder.events(from: request)

        #expect(events.contains { if case .assistantText(_, _, let t, let f) = $0 { return f && t == "Fixture reply." }; return false })
        #expect(events.contains { if case .activityStateChanged(.idle) = $0 { return true }; return false })
    }

    @Test("twin stop emitter matches fixture shape")
    func twinStopMatchesFixture() throws {
        let workspace = URL(fileURLWithPath: "/tmp/test")
        let claudeDir = URL(fileURLWithPath: "/tmp/.claude")
        let context = ClaudeCodeTwinHookEmitter.Context(sessionID: "sess-fixture-1",
                                                        workspace: workspace,
                                                        claudeDirectory: claudeDir)
        let payload = ClaudeCodeTwinHookEmitter.stop(sessionID: "sess-fixture-1",
                                                     lastAssistantMessage: "Fixture reply.",
                                                     context: context)
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        #expect(object?["hook_event_name"] as? String == "Stop")
        #expect(object?["last_assistant_message"] as? String == "Fixture reply.")
        #expect((object?["transcript_path"] as? String)?.contains("sess-fixture-1.jsonl") == true)
    }
}
