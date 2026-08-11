import SwiftUI
import AgentCore

/// Standalone host for a sidebar pin on a folder-tree project.
struct FolderTreePreviewPanelHost: View {
    @Bindable var model: EngineViewModel
    let project: WorkspaceProjectsStore.ProjectRef
    let relativePath: String

    @State private var treeModel: FolderTreeViewModel?

    var body: some View {
        Group {
            if let treeModel {
                FolderTreePreviewPanel(
                    model: treeModel,
                    onClose: {
                        model.pendingFolderSelectionRelativePath = nil
                        model.setActiveFolderSelection(nil)
                    },
                    trailingActionTitle: "Show files",
                    onTrailingAction: {
                        if let path = model.activeFolderSelectionRelativePath {
                            model.pendingFolderSelectionRelativePath = path
                        }
                        model.exitFolderPreviewOnly()
                    }
                )
            } else {
                ProgressView("Loading preview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading preview")
            }
        }
        .background(Theme.surface.canvas)
        .onAppear { ensureModel() }
        .onChange(of: relativePath) { _, _ in recreateModel() }
        .onChange(of: project.path) { _, _ in recreateModel() }
        .onDisappear { treeModel?.stop() }
    }

    private func ensureModel() {
        guard treeModel == nil else { return }
        recreateModel()
    }

    private func recreateModel() {
        treeModel?.stop()
        let created = FolderTreeViewModel(
            root: URL(fileURLWithPath: project.path),
            initialRelativePath: relativePath
        )
        treeModel = created
        created.start(previewOnly: true)
        model.setActiveFolderSelection(relativePath)
    }
}
