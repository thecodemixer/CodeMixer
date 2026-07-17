import Foundation
import Testing
import AgentCore
import AgentProtocol
import ClaudeCode

/// Live-account integration for the production interactive PTY path.
///
/// Skipped unless `CODEMIXER_LIVE_CLAUDE=1` and a real `claude` binary is available.
/// Reuses `LiveClaudeHarness` so future suites can drive the same flow.
@Suite("AgentEngine + ClaudeAdapter live harness", .serialized)
struct LiveClaudeIntegrationTests {

    @Test("launch argv stays on the interactive billing path")
    func launchArgvStaysInteractive() {
        #expect(LiveClaudeHarness.launchArgvIsInteractive())
        #expect(LiveClaudeHarness.launchArgvIsInteractive(permissionMode: .acceptEdits,
                                                          resumeSessionID: "sess-live"))
    }

    @Test("interactive PTY turn emits assistantText through hooks + transcript")
    func interactivePTYTurn() async throws {
        guard LiveClaudeHarness.isEnabled() else { return }
        if let reason = LiveClaudeHarness.prerequisiteFailure() {
            Issue.record("\(reason)")
            return
        }

        let harness = LiveClaudeHarness()
        let configuration = LiveClaudeHarness.defaultConfiguration()

        let result: LiveClaudeHarness.TurnResult
        do {
            result = try await harness.runTurn(configuration)
        } catch {
            Issue.record("\(error)")
            return
        }

        #expect(result.events.contains { if case .sessionStarted = $0 { return true }; return false })
        #expect(result.events.contains {
            if case .userTurn(_, let text) = $0 { return text == configuration.prompt }
            return false
        })
        #expect(result.finalAssistantText?.localizedCaseInsensitiveContains(configuration.expectedFinalSubstring) == true)
        #expect(result.finalAssistantTextCount == 1)

        if let markers = result.billingMarkers {
            #expect(markers.isSubscriptionCLIPath)
            #expect(markers.entrypoint == "cli")
            #expect(markers.promptSource != "sdk")
        } else if let transcriptURL = result.transcriptURL {
            Issue.record("transcript exists but billing markers were not parsed: \(transcriptURL.path)")
        }
    }
}
