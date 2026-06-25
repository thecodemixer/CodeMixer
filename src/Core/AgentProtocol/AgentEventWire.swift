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

    case toolStart(id: String, name: String, input: WireToolInput, startedAt: Date)
    case toolProgress(callID: UUID, progress: WireToolProgress)
    case toolEnd(id: String, success: Bool, output: WireToolOutput, durationMS: Int)

    case permissionRequest(prompt: WirePermissionPrompt)
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

    case speakBubbleRequested(id: String)
    case fileReverted(path: String)
    case prefsChanged(rulesCount: Int)
    case appearancePrefChanged(key: AppearancePrefKey, value: AppearancePrefValue)
    case snapshotReady(kind: SnapshotKind, payloadBase64: String)
}

// MARK: - Wire payload types

/// Wire-side description of a tool's input — small JSON-shaped sum type so we
/// don't need to transport raw schemas.
public struct WireToolInput: Sendable, Codable, Hashable {
    public var summary: String
    public var jsonPayload: String?

    public init(summary: String, jsonPayload: String? = nil) {
        self.summary = summary
        self.jsonPayload = jsonPayload
    }
}

public struct WireToolOutput: Sendable, Codable, Hashable {
    public var summary: String
    public var jsonPayload: String?
    public var errorMessage: String?

    public init(summary: String, jsonPayload: String? = nil, errorMessage: String? = nil) {
        self.summary = summary
        self.jsonPayload = jsonPayload
        self.errorMessage = errorMessage
    }
}

/// Typed live progress for a tool call.
public enum WireToolProgress: Sendable, Codable, Hashable {
    case bashLine(String)
    case fileBytes(written: Int, total: Int?)
    case generic(message: String)
}

public struct WirePermissionPrompt: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let toolName: String
    public let summary: String
    public let argumentsSummary: String
    public let requestedAt: Date

    public init(id: UUID, toolName: String, summary: String, argumentsSummary: String, requestedAt: Date) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.argumentsSummary = argumentsSummary
        self.requestedAt = requestedAt
    }
}

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
