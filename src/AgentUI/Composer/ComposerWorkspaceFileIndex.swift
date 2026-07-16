import Foundation

/// Cached workspace-relative file paths for the composer @-file picker.
@MainActor
final class ComposerWorkspaceFileIndex {
    private(set) var files: [String] = []

    func refresh(workspace: URL) {
        Task.detached(priority: .utility) { [weak self] in
            let listed = DesktopActions.workspaceFiles(
                in: workspace,
                limit: WorkspaceFilePickerLimits.maxEntries
            )
            await MainActor.run { [weak self] in
                self?.files = listed
            }
        }
    }
}

private enum WorkspaceFilePickerLimits {
    static let maxEntries = 200
}
