import Foundation
import Testing
@testable import ACPCLIs
import AgentCore

@Suite("AgentEngine + CustomACPAdapter live harness")
struct LiveCustomACPIntegrationTests {

    @Test("live custom ACP session responds to a prompt")
    func livePrompt() async throws {
        guard LiveCustomACPHarness.isEnabled() else {
            return
        }
        guard let exe = LiveCustomACPHarness.executablePath() else {
            Issue.record("Set CODEMIXER_LIVE_ACP_BIN to a real ACP binary")
            return
        }

        let ws = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("live-custom-acp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }

        let result = try await LiveCustomACPHarness().run(.init(
            workspace: ws,
            executablePath: exe
        ))
        #expect(result.sessionID != nil)
        #expect(result.finalAssistantText?.contains("codemixer-custom-acp-pong") == true)
    }
}
