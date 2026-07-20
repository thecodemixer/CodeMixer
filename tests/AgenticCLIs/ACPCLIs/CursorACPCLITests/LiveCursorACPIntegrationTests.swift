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
        #expect(result.firstTurn.finalAssistantText?
            .localizedCaseInsensitiveContains(configuration.expectedFinalSubstring) == true)
        #expect(result.secondTurn.finalAssistantText?
            .localizedCaseInsensitiveContains(configuration.expectedSecondFinalSubstring) == true)
        print(
            "live Cursor ACP timings: first=\(result.firstTurn.duration) second=\(result.secondTurn.duration) session=\(result.sessionID ?? "nil")"
        )
        // Warm same-session turn must beat the first prompt (no cold handshake).
        #expect(result.secondTurn.duration < result.firstTurn.duration)
        // Distinct bubble ids so SwiftUI keeps both finals visible.
        if let firstID = result.firstTurn.finalAssistantID,
           let secondID = result.secondTurn.finalAssistantID {
            #expect(firstID != secondID)
        } else {
            Issue.record("missing final assistant ids (first=\(String(describing: result.firstTurn.finalAssistantID)), second=\(String(describing: result.secondTurn.finalAssistantID)))")
        }
        // Both finals remain in the live event stream after turn 2.
        let finals = result.events.compactMap { event -> String? in
            if case .assistantText(_, _, let text, true) = event { return text }
            return nil
        }
        #expect(finals.contains { $0.localizedCaseInsensitiveContains(configuration.expectedFinalSubstring) })
        #expect(finals.contains { $0.localizedCaseInsensitiveContains(configuration.expectedSecondFinalSubstring) })
    }

    @Test("live Cursor ACP thoughts and replies stream incrementally")
    func liveStreamingCadence() async throws {
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
        let result: LiveCursorACPHarness.StreamingCadenceResult
        do {
            result = try await harness.runStreamingCadence(configuration)
        } catch {
            Issue.record("\(error)")
            return
        }

        #expect(result.finalAssistantText?
            .localizedCaseInsensitiveContains("codemixer-stream-ok") == true)
        // Cursor ACP delivers many non-final chunks (incremental decode works).
        #expect(result.nonFinalAssistantCount >= 2)
        #expect(result.distinctNonFinalLengths.count >= 2)
        if result.distinctNonFinalLengths.count >= 2 {
            #expect(result.distinctNonFinalLengths.last! > result.distinctNonFinalLengths.first!)
        }
        // Note: Cursor currently emits those chunks in a millisecond-scale burst
        // after generation (wire probe ~2ms), so assistantStreamSpan is often tiny.
        // Codemixer still surfaces each chunk; UI morphs them in place.
        print(
            "live Cursor streaming: thoughts=\(result.thinkingChunkCount) thoughtSpan=\(String(describing: result.thinkingStreamSpan)) nonFinalAssistant=\(result.nonFinalAssistantCount) lengths=\(result.distinctNonFinalLengths) assistantSpan=\(String(describing: result.assistantStreamSpan)) session=\(result.sessionID ?? "nil")"
        )
    }

    @Test("live Cursor ACP fresh-process session/load replays history")
    func liveFreshProcessHistoryLoad() async throws {
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
        let result: LiveCursorACPHarness.ResumeLoadResult
        do {
            result = try await harness.runFreshProcessLoad(configuration)
        } catch {
            Issue.record("\(error)")
            return
        }

        #expect(result.cliVersion?.isEmpty == false)
        #expect(result.sawPriorUserTurn)
        #expect(result.sawPriorAssistantFinal)
        #expect(result.followUpAssistantText?
            .localizedCaseInsensitiveContains(configuration.expectedSecondFinalSubstring) == true)
        print(
            "live Cursor ACP session/load: session=\(result.priorSessionID) historyUser=\(result.sawPriorUserTurn) historyAssistant=\(result.sawPriorAssistantFinal)"
        )
    }
}
