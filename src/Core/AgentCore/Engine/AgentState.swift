import Foundation
import AgentProtocol

/// The engine's canonical state machine.
///
/// Each `AgentEvent` advances the state through a single reducer so the UI
/// can derive its activity indicator from one source of truth rather than
/// peeking at half a dozen booleans.
public enum AgentState: Sendable, Hashable {
    case idle
    case awaitingFirstChunk(turnID: UUID, startedAt: Date)
    case streamingText(turnID: UUID, startedAt: Date)
    case thinking(turnID: UUID, blockID: UUID, startedAt: Date)
    case runningTool(turnID: UUID, callID: String, name: String, startedAt: Date)
    case waitingPermission(turnID: UUID, prompt: PermissionPrompt)
    case stillWorking(turnID: UUID, kind: Kind)
    case probablyStuck(turnID: UUID, kind: Kind)

    public enum Kind: Sendable, Hashable {
        case awaitingFirstChunk, streamingText, thinking, runningTool
    }

    public var substate: ActivitySubstate {
        switch self {
        case .idle:                  return .idle
        case .awaitingFirstChunk:    return .awaitingFirstChunk
        case .streamingText:         return .streamingText
        case .thinking:              return .thinking
        case .runningTool:           return .runningTool
        case .waitingPermission:     return .waitingPermission
        case .stillWorking:          return .stillWorking
        case .probablyStuck:         return .probablyStuck
        }
    }

    public var turnID: UUID? {
        switch self {
        case .idle:                          return nil
        case .awaitingFirstChunk(let id, _),
             .streamingText(let id, _),
             .thinking(let id, _, _),
             .runningTool(let id, _, _, _),
             .waitingPermission(let id, _),
             .stillWorking(let id, _),
             .probablyStuck(let id, _):
            return id
        }
    }
}
