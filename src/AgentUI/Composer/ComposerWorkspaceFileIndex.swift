import Foundation

/// Cached workspace-relative file paths for the composer @-file picker.
@MainActor
final class ComposerWorkspaceFileIndex {
    private let indexer = WorkspaceFileIndexer()
    private(set) var files: [String] = []

    func refresh(workspace: URL) {
        Task.detached(priority: .utility) { [weak self, indexer] in
            let listed = indexer.files(in: workspace)
            await MainActor.run { [weak self] in
                self?.files = listed
            }
        }
    }
}
