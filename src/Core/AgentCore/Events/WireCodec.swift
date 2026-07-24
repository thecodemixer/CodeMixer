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
        case .fileReverted(let path):
            return .fileReverted(path: path)
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
        case .sessionIndexChanged(let projectPath):
            return .sessionIndexChanged(projectPath: projectPath.path)
        case .sessionAttentionChanged(let sessionID, let title, let needsAttention):
            return .sessionAttentionChanged(
                sessionID: sessionID,
                title: title,
                needsAttention: needsAttention
            )
        case .cachedTranscriptLoaded(let sessionID):
            return .cachedTranscriptLoaded(sessionID: sessionID)
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
        case .fileReverted(let path):
            return .fileReverted(path: path)
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
        case .sessionIndexChanged(let path):
            return .sessionIndexChanged(projectPath: URL(fileURLWithPath: path))
        case .sessionAttentionChanged(let sessionID, let title, let needsAttention):
            return .sessionAttentionChanged(
                sessionID: sessionID,
                title: title,
                needsAttention: needsAttention
            )
        case .cachedTranscriptLoaded(let sessionID):
            return .cachedTranscriptLoaded(sessionID: sessionID)
        }
    }

    // MARK: - Sub-encodings

    private static func ms(of duration: Duration) -> Int {
        let comp = duration.components
        return Int(comp.seconds * 1_000) + Int(comp.attoseconds / 1_000_000_000_000_000)
    }

}
