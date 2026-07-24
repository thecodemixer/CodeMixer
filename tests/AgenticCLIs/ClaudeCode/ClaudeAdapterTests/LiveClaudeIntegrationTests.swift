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

    @Test("resumed interactive session still emits assistantText on the next prompt")
    func resumedInteractivePTYTurn() async throws {
        guard LiveClaudeHarness.isEnabled() else { return }
        if let reason = LiveClaudeHarness.prerequisiteFailure() {
            Issue.record("\(reason)")
            return
        }

        let harness = LiveClaudeHarness()
        let configuration = LiveClaudeHarness.defaultConfiguration()

        let result: LiveClaudeHarness.ResumeLoadResult
        do {
            result = try await harness.runFreshProcessResume(configuration)
        } catch {
            Issue.record("\(error)")
            return
        }

        #expect(result.sawPriorUserTurn)
        #expect(result.sawPriorAssistantFinal)
        #expect(result.followUpAssistantText?.localizedCaseInsensitiveContains("resume-pong") == true)
        #expect(result.priorSessionID.isEmpty == false)
        print(
            "live Claude --resume: session=\(result.priorSessionID) historyUser=\(result.sawPriorUserTurn) historyAssistant=\(result.sawPriorAssistantFinal)"
        )
    }

    /// Opt-in TUI dump for resume hangs. Skipped unless
    /// `CODEMIXER_LIVE_CLAUDE=1` **and** `CODEMIXER_LIVE_CLAUDE_RESUME_DIAG=1`.
    ///
    /// ```bash
    /// CODEMIXER_LIVE_CLAUDE=1 CODEMIXER_LIVE_CLAUDE_RESUME_DIAG=1 \
    ///   swift test --no-parallel --filter resumeHangDiagnostic
    /// ```
    @Test("resume hang diagnostic dumps terminal rows")
    func resumeHangDiagnostic() async throws {
        guard LiveClaudeHarness.isResumeDiagnosticEnabled() else { return }
        if let reason = LiveClaudeHarness.prerequisiteFailure() {
            Issue.record("\(reason)")
            return
        }

        let harness = LiveClaudeHarness()
        let configuration = LiveClaudeHarness.defaultConfiguration()
        do {
            try await harness.runResumeHangDiagnostic(configuration)
        } catch {
            Issue.record("\(error)")
        }
    }
}
