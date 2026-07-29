#if DEBUG
import Foundation
import AgentCore
import AgentProtocol

/// Shared sample data for SwiftUI `#Preview` blocks.
enum PreviewFixtures {

    enum ProjectNames {
        static let sample = "Sample"
        static let api = "api"
    }

    enum ProjectPaths {
        static let apiSubpath = ProjectNames.api
    }

    static let workspace = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("CodemixerPreview/\(ProjectNames.sample)", isDirectory: true)

    static var apiProjectURL: URL {
        workspace.appendingPathComponent(ProjectPaths.apiSubpath, isDirectory: true)
    }

    static var sampleProjectRef: WorkspaceProjectsStore.ProjectRef {
        WorkspaceProjectsStore.ProjectRef(
            path: workspace.path,
            displayName: ProjectNames.sample,
            projectType: .claudeCode
        )
    }

    static var apiProjectRef: WorkspaceProjectsStore.ProjectRef {
        WorkspaceProjectsStore.ProjectRef(
            path: apiProjectURL.path,
            displayName: ProjectNames.api,
            projectType: .codex
        )
    }

    static let recentProjects: [SessionStore.ProjectRecord] = [
        .init(path: workspace.path,
              displayName: ProjectNames.sample,
              lastOpened: Date(),
              lastSessionID: "s1"),
        .init(path: apiProjectURL.path,
              displayName: ProjectNames.api,
              lastOpened: Date().addingTimeInterval(-86_400),
              lastSessionID: nil),
    ]

    static func conversationMessages() -> [EngineViewModel.Message] {
        let userID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let asstID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let actionID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        return [
            .user(bubbleID: userID, text: "Add a session navigator to the sidebar."),
            .clientAction(ClientAction(
                id: actionID,
                kind: .mode,
                title: "Mode",
                detail: "Think"
            )),
            .assistant(bubbleID: asstID,
                       text: "I'll scaffold the navigator with projects and resumable sessions."),
        ]
    }

    /// Multi-turn, multi-phase Custom ACP file session — feeds the workbench
    /// lane previews (`IndexRailView` phase grouping, `SessionScrubber`,
    /// rail ETA/round badges) plus a Comfortable/Compact/Focus density check.
    static func customACPPhasesFixture() -> (
        messages: [EngineViewModel.Message],
        toolCalls: [EngineViewModel.ToolCallEntry],
        phaseMarkers: [EngineViewModel.PhaseMarker]
    ) {
        let now = Date()
        func phase(_ id: String, _ label: String, _ ordinal: Int, _ group: SessionPhase.Group) -> SessionPhase {
            SessionPhase(id: id, label: label, ordinal: ordinal, group: group)
        }

        let user1 = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let asst1 = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let thinking1 = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let user2 = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
        let asst2 = UUID(uuidString: "00000000-0000-0000-0000-000000000014")!
        let user3 = UUID(uuidString: "00000000-0000-0000-0000-000000000015")!
        let thinking3 = UUID(uuidString: "00000000-0000-0000-0000-000000000016")!

        let messages: [EngineViewModel.Message] = [
            .user(bubbleID: user1, text: "Migrate orders.ts to the new billing client."),
            .thinkingComplete(blockID: thinking1, text: "Scanning call sites for the legacy billing client.", duration: .seconds(3)),
            .toolCall(callID: "tool-1"),
            .assistant(bubbleID: asst1, text: "Replaced 4 call sites with `BillingClientV2`."),
            .user(bubbleID: user2, text: "Looks good — anything risky?"),
            .assistant(bubbleID: asst2, text: "One call site drops a retry parameter; flagging for review."),
            .user(bubbleID: user3, text: "Fix the retry parameter and re-run."),
            .thinkingChunk(blockID: thinking3, delta: "Re-adding the retry parameter with the v2 default…"),
        ]

        let toolCalls: [EngineViewModel.ToolCallEntry] = [
            EngineViewModel.ToolCallEntry(
                id: "tool-1",
                name: "edit_file",
                input: .init(summary: "Edit orders.ts", jsonPayload: "{\"path\":\"orders.ts\"}"),
                finished: true,
                success: true,
                output: .init(summary: "4 call sites updated", jsonPayload: nil, errorMessage: nil)
            ),
        ]

        let phaseMarkers: [EngineViewModel.PhaseMarker] = [
            .init(messageIndex: 0, phase: phase("migrating", "Migrate", 2, .migrate), at: now.addingTimeInterval(-600)),
            .init(messageIndex: 4, phase: phase("reviewing", "Review", 4, .review), at: now.addingTimeInterval(-300)),
            .init(messageIndex: 6, phase: phase("fixing", "Fix", 5, .fix), at: now.addingTimeInterval(-60)),
        ]

        return (messages, toolCalls, phaseMarkers)
    }

    @MainActor
    static func paletteCommands(for model: EngineViewModel) -> [PaletteCommand] {
        [
            PaletteCommand(id: "new-chat",
                           title: "New Chat",
                           subtitle: "Start a fresh session",
                           systemImage: "plus.message") { model.startNewSession() },
            PaletteCommand(id: "toggle-sidebar",
                           title: "Toggle Sidebar",
                           subtitle: nil,
                           systemImage: "sidebar.left") { model.sidebarVisible.toggle() },
        ]
    }
}
#endif
