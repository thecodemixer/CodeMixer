import Foundation
import CryptoKit
import AgentProtocol

/// Permission prompt the agent surfaced before executing a tool.
public struct PermissionPrompt: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let toolName: String
    public let summary: String
    public let argumentsSummary: String
    public let requestedAt: Date

    public init(id: UUID,
                toolName: String,
                summary: String,
                argumentsSummary: String,
                requestedAt: Date) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.argumentsSummary = argumentsSummary
        self.requestedAt = requestedAt
    }

    public init(toolName: String,
                summary: String,
                argumentsSummary: String,
                requestedAt: Date) {
        self.init(id: PermissionPrompt.stableID(
            toolName: toolName,
            summary: summary,
            argumentsSummary: argumentsSummary,
            requestedAt: requestedAt
        ),
        toolName: toolName,
        summary: summary,
        argumentsSummary: argumentsSummary,
        requestedAt: requestedAt)
    }

    private static func stableID(toolName: String,
                                 summary: String,
                                 argumentsSummary: String,
                                 requestedAt: Date) -> UUID {
        let material = "\(toolName)|\(summary)|\(argumentsSummary)|\(requestedAt.timeIntervalSince1970)"
        let digest = Array(SHA256.hash(data: Data(material.utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}

/// Compact, structured description of a tool's input. Adapters fill in only
/// the fields that matter; everything else is `nil`.
public struct ToolInput: Sendable, Hashable {
    public var summary: String
    public var jsonPayload: String?

    public init(summary: String, jsonPayload: String? = nil) {
        self.summary = summary
        self.jsonPayload = jsonPayload
    }
}

public struct ToolOutput: Sendable, Hashable {
    public var summary: String
    public var jsonPayload: String?
    public var errorMessage: String?

    public init(summary: String, jsonPayload: String? = nil, errorMessage: String? = nil) {
        self.summary = summary
        self.jsonPayload = jsonPayload
        self.errorMessage = errorMessage
    }
}

/// Live progress for a running tool call. Typed so each renderer reaches for
/// exactly the data it needs.
public enum ToolProgress: Sendable, Hashable {
    case bashLine(String)
    case fileBytes(written: Int, total: Int?)
    case generic(message: String)
}

/// Authentication state for an adapter.
public enum AuthStatus: Sendable, Hashable {
    case authenticated(account: String?)
    case unauthenticated
    case expired
    case unknown
}

/// Aggregated context an adapter receives when asked to build its launch
/// argv: workspace, hook socket path, optional resume id, prefs.
public struct LaunchContext: Sendable {
    public let workspace: URL
    public let hookSocketPath: String?
    public let resumeSessionID: String?
    public let permissionMode: PermissionMode
    public let extraEnv: [String: String]

    public init(workspace: URL,
                hookSocketPath: String? = nil,
                resumeSessionID: String? = nil,
                permissionMode: PermissionMode = .default,
                extraEnv: [String: String] = [:]) {
        self.workspace = workspace
        self.hookSocketPath = hookSocketPath
        self.resumeSessionID = resumeSessionID
        self.permissionMode = permissionMode
        self.extraEnv = extraEnv
    }
}

/// Delivery channel for the user's permission decision back to the agent.
public enum PermissionResponseDelivery: Sendable {
    case writePTY(Data)
    case respondToHookProcess(jsonStdout: Data)
    case both(ptyBytes: Data, hookStdout: Data)
}

/// Slash command surfaced in the UI palette and reachable by mouse + voice.
public struct SlashCommand: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let summary: String
    public let isProjectDefined: Bool

    public init(id: String, name: String, summary: String, isProjectDefined: Bool = false) {
        self.id = id
        self.name = name
        self.summary = summary
        self.isProjectDefined = isProjectDefined
    }
}

/// Lightweight metadata for a previously-recorded session, suitable for the
/// project picker's "Resume" list.
public struct SessionSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let agentID: AgentID
    public let workspace: URL
    public let title: String
    public let lastActivity: Date
    public let messageCount: Int
    /// Git branch captured at the time of the session, when known. Optional and
    /// purely additive (not carried on the wire).
    public let gitBranch: String?

    public init(id: String,
                agentID: AgentID,
                workspace: URL,
                title: String,
                lastActivity: Date,
                messageCount: Int,
                gitBranch: String? = nil) {
        self.id = id
        self.agentID = agentID
        self.workspace = workspace
        self.title = title
        self.lastActivity = lastActivity
        self.messageCount = messageCount
        self.gitBranch = gitBranch
    }
}

/// Why a session ended.
public typealias DomainStopReason = AgentProtocol.StopReason
