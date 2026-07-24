import Foundation
@_exported import AgentProtocol

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
    /// When `false`, palette activation routes through `runSlashCommand`
    /// (e.g. Cursor ACP mode switches). Default `true`
    /// submits the command text as a user prompt with optimistic UI feedback.
    public let sendsAsPrompt: Bool

    public init(id: String,
                name: String,
                summary: String,
                isProjectDefined: Bool = false,
                sendsAsPrompt: Bool = true) {
        self.id = id
        self.name = name
        self.summary = summary
        self.isProjectDefined = isProjectDefined
        self.sendsAsPrompt = sendsAsPrompt
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
    /// True when a background session has a parked permission or other attention signal.
    public let needsAttention: Bool
    /// True when this session is the project's overview / control session (hosted
    /// dashboard). File-scoped sessions leave this false so the UI stays chat-only.
    public let isOverview: Bool
    /// Last dashboard URL advertised for overview sessions, when known.
    public let overviewURL: URL?

    public init(id: String,
                agentID: AgentID,
                workspace: URL,
                title: String,
                lastActivity: Date,
                messageCount: Int,
                gitBranch: String? = nil,
                needsAttention: Bool = false,
                isOverview: Bool = false,
                overviewURL: URL? = nil) {
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
    }
}
