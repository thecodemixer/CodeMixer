#if DEBUG
import Foundation
import AgentCore
import AgentProtocol

/// Shared sample data for SwiftUI `#Preview` blocks.
enum PreviewFixtures {

    static let workspace = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("CodemixerPreview/Sample", isDirectory: true)

    static let recentProjects: [SessionStore.ProjectRecord] = [
        .init(path: workspace.path,
              displayName: "Sample",
              lastOpened: Date(),
              lastSessionID: "s1"),
        .init(path: workspace.appendingPathComponent("api").path,
              displayName: "api",
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
