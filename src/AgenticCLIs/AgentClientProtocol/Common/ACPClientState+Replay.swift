import Foundation

import AgentCore
import AgentProtocol

/// `session/load` history-chunk coalescing: buffers chunks until a role or
/// `messageId` boundary, then flushes one finalized event per turn.
extension ACPClientState {
    /// Append a history chunk during `session/load`. Emits finalized turns when
    /// the role or `messageId` boundary changes.
    func appendHistoryChunk(role: String,
                            messageID: String?,
                            delta: String,
                            random: any RandomSource) -> [AgentEvent] {
        withLock {
            guard !delta.isEmpty else { return [] }
            let nextRole: ReplayRole
            switch role {
            case "user": nextRole = .user
            case "thinking": nextRole = .thinking
            default: nextRole = .agent
            }
            var events: [AgentEvent] = []
            let boundary = replayRole != nil && (
                replayRole != nextRole
                    || (messageID != nil && replayMessageID != nil && messageID != replayMessageID)
            )
            if boundary {
                events.append(contentsOf: flushReplayLocked())
            }
            if replayRole == nil {
                replayRole = nextRole
                replayMessageID = messageID
                replayEventID = random.uuid()
                replayText = ""
            } else if messageID != nil {
                replayMessageID = messageID
            }
            replayText += delta
            return events
        }
    }

    func flushHistoryReplay() -> [AgentEvent] {
        withLock { flushReplayLocked() }
    }

    func flushReplayLocked() -> [AgentEvent] {
        defer { clearReplayLocked() }
        guard let role = replayRole,
              let id = replayEventID,
              !replayText.isEmpty else { return [] }
        let text = replayText
        switch role {
        case .user:
            return [.userTurn(id: id.uuidString, text: text)]
        case .agent:
            return [.assistantText(
                id: id.uuidString,
                blockID: replayMessageID ?? "history-agent",
                text: text,
                isFinal: true
            )]
        case .thinking:
            // Chunk then complete so EngineViewModel can materialize the text.
            return [
                .thinkingChunk(blockID: id, delta: text),
                .thinkingComplete(blockID: id, duration: .zero),
            ]
        }
    }

    func clearReplayLocked() {
        replayRole = nil
        replayMessageID = nil
        replayText = ""
        replayEventID = nil
    }
}
