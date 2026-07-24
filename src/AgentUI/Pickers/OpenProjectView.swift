import AgentCore
import SwiftUI

/// Dialog shown via File → Add Existing Project….
///
/// The user picks a folder; the engine then resolves the project type
/// (auto-detect → configure sheet if unknown). Advanced options sit on the
/// Cancel row so prefer-fresh launch can be set before the folder is adopted.
public struct OpenProjectView: View {
    public let onCancel: () -> Void
    public let onOpen: (_ info: ProjectDraft) -> Void

    @State private var preferFreshAgentProcess = false

    public init(onCancel: @escaping () -> Void,
                onOpen: @escaping (_ info: ProjectDraft) -> Void) {
        self.onCancel = onCancel
        self.onOpen = onOpen
    }

    public var body: some View {
        FolderChooserShell(
            systemImage: "folder.badge.plus",
            title: "Add Existing Project",
            caption: "Choose a folder to add to the current workspace.",
            chooseLabel: "Choose Folder…",
            accessibilityChooseLabel: "Choose project folder",
            accessibilityCancelLabel: "Cancel add existing project",
            width: Theme.layout.openProjectWidth,
            onChoose: pickFolder,
            onCancel: onCancel
        ) {
            ProjectAdvancedOptions(preferFreshAgentProcess: $preferFreshAgentProcess)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Private

    private func pickFolder() {
        guard let url = DesktopActions.chooseDirectoryPanel(prompt: "Add Project") else { return }
        onOpen(.existingFolder(url, preferFreshAgentProcess: preferFreshAgentProcess))
    }
}
