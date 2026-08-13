import SwiftUI
import AgentCore

extension FolderTreeView {
    func treeColumn(_ treeModel: FolderTreeViewModel) -> some View {
        FolderTreeColumn(
            treeModel: treeModel,
            accessibilityLabel: "Folder tree",
            // Ideal keeps the familiar starting width; the split handle may drag
            // it wider, so no hard maximum.
            maxWidth: .infinity,
            showsPinActions: FolderProjectKind.folderTree.supportsPinnedSidebarEntries,
            onQuickLook: { url in quickLook(url: url) },
            onPin: { path in model.pinFolderPath(path, in: project.path) },
            onUnpin: { path in model.unpinFolderPath(path, in: project.path) }
        )
    }
}
