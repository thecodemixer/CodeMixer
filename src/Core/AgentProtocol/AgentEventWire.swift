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
    case fileReverted(file: ChangedFile)
    case prefsChanged(rulesCount: Int)
    case appearancePrefChanged(key: AppearancePrefKey, value: AppearancePrefValue)
    case snapshotReady(kind: SnapshotKind, payloadBase64: String)
    case clientAction(ClientAction)

    case agentDashboard(url: String, title: String?)
    case sessionAttentionChanged(sessionID: String, title: String, needsAttention: Bool)
    case sessionHistoryRestored(sessionID: String)
    case sessionPromptReady(sessionID: String)
    case sessionsListed(projectPath: String, sessions: [WireSessionSummary])
    case historyImportProgress(projectPath: String, completed: Int, total: Int)
    case historyImportFinished(projectPath: String, imported: Int, failed: Int)
    case sessionPhaseChanged(sessionID: String, phase: WireSessionPhase)
}

/// Portable mirror of the store-owned session-list projection.
public struct WireSessionSummary: Sendable, Codable, Hashable {
    public let id: String
    public let agentID: String
    public let workspace: String
    public let title: String
    public let lastActivity: Date
    public let messageCount: Int
    public let gitBranch: String?
    public let needsAttention: Bool
    public let isOverview: Bool
    public let overviewURL: String?
    public let archived: Bool
    public let supersededAt: Date?
    public let historyImportState: String

    public init(id: String,
                agentID: String,
                workspace: String,
                title: String,
                lastActivity: Date,
                messageCount: Int,
                gitBranch: String?,
                needsAttention: Bool,
                isOverview: Bool,
                overviewURL: String?,
                archived: Bool,
                supersededAt: Date?,
                historyImportState: String) {
        self.id = id
        self.agentID = agentID
        self.workspace = workspace
        self.title = title
        self.lastActivity = lastActivity
        self.messageCount = messageCount
        self.gitBranch = gitBranch
        self.needsAttention = needsAttention
        self.isOverview = isOverview
        self.overviewURL = overviewURL
        self.archived = archived
        self.supersededAt = supersededAt
        self.historyImportState = historyImportState
    }
}

/// `SessionPhase` flattened to primitives; `group` is `SessionPhase.Group.rawValue`.
public struct WireSessionPhase: Sendable, Codable, Hashable {
    public let id: String
    public let label: String
    public let ordinal: Int
    public let group: String

    public init(id: String, label: String, ordinal: Int, group: String) {
        self.id = id
        self.label = label
        self.ordinal = ordinal
        self.group = group
    }
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
