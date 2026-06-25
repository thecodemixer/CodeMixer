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

    case speakBubbleRequested(id: String)
    case fileReverted(path: String)
    case prefsChanged(rulesCount: Int)
    case appearancePrefChanged(key: AppearancePrefKey, value: AppearancePrefValue)
    case snapshotReady(kind: SnapshotKind, payload: Data)
}
