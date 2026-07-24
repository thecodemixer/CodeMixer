import Foundation

/// Pure-Codable mirror of the engine's domain `AgentEvent`.
///
/// `AgentEventWire` deliberately uses portable encodings — strings for URLs,
/// ISO-8601 strings for dates, integer milliseconds for durations — so it
/// compiles against Foundation alone on iOS / iPadOS / Linux clients with no
/// macOS dependencies. A `WireCodec` in `AgentCore` converts between this and
/// the domain `AgentEvent` at the network boundary.
public enum AgentEventWire: Sendable, Codable, Hashable {

    case sessionStarted(sessionID: String, model: String?, cwd: String)

    case userTurn(id: String, text: String)

    case textDelta(messageID: UUID, delta: String)

    case assistantText(id: String, blockID: String, text: String, isFinal: Bool)

    case thinkingChunk(blockID: UUID, delta: String)
    case thinkingComplete(blockID: UUID, durationMS: Int)

    case toolStart(id: String, name: String, input: ToolInput, startedAt: Date)
    case toolProgress(callID: UUID, progress: ToolProgress)
    case toolEnd(id: String, success: Bool, output: ToolOutput, durationMS: Int)

    case permissionRequest(prompt: PermissionPrompt)
    case permissionAlreadyResolved(id: UUID, byDevice: String)

    case statusPhraseChanged(source: StatusPhraseSource, phrase: String)
    case activityStateChanged(ActivitySubstate)
    case noEventGap(turnID: UUID, elapsedMS: Int)

    case authURL(String)
    case bell
    case fileTouched(path: String, kind: FileChangeKind)
    case usage(tokens: Int, costUSD: Double?)

    case engineRestarted
    case stopped(reason: StopReason)
    case error(WireAgentError)

    // MARK: - Out-of-band

    case speakBubbleRequested(eventID: UUID, action: TTSAction)
    case fileReverted(path: String)
    case prefsChanged(rulesCount: Int)
    case appearancePrefChanged(key: AppearancePrefKey, value: AppearancePrefValue)
    case snapshotReady(kind: SnapshotKind, payloadBase64: String)
    case clientAction(ClientAction)

    case agentDashboard(url: String, title: String?)
    case sessionIndexChanged(projectPath: String)
    case sessionAttentionChanged(sessionID: String, title: String, needsAttention: Bool)
    case cachedTranscriptLoaded(sessionID: String)
}

// MARK: - Wire payload types

/// Wire error DTO — domain `AgentError` carries richer typed context that is
/// flattened to string maps here. Tool / permission payloads are shared with
/// the domain (`ToolInput`, `ToolOutput`, `ToolProgress`, `PermissionPrompt`)
/// because those shapes are already portable; see `ToolPayloads.swift`.
public struct WireAgentError: Sendable, Codable, Hashable, Error {
    public let code: String
    public let message: String
    public let context: [String: String]

    public init(code: String, message: String, context: [String: String] = [:]) {
        self.code = code
        self.message = message
        self.context = context
    }
}
