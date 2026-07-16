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
            return .toolStart(id: id, name: name, input: encode(input), startedAt: startedAt)
        case .toolProgress(let callID, let progress):
            return .toolProgress(callID: callID, progress: encode(progress))
        case .toolEnd(let id, let success, let output, let ms):
            return .toolEnd(id: id, success: success, output: encode(output), durationMS: ms)
        case .permissionRequest(let prompt):
            return .permissionRequest(prompt: encode(prompt))
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
        case .speakBubbleRequested(let id):
            return .speakBubbleRequested(id: id)
        case .fileReverted(let path):
            return .fileReverted(path: path)
        case .prefsChanged(let n):
            return .prefsChanged(rulesCount: n)
        case .appearancePrefChanged(let key, let value):
            return .appearancePrefChanged(key: key, value: value)
        case .snapshotReady(let kind, let payload):
            return .snapshotReady(kind: kind, payloadBase64: payload.base64EncodedString())
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
            return .toolStart(id: id, name: name, input: decode(input), startedAt: at)
        case .toolProgress(let callID, let progress):
            return .toolProgress(callID: callID, progress: decode(progress))
        case .toolEnd(let id, let success, let output, let ms):
            return .toolEnd(id: id, success: success, output: decode(output), durationMS: ms)
        case .permissionRequest(let prompt):
            return .permissionRequest(prompt: decode(prompt))
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
        case .speakBubbleRequested(let id):
            return .speakBubbleRequested(id: id)
        case .fileReverted(let path):
            return .fileReverted(path: path)
        case .prefsChanged(let n):
            return .prefsChanged(rulesCount: n)
        case .appearancePrefChanged(let key, let value):
            return .appearancePrefChanged(key: key, value: value)
        case .snapshotReady(let kind, let b64):
            return .snapshotReady(kind: kind, payload: Data(base64Encoded: b64) ?? Data())
        }
    }

    // MARK: - Sub-encodings

    private static func encode(_ input: ToolInput) -> WireToolInput {
        WireToolInput(summary: input.summary, jsonPayload: input.jsonPayload)
    }
    private static func decode(_ wire: WireToolInput) -> ToolInput {
        ToolInput(summary: wire.summary, jsonPayload: wire.jsonPayload)
    }

    private static func encode(_ output: ToolOutput) -> WireToolOutput {
        WireToolOutput(summary: output.summary, jsonPayload: output.jsonPayload, errorMessage: output.errorMessage)
    }
    private static func decode(_ wire: WireToolOutput) -> ToolOutput {
        ToolOutput(summary: wire.summary, jsonPayload: wire.jsonPayload, errorMessage: wire.errorMessage)
    }

    private static func encode(_ p: ToolProgress) -> WireToolProgress {
        switch p {
        case .bashLine(let line): return .bashLine(line)
        case .fileBytes(let w, let t): return .fileBytes(written: w, total: t)
        case .generic(let m): return .generic(message: m)
        }
    }
    private static func decode(_ p: WireToolProgress) -> ToolProgress {
        switch p {
        case .bashLine(let line): return .bashLine(line)
        case .fileBytes(let w, let t): return .fileBytes(written: w, total: t)
        case .generic(let m): return .generic(message: m)
        }
    }

    private static func encode(_ p: PermissionPrompt) -> WirePermissionPrompt {
        WirePermissionPrompt(id: p.id,
                             toolName: p.toolName,
                             summary: p.summary,
                             argumentsSummary: p.argumentsSummary,
                             requestedAt: p.requestedAt)
    }
    private static func decode(_ p: WirePermissionPrompt) -> PermissionPrompt {
        PermissionPrompt(id: p.id,
                         toolName: p.toolName,
                         summary: p.summary,
                         argumentsSummary: p.argumentsSummary,
                         requestedAt: p.requestedAt)
    }

    private static func ms(of duration: Duration) -> Int {
        let comp = duration.components
        return Int(comp.seconds * 1_000) + Int(comp.attoseconds / 1_000_000_000_000_000)
    }

}
