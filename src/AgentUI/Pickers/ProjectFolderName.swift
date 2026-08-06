import Foundation
import AgentCore

/// Checks whether New Project would create `<workspace>/<name>/` on top of an
/// existing sibling folder (registered project or stray directory).
enum ProjectFolderName {
    /// User-facing copy for the New Project name field.
    static let collisionGuidance =
        "A folder with that name already exists in this workspace. Choose a different project name."

    static func proposedFolder(name: String, in workspace: URL) -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return workspace.appendingPathComponent(trimmed, isDirectory: true)
    }

    /// `nil` when the name is free (or empty — other validation owns emptiness).
    static func collisionMessage(name: String,
                                 in workspace: URL,
                                 fileSystem: any FileSystem) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folder = proposedFolder(name: trimmed, in: workspace)
        guard fileSystem.fileExists(at: folder) || fileSystem.isDirectory(at: folder) else {
            return nil
        }
        return collisionGuidance
    }
}
