import Foundation
import AgentProtocol

/// Translates between domain `AgentEvent` (uses URLs / Durations / Dates) and
/// the portable `AgentEventWire` (uses strings / ints / ISO-8601).
///
/// Lives in `AgentCore` because the conversion knows about both sides. The
/// remote control server is the only caller — UI consumes `AgentEvent`
/// directly.
public enum WireCodec {

    // MARK: - Domain → wire

    public static func encode(_ event: AgentEvent) -> AgentEventWire {
        switch event {
        case .sessionStarted(let id, let model, let cwd):
            return .sessionStarted(sessionID: id, model: model, cwd: cwd.path)
        case .userTurn(let id, let text):
            return .userTurn(id: id, text: text)
        case .textDelta(let mid, let delta):
            return .textDelta(messageID: mid, delta: delta)
        case .assistantText(let id, let block, let text, let isFinal):
            return .assistantText(id: id, blockID: block, text: text, isFinal: isFinal)
        case .thinkingChunk(let block, let delta):
            return .thinkingChunk(blockID: block, delta: delta)
        case .thinkingComplete(let block, let duration):
            return .thinkingComplete(blockID: block, durationMS: ms(of: duration))
        case .toolStart(let id, let name, let input, let startedAt):
            return .toolStart(id: id, name: name, input: input, startedAt: startedAt)
        case .toolProgress(let callID, let progress):
            return .toolProgress(callID: callID, progress: progress)
        case .toolEnd(let id, let success, let output, let ms):
            return .toolEnd(id: id, success: success, output: output, durationMS: ms)
        case .permissionRequest(let prompt):
            return .permissionRequest(prompt: prompt)
        case .permissionAlreadyResolved(let id, let by):
            return .permissionAlreadyResolved(id: id, byDevice: by)
        case .statusPhraseChanged(let source, let phrase):
            return .statusPhraseChanged(source: source, phrase: phrase)
        case .activityStateChanged(let substate):
            return .activityStateChanged(substate)
        case .noEventGap(let turn, let elapsed):
            return .noEventGap(turnID: turn, elapsedMS: ms(of: elapsed))
        case .authURL(let url):
            return .authURL(url.absoluteString)
        case .bell:
            return .bell
        case .fileTouched(let url, let kind):
            return .fileTouched(path: url.path, kind: kind)
        case .usage(let tokens, let cost):
            return .usage(tokens: tokens, costUSD: cost)
        case .engineRestarted:
            return .engineRestarted
        case .stopped(let reason):
            return .stopped(reason: reason)
        case .error(let err):
            return .error(WireAgentErrorCoding.encode(err))
        case .speakBubbleRequested(let eventID, let action):
            return .speakBubbleRequested(eventID: eventID, action: action)
        case .fileReverted(let file):
            return .fileReverted(file: file)
        case .prefsChanged(let n):
            return .prefsChanged(rulesCount: n)
        case .appearancePrefChanged(let key, let value):
            return .appearancePrefChanged(key: key, value: value)
        case .snapshotReady(let kind, let payload):
            return .snapshotReady(kind: kind, payloadBase64: payload.base64EncodedString())
        case .clientAction(let action):
            return .clientAction(action)
        case .agentDashboard(let url, let title):
            return .agentDashboard(url: url.absoluteString, title: title)
        case .sessionAttentionChanged(let sessionID, let title, let needsAttention):
            return .sessionAttentionChanged(
                sessionID: sessionID,
                title: title,
                needsAttention: needsAttention
            )
        case .sessionHistoryRestored(let sessionID):
            return .sessionHistoryRestored(sessionID: sessionID)
        case .sessionPromptReady(let sessionID):
            return .sessionPromptReady(sessionID: sessionID)
        case .sessionsListed(let projectPath, let sessions):
            return .sessionsListed(projectPath: projectPath.path,
                                   sessions: sessions.map(encode))
        case .historyImportProgress(let projectPath, let completed, let total):
            return .historyImportProgress(projectPath: projectPath.path,
                                          completed: completed,
                                          total: total)
        case .historyImportFinished(let projectPath, let imported, let failed):
            return .historyImportFinished(projectPath: projectPath.path,
                                          imported: imported,
                                          failed: failed)
        case .sessionPhaseChanged(let sessionID, let phase):
            return .sessionPhaseChanged(
                sessionID: sessionID,
                phase: WireSessionPhase(id: phase.id, label: phase.label, ordinal: phase.ordinal, group: phase.group.rawValue)
            )
        case .a2uiBatch(let batch):
            return .a2uiBatch(batch)
        }
    }

    // MARK: - Wire → domain

    public static func decode(_ wire: AgentEventWire) -> AgentEvent {
        switch wire {
        case .sessionStarted(let id, let model, let cwd):
            return .sessionStarted(sessionID: id, model: model, cwd: URL(fileURLWithPath: cwd))
        case .userTurn(let id, let text):
            return .userTurn(id: id, text: text)
        case .textDelta(let mid, let delta):
            return .textDelta(messageID: mid, delta: delta)
        case .assistantText(let id, let block, let text, let isFinal):
            return .assistantText(id: id, blockID: block, text: text, isFinal: isFinal)
        case .thinkingChunk(let block, let delta):
            return .thinkingChunk(blockID: block, delta: delta)
        case .thinkingComplete(let block, let ms):
            return .thinkingComplete(blockID: block, duration: .milliseconds(ms))
        case .toolStart(let id, let name, let input, let at):
            return .toolStart(id: id, name: name, input: input, startedAt: at)
        case .toolProgress(let callID, let progress):
            return .toolProgress(callID: callID, progress: progress)
        case .toolEnd(let id, let success, let output, let ms):
            return .toolEnd(id: id, success: success, output: output, durationMS: ms)
        case .permissionRequest(let prompt):
            return .permissionRequest(prompt: prompt)
        case .permissionAlreadyResolved(let id, let by):
            return .permissionAlreadyResolved(id: id, byDevice: by)
        case .statusPhraseChanged(let source, let phrase):
            return .statusPhraseChanged(source: source, phrase: phrase)
        case .activityStateChanged(let substate):
            return .activityStateChanged(substate)
        case .noEventGap(let turn, let ms):
            return .noEventGap(turnID: turn, elapsed: .milliseconds(ms))
        case .authURL(let s):
            guard let url = URL(string: s) else {
                return .error(.internalInvariant(detail: "invalid authURL"))
            }
            return .authURL(url)
        case .bell:
            return .bell
        case .fileTouched(let path, let kind):
            return .fileTouched(URL(fileURLWithPath: path), kind: kind)
        case .usage(let tokens, let cost):
            return .usage(tokens: tokens, costUSD: cost)
        case .engineRestarted:
            return .engineRestarted
        case .stopped(let reason):
            return .stopped(reason: reason)
        case .error(let wireErr):
            return .error(WireAgentErrorCoding.decode(wireErr))
        case .speakBubbleRequested(let eventID, let action):
            return .speakBubbleRequested(eventID: eventID, action: action)
        case .fileReverted(let file):
            return .fileReverted(file: file)
        case .prefsChanged(let n):
            return .prefsChanged(rulesCount: n)
        case .appearancePrefChanged(let key, let value):
            return .appearancePrefChanged(key: key, value: value)
        case .snapshotReady(let kind, let b64):
            return .snapshotReady(kind: kind, payload: Data(base64Encoded: b64) ?? Data())
        case .clientAction(let action):
            return .clientAction(action)
        case .agentDashboard(let s, let title):
            guard let url = URL(string: s) else {
                return .error(.internalInvariant(detail: "invalid agentDashboard URL"))
            }
            return .agentDashboard(url: url, title: title)
        case .sessionAttentionChanged(let sessionID, let title, let needsAttention):
            return .sessionAttentionChanged(
                sessionID: sessionID,
                title: title,
                needsAttention: needsAttention
            )
        case .sessionHistoryRestored(let sessionID):
            return .sessionHistoryRestored(sessionID: sessionID)
        case .sessionPromptReady(let sessionID):
            return .sessionPromptReady(sessionID: sessionID)
        case .sessionsListed(let projectPath, let sessions):
            return .sessionsListed(
                projectPath: URL(fileURLWithPath: projectPath),
                sessions: sessions.map(decode)
            )
        case .historyImportProgress(let projectPath, let completed, let total):
            return .historyImportProgress(projectPath: URL(fileURLWithPath: projectPath),
                                          completed: completed,
                                          total: total)
        case .historyImportFinished(let projectPath, let imported, let failed):
            return .historyImportFinished(projectPath: URL(fileURLWithPath: projectPath),
                                          imported: imported,
                                          failed: failed)
        case .sessionPhaseChanged(let sessionID, let wirePhase):
            let group = SessionPhase.Group(rawValue: wirePhase.group) ?? .plan
            return .sessionPhaseChanged(
                sessionID: sessionID,
                phase: SessionPhase(id: wirePhase.id, label: wirePhase.label, ordinal: wirePhase.ordinal, group: group)
            )
        case .a2uiBatch(let batch):
            return .a2uiBatch(batch)
        }
    }

    // MARK: - Sub-encodings

    private static func ms(of duration: Duration) -> Int {
        let comp = duration.components
        return Int(comp.seconds * 1_000) + Int(comp.attoseconds / 1_000_000_000_000_000)
    }

    private static func encode(_ summary: SessionSummary) -> WireSessionSummary {
        WireSessionSummary(id: summary.id,
                           agentID: summary.agentID.rawValue,
                           workspace: summary.workspace.path,
                           title: summary.title,
                           lastActivity: summary.lastActivity,
                           messageCount: summary.messageCount,
                           gitBranch: summary.gitBranch,
                           needsAttention: summary.needsAttention,
                           isOverview: summary.isOverview,
                           overviewURL: summary.overviewURL?.absoluteString,
                           archived: summary.archived,
                           supersededAt: summary.supersededAt,
                           historyImportState: summary.historyImportState.rawValue)
    }

    private static func decode(_ summary: WireSessionSummary) -> SessionSummary {
        SessionSummary(id: summary.id,
                       agentID: AgentID(rawValue: summary.agentID) ?? .other,
                       workspace: URL(fileURLWithPath: summary.workspace),
                       title: summary.title,
                       lastActivity: summary.lastActivity,
                       messageCount: summary.messageCount,
                       gitBranch: summary.gitBranch,
                       needsAttention: summary.needsAttention,
                       isOverview: summary.isOverview,
                       overviewURL: summary.overviewURL.flatMap(URL.init(string:)),
                       archived: summary.archived,
                       supersededAt: summary.supersededAt,
                       historyImportState: HistoryImportState(
                           rawValue: summary.historyImportState
                       ) ?? .notNeeded)
    }

}
