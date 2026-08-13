/// Selects durable engine events and translates them into transcript-domain
/// mutations. It is pure so transient events never cross into persistence.
import AgentProtocol
import Foundation

enum TranscriptEventMapper {
    /// `changedFileRoot` is the agent cwd — the directory touched-file URLs are
    /// relative to — which is the project root unless the project overrides it.
    static func mutations(for event: AgentEvent,
                          recordedAt: Date,
                          changedFileRoot: URL) -> [TranscriptMutation] {
        if let mutation = conversationMutation(for: event, recordedAt: recordedAt) {
            return [mutation]
        }
        if let mutation = workMutation(
            for: event,
            recordedAt: recordedAt,
            changedFileRoot: changedFileRoot
        ) {
            return [mutation]
        }
        if case .sessionPhaseChanged(let sessionID, let phase) = event {
            return [.changePhase(sessionID: sessionID,
                                 phase: phase,
                                 recordedAt: recordedAt)]
        }
        if case .a2uiBatch(let batch) = event {
            return [.applyA2UIBatch(batch, recordedAt: recordedAt)]
        }
        return []
    }

    private static func conversationMutation(for event: AgentEvent,
                                             recordedAt: Date) -> TranscriptMutation? {
        switch event {
        case .userTurn(let id, let text):
            return .appendUser(id: id, text: text, recordedAt: recordedAt)
        case .assistantText(let id, let blockID, let text, let isFinal) where isFinal:
            return .finalizeAssistant(id: id,
                                      blockID: blockID,
                                      text: text,
                                      recordedAt: recordedAt)
        case .thinkingChunk(let blockID, let delta):
            return .appendThinking(blockID: blockID,
                                   delta: delta,
                                   recordedAt: recordedAt)
        case .thinkingComplete(let blockID, let duration):
            return .completeThinking(blockID: blockID,
                                     durationMS: duration.milliseconds,
                                     recordedAt: recordedAt)
        case .clientAction(let action):
            return .appendClientAction(action, recordedAt: recordedAt)
        default:
            return nil
        }
    }

    private static func workMutation(for event: AgentEvent,
                                     recordedAt: Date,
                                     changedFileRoot: URL) -> TranscriptMutation? {
        switch event {
        case .toolStart(let id, let name, let input, let startedAt):
            return .startTool(id: id, name: name, input: input, startedAt: startedAt)
        case .toolProgress(let callID, let progress):
            return .updateTool(id: callID, progress: progress, recordedAt: recordedAt)
        case .toolEnd(let id, let success, let output, let durationMS):
            return .finishTool(id: id,
                               success: success,
                               output: output,
                               durationMS: durationMS,
                               recordedAt: recordedAt)
        case .fileTouched(let url, let kind):
            return .touchFile(file: .init(url: url, workspace: changedFileRoot),
                              kind: kind,
                              recordedAt: recordedAt)
        case .fileReverted(let file):
            return .removeChangedFile(file, recordedAt: recordedAt)
        default:
            return nil
        }
    }
}

private extension Duration {
    var milliseconds: Int {
        let parts = components
        let seconds = parts.seconds * 1_000
        let milliseconds = parts.attoseconds / 1_000_000_000_000_000
        return Int(seconds + milliseconds)
    }
}
