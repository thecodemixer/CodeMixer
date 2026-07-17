import AgentProtocol

/// Maps Codemixer permission modes onto Codex App Server thread policy.
public enum CodexPolicyMapping {
    public struct Policy: Sendable, Hashable {
        public let approval: CodexApprovalPolicy
        public let sandbox: CodexSandboxMode

        public init(approval: CodexApprovalPolicy, sandbox: CodexSandboxMode) {
            self.approval = approval
            self.sandbox = sandbox
        }
    }

    public static func policy(for mode: PermissionMode) -> Policy {
        switch mode {
        case .default:
            return Policy(approval: .onRequest, sandbox: .workspaceWrite)
        case .acceptEdits:
            return Policy(approval: .untrusted, sandbox: .workspaceWrite)
        case .bypassPermissions:
            return Policy(approval: .never, sandbox: .dangerFullAccess)
        case .plan:
            return Policy(approval: .untrusted, sandbox: .readOnly)
        }
    }
}
