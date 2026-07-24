import AgentCore
import SwiftUI

/// Workspace picker shown when no workspace is open, or via File → Open Workspace.
///
/// The user picks a folder from disk; the engine resolves the workspace or
/// project type after selection and presents configuration only when needed.
public struct WorkspacePickerView: View {
    public let onOpen: (URL, _ resumeSessionID: String?) -> Void
    public let onCancel: () -> Void

    public init(onCancel: @escaping () -> Void = {},
                onOpen: @escaping (URL, _ resumeSessionID: String?) -> Void) {
        self.onCancel = onCancel
        self.onOpen = onOpen
    }

    public var body: some View {
        FolderChooserShell(
            systemImage: "folder.fill.badge.gearshape",
            title: "Open a workspace",
            caption: "Choose a folder from disk.",
            chooseLabel: "Choose Folder…",
            accessibilityChooseLabel: "Choose workspace folder",
            accessibilityCancelLabel: "Cancel open workspace",
            width: Theme.layout.projectPickerWidth,
            onChoose: chooseFolder,
            onCancel: onCancel
        )
    }

    private func chooseFolder() {
        if let url = DesktopActions.chooseDirectoryPanel() {
            open(url, resumeSessionID: nil)
        }
    }

    private func open(_ url: URL, resumeSessionID: String?) {
        onOpen(url, resumeSessionID)
    }
}

#if DEBUG
#Preview("Workspace picker – Light") {
    WorkspacePickerView { _, _ in }
        .frame(width: 360, height: 220)
        .preferredColorScheme(.light)
}

#Preview("Workspace picker – Dark") {
    WorkspacePickerView { _, _ in }
        .frame(width: 360, height: 220)
        .preferredColorScheme(.dark)
}
#endif
