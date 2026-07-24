import Foundation

/// Which live CLI slot a project binds to. Not a free-form string.
public enum AgentInstanceIdentity: Hashable, Sendable, Codable {
    /// Default shared slot for this project+agent — reused across returns.
    case shared
    /// Dedicated slot minted when Advanced → Launch new agent instance is on.
    case dedicated(UUID)
}

/// Pool lookup key: one live process per project+agent (+ instance identity).
public struct AgentRuntimeKey: Hashable, Sendable {
    public var projectPath: String
    public var agentID: AgentID
    public var instance: AgentInstanceIdentity

    public init(projectPath: String,
                agentID: AgentID,
                instance: AgentInstanceIdentity = .shared) {
        self.projectPath = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        self.agentID = agentID
        self.instance = instance
    }
}

/// One parked or active agent CLI process owned by `AgentEngine`.
struct AgentRuntime {
    let key: AgentRuntimeKey
    let adapter: any AgentAdapter
    let transport: any AgentTransport
    var hookServer: HookServer?
    var workspace: URL
    /// Session/thread id this process is currently bound to (Claude `/resume`,
    /// Codex thread, ACP session).
    var boundSessionID: String?
    var forwardingTask: Task<Void, Never>?
    var bellTask: Task<Void, Never>?
    var sessionIDContinuation: AsyncStream<String>.Continuation?
    var lastActivatedAt: Date
}
