import Foundation
import Testing
import AgentClientProtocol
import AgentCore
import AgentProtocol

/// Live integration for a configured ACP agent server over stdio JSON-RPC.
///
/// Skipped unless `CODEMIXER_LIVE_ACP=1` and `CODEMIXER_LIVE_ACP_BIN` points at
/// a real ACP agent-server executable.
@Suite("AgentEngine + ACPAdapter live harness", .serialized)
struct LiveACPIntegrationTests {

    @Test("transport descriptor stays on agentClientProtocol")
    func transportDescriptor() {
        #expect(LiveACPHarness.transportIsAgentClientProtocol())
    }

    @Test("ACP stdio turn emits assistantText through ACPAdapter")
    func acpStdioTurn() async throws {
        guard LiveACPHarness.isEnabled() else { return }
        if let reason = LiveACPHarness.prerequisiteFailure() {
            Issue.record("\(reason)")
            return
        }
        guard let configuration = LiveACPHarness.defaultConfiguration() else {
            Issue.record("missing CODEMIXER_LIVE_ACP_BIN")
            return
        }

        let harness = LiveACPHarness()
        let result: LiveACPHarness.TurnResult
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
        #expect(result.sessionID?.isEmpty == false)
        #expect(result.finalAssistantText?
            .localizedCaseInsensitiveContains(configuration.expectedFinalSubstring) == true)
        #expect(result.finalAssistantTextCount == 1)
    }
}
