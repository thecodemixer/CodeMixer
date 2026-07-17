import Foundation
import Testing
import ACPCLIs
import AgentCore
import AgentProtocol

/// Opt-in live harness for Cursor ACP (`cursor-agent acp`).
///
/// ```bash
/// CODEMIXER_LIVE_CURSOR_ACP=1 \
///   swift test --no-parallel --filter LiveCursorACPIntegrationTests
/// ```
///
/// Optional: `CURSOR_BIN` / `CODEMIXER_LIVE_CURSOR_BIN`, `CODEMIXER_LIVE_WORKSPACE`.
@Suite("AgentEngine + CursorACPAdapter live harness", .serialized)
struct LiveCursorACPIntegrationTests {

    @Test("transport and identity stay on cursor ACP")
    func identity() {
        let adapter = CursorACPAdapter()
        #expect(adapter.id == .cursorCLI)
        #expect(adapter.transportDescriptor == .agentClientProtocol)
        #expect(adapter.buildLaunchArgv(context: LaunchContext(
            workspace: URL(fileURLWithPath: "/tmp"),
            permissionMode: .default
        )) == ["cursor-agent", "acp"])
    }

    @Test("live Cursor ACP turn and mode switches")
    func liveModesAndTurn() async throws {
        guard LiveCursorACPHarness.isEnabled() else { return }
        if let reason = LiveCursorACPHarness.prerequisiteFailure() {
            Issue.record("\(reason)")
            return
        }
        guard let configuration = LiveCursorACPHarness.defaultConfiguration() else {
            Issue.record("missing Cursor binary")
            return
        }

        let harness = LiveCursorACPHarness()
        let result: LiveCursorACPHarness.Result
        do {
            result = try await harness.run(configuration)
        } catch {
            Issue.record("\(error)")
            return
        }

        #expect(result.cliVersion?.isEmpty == false)
        #expect(result.modeProbeResults[.agent] == .supported)
        #expect(result.modeProbeResults[.plan] == .supported)
        #expect(result.modeProbeResults[.ask] == .supported)
        #expect(result.modeProbeResults[.debug] == .diagnosticOnly)
        #expect(result.finalAssistantText?
            .localizedCaseInsensitiveContains(configuration.expectedFinalSubstring) == true)
    }
}
