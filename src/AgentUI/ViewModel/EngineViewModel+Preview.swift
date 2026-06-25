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
        let workspace = URL(fileURLWithPath: "/Users/you/Code/Sample")
        model.applyPreviewState(
            workspace: workspace,
            projects: [
                .init(path: workspace.path, displayName: "Sample"),
                .init(path: workspace.appendingPathComponent("api").path, displayName: "api"),
            ],
            sessions: [
                workspace.path: [
                    SessionSummary(id: "s1", workspace: workspace,
                                   title: "Add session navigator",
                                   lastActivity: Date(), messageCount: 12),
                    SessionSummary(id: "s2", workspace: workspace,
                                   title: "Fix transcript slug bug",
                                   lastActivity: Date().addingTimeInterval(-90_000),
                                   messageCount: 5),
                ],
            ]
        )
        return model
    }
}
#endif
