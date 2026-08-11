import Foundation
import AgentCore

/// One node in a folder-tree hierarchy built from flat `FolderFileEntry` rows.
struct FolderTreeNode: Hashable, Identifiable {
    var id: String { entry.relativePath }
    let entry: FolderFileEntry
    let children: [FolderTreeNode]
}
