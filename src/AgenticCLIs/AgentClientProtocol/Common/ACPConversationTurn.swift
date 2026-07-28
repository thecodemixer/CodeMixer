import Foundation

import AgentCore

/// Semantic role used while coalescing ACP stream chunks and decoding the
/// retired project-local catalog format.
public enum ACPTurnRole: String, Sendable, Codable, Hashable {
    case user
    case assistant
    case agent
    case thinking
    case tool
    case phase
    case unknown

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = ACPTurnRole(rawValue: try container.decode(String.self)) ?? .unknown
    }

    public var stored: ACPTurnRole {
        self == .agent ? .assistant : self
    }

    public init(historyChunk raw: String) {
        switch raw {
        case ACPTurnRole.user.rawValue:
            self = .user
        case ACPTurnRole.thinking.rawValue:
            self = .thinking
        default:
            self = .agent
        }
    }
}

/// One row in the retired project-local ACP catalog format.
public struct ACPConversationTurn: Sendable, Codable, Hashable {
    public let role: ACPTurnRole
    public let text: String
    public let toolCallID: String?
    public let toolSuccess: Bool?
    public let toolOutputSummary: String?
    public let toolInputJSON: String?
    public let phase: SessionPhase?

    public init(role: ACPTurnRole,
                text: String,
                toolCallID: String? = nil,
                toolSuccess: Bool? = nil,
                toolOutputSummary: String? = nil,
                toolInputJSON: String? = nil,
                phase: SessionPhase? = nil) {
        self.role = role
        self.text = text
        self.toolCallID = toolCallID
        self.toolSuccess = toolSuccess
        self.toolOutputSummary = toolOutputSummary
        self.toolInputJSON = toolInputJSON
        self.phase = phase
    }
}
