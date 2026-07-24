#if DEBUG
import Foundation
import AgentCore
import AgentProtocol

/// Preview/test scaffolding for `EngineViewModel`. DEBUG-only so it never ships.
public extension EngineViewModel {

    /// A no-op command port so previews can construct a view model without a
    /// real engine or PTY.
    struct NoopEnginePort: AgentEngineCommandPort {
        public init() {}
        public func send(_ command: AgentCommand) async throws {}
    }

    /// A view model populated with sample projects + sessions for previews.
    static var preview: EngineViewModel {
        let model = EngineViewModel(engine: NoopEnginePort(), bus: MulticastEventBus())
        model.applyPreviewState(
            workspace: PreviewFixtures.workspace,
            projects: [
                .init(path: PreviewFixtures.workspace.path,
                      displayName: "Sample",
                      projectType: .claudeCode),
                .init(path: PreviewFixtures.workspace.appendingPathComponent("api").path,
                      displayName: "api",
                      projectType: .codex),
            ],
            sessions: [
                PreviewFixtures.workspace.path: [
                    SessionSummary(id: "s1", agentID: .claudeCode,
                                   workspace: PreviewFixtures.workspace,
                                   title: "Add session navigator",
                                   lastActivity: Date(), messageCount: 12),
                    SessionSummary(id: "s2", agentID: .claudeCode,
                                   workspace: PreviewFixtures.workspace,
                                   title: "Fix transcript slug bug",
                                   lastActivity: Date().addingTimeInterval(-90_000),
                                   messageCount: 5),
                ],
            ]
        )
        model.availableModels = [
            AgentModelOption(id: "sonnet", label: "Sonnet"),
            AgentModelOption(id: "opus", label: "Opus"),
        ]
        model.availableAgentModes = [
            AgentModeOption(id: "agent", label: "Agent", selectCommands: []),
            AgentModeOption(id: "think", label: "Think",
                                   selectCommands: [.setAgentMode(id: AgentModeCommandID.think)]),
            AgentModeOption(id: "review", label: "Review",
                                   selectCommands: [.setAgentMode(id: AgentModeCommandID.review)]),
        ]
        model.selectedAgentModeID = "agent"
        return model
    }

    /// Navigator + conversation sample for conversation/composer previews.
    static var previewConversation: EngineViewModel {
        let model = preview
        model.applyPreviewConversationState()
        return model
    }
}
#endif
