import AgentCore
import SwiftUI

/// Dialog shown via File → Open Project.
///
/// The user picks a folder; the engine then resolves the project type
/// (auto-detect → configure sheet if unknown).
public struct OpenProjectView: View {
    public let onCancel: () -> Void
    public let onOpen: (URL) -> Void

    public init(onCancel: @escaping () -> Void,
                onOpen: @escaping (URL) -> Void) {
        self.onCancel = onCancel
        self.onOpen = onOpen
    }

    public var body: some View {
        FolderChooserShell(
            systemImage: "folder.badge.plus",
            title: "Open a project",
            caption: "Choose a folder to add to the current workspace.",
            chooseLabel: "Choose Folder…",
            accessibilityChooseLabel: "Choose project folder",
            accessibilityCancelLabel: "Cancel open project",
            width: Theme.layout.openProjectWidth,
            onChoose: pickFolder,
            onCancel: onCancel
        )
        .padding(.horizontal, Theme.spacing.s32)
    }

    // MARK: - Private

    private func pickFolder() {
        guard let url = DesktopActions.chooseDirectoryPanel(prompt: "Add Project") else { return }
        onOpen(url)
    }
}
