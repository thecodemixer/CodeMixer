#if DEBUG
import Foundation
import AgentCore
import AgentProtocol

/// Shared sample data for SwiftUI `#Preview` blocks.
enum PreviewFixtures {

    static let workspace = URL(fileURLWithPath: "/Users/you/Code/Sample")

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

    static let sampleAuthURL = URL(string: "https://claude.ai/oauth/authorize?client_id=preview")!

    static let installHint = "Install Claude Code with npm, then relaunch Codemixer."

    static func conversationMessages() -> [EngineViewModel.Message] {
        let userID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let asstID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        return [
            .user(bubbleID: userID, text: "Add a session navigator to the sidebar."),
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
                           systemImage: "plus.message") { model.send(.newSession) },
            PaletteCommand(id: "toggle-sidebar",
                           title: "Toggle Sidebar",
                           subtitle: nil,
                           systemImage: "sidebar.left") { model.sidebarVisible.toggle() },
        ]
    }
}
#endif
