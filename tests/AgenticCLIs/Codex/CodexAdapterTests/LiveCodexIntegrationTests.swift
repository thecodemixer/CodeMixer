import Foundation
import Testing
import AgentCore
import AgentProtocol
import Codex

/// Live-account integration for the production App Server stdio path.
///
/// Skipped unless `CODEMIXER_LIVE_CODEX=1` and a real `codex` binary is available.
/// Reuses `LiveCodexHarness` so future suites can drive the same flow.
@Suite("AgentEngine + CodexAdapter live harness", .serialized)
struct LiveCodexIntegrationTests {

    @Test("launch argv stays on the App Server stdio path")
    func launchArgvStaysAppServerStdio() {
        #expect(LiveCodexHarness.launchArgvIsAppServerStdio())
        #expect(LiveCodexHarness.transportIsStdioJSONRPC())
    }

    @Test("App Server stdio turn emits assistantText through CodexAdapter")
    func appServerStdioTurn() async throws {
        guard LiveCodexHarness.isEnabled() else { return }
        if let reason = LiveCodexHarness.prerequisiteFailure() {
            Issue.record("\(reason)")
            return
        }

        let harness = LiveCodexHarness()
        let configuration = LiveCodexHarness.defaultConfiguration()

        let result: LiveCodexHarness.TurnResult
        do {
            result = try await harness.runTurn(configuration)
        } catch {
            Issue.record("\(error)")
            return
        }

        #expect(result.events.contains {
            if case .sessionStarted(let id, _, _) = $0 { return !id.isEmpty }
            return false
        })
        #expect(result.events.contains {
            if case .userTurn(_, let text) = $0 { return text == configuration.prompt }
            return false
        })
        #expect(result.threadID?.isEmpty == false)
        #expect(result.finalAssistantText?
            .localizedCaseInsensitiveContains(configuration.expectedFinalSubstring) == true)
        #expect(result.finalAssistantTextCount == 1)
    }
}
