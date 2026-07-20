import Foundation

import AgentCore

/// One Codemixer-owned ACP conversation turn (local history / JSONL).
public struct ACPConversationTurn: Sendable, Codable, Hashable {
    public let role: String
    public let text: String
    public let toolCallID: String?
    public let toolSuccess: Bool?
    public let toolOutputSummary: String?
    public let toolInputJSON: String?

    public init(role: String,
                text: String,
                toolCallID: String? = nil,
                toolSuccess: Bool? = nil,
                toolOutputSummary: String? = nil,
                toolInputJSON: String? = nil) {
        self.role = role
        self.text = text
        self.toolCallID = toolCallID
        self.toolSuccess = toolSuccess
        self.toolOutputSummary = toolOutputSummary
        self.toolInputJSON = toolInputJSON
    }
}

/// Persistence surface for ACP resumable sessions and local turn cache.
public protocol ACPSessionIndexing: Sendable {
    func recordSession(id: String,
                       customAgentID: String,
                       workspace: URL,
                       title: String?) async

    func recordTurn(sessionID: String, customAgentID: String, title: String?) async

    func appendConversationTurn(sessionID: String,
                                customAgentID: String,
                                role: String,
                                text: String) async

    func appendToolTurn(sessionID: String,
                        customAgentID: String,
                        toolCallID: String,
                        name: String,
                        success: Bool,
                        outputSummary: String,
                        inputJSON: String?) async

    func localHistoryEvents(sessionID: String,
                            customAgentID: String,
                            random: any RandomSource) async -> [AgentEvent]

    func summaries(workspace: URL, customAgentID: String) async -> [SessionSummary]
}
