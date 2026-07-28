import Foundation
import AgentProtocol

/// The complete, typed output alphabet of the engine.
///
/// All UI surfaces (Mac UI, future iOS client, voice TTS, automation scripts)
/// derive their state from this stream. A parallel `AgentEventWire` (in
/// `AgentProtocol`) is its Codable mirror; `WireCodec` converts at the
/// network boundary.
public enum AgentEvent: Sendable {

    case sessionStarted(sessionID: String, model: String?, cwd: URL)

    case userTurn(id: String, text: String)

    case textDelta(messageID: UUID, delta: String)

    case assistantText(id: String, blockID: String, text: String, isFinal: Bool)

    case thinkingChunk(blockID: UUID, delta: String)
    case thinkingComplete(blockID: UUID, duration: Duration)

    case toolStart(id: String, name: String, input: ToolInput, startedAt: Date)
    case toolProgress(callID: UUID, progress: ToolProgress)
    case toolEnd(id: String, success: Bool, output: ToolOutput, durationMS: Int)

    case permissionRequest(prompt: PermissionPrompt)
    case permissionAlreadyResolved(id: UUID, byDevice: String)

    case statusPhraseChanged(source: StatusPhraseSource, phrase: String)
    case activityStateChanged(ActivitySubstate)
    case noEventGap(turnID: UUID, elapsed: Duration)

    case authURL(URL)
    case bell
    case fileTouched(URL, kind: FileChangeKind)
    case usage(tokens: Int, costUSD: Double?)

    case engineRestarted
    case stopped(reason: AgentProtocol.StopReason)
    case error(AgentError)

    // MARK: - Out-of-band (snapshots, prefs, TTS, revert)

    case speakBubbleRequested(eventID: UUID, action: TTSAction)
    case fileReverted(file: ChangedFile)
    case prefsChanged(rulesCount: Int)
    case appearancePrefChanged(key: AppearancePrefKey, value: AppearancePrefValue)
    case snapshotReady(kind: SnapshotKind, payload: Data)

    /// Codemixer-owned history marker for an agent-affecting client intent.
    /// Live session + export only — not restored from agent JSONL on resume.
    case clientAction(ClientAction)

    /// Agent-advertised embedded dashboard (loopback URL only in the UI).
    /// `title` is agent-owned display copy, used for the sidebar overview row.
    case agentDashboard(url: URL, title: String?)

    /// Background session needs user attention (e.g. parked permission).
    case sessionAttentionChanged(sessionID: String, title: String, needsAttention: Bool)

    /// Project-local transcript restoration completed. This never implies that
    /// the adapter is ready to accept a prompt.
    case sessionHistoryRestored(sessionID: String)

    /// The live adapter has bound the session and can accept user input.
    case sessionPromptReady(sessionID: String)

    /// Store-owned session list for one project.
    case sessionsListed(projectPath: URL, sessions: [SessionSummary])

    /// Progress from the one-shot add-existing-project history import.
    case historyImportProgress(projectPath: URL, completed: Int, total: Int)

    /// Terminal result from the one-shot project history import.
    case historyImportFinished(projectPath: URL, imported: Int, failed: Int)

    /// A file-level pipeline phase advanced for this session. Agent-agnostic:
    /// a Custom ACP adapter maps its vendor status onto `SessionPhase`. Always
    /// file-scoped — there is no run/overall variant (see `AGENTS.md` phase
    /// bridge notes). Ordered and durable: emitted live and re-emitted, in
    /// order from the project-local transcript, so
    /// the rail can phase-group reopened history, not just the live tail.
    case sessionPhaseChanged(sessionID: String, phase: SessionPhase)
}
