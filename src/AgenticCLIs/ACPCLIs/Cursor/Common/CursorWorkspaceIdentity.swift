import CryptoKit
import Foundation

enum CursorWorkspaceIdentity {
    /// Cursor names project chat directories with MD5(absolute workspace path).
    /// MD5 is required for vendor path identity compatibility; it is not a
    /// security primitive and must not be replaced with a stronger digest.
    static func projectDirectoryName(forWorkspace workspace: URL) -> String {
        Insecure.MD5.hash(data: Data(workspace.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func chatsDirectories(forWorkspace workspace: URL,
                                 cursorDirectory: URL) -> [URL] {
        let raw = workspace.standardizedFileURL
        let resolved = raw.resolvingSymlinksInPath().standardizedFileURL
        var names = [projectDirectoryName(forWorkspace: raw)]
        let resolvedName = projectDirectoryName(forWorkspace: resolved)
        if !names.contains(resolvedName) {
            names.append(resolvedName)
        }
        return names.map {
            cursorDirectory.appendingPathComponent("chats/\($0)", isDirectory: true)
        }
    }

    static func storeURL(chatID: String, in projectDirectory: URL) -> URL {
        projectDirectory
            .appendingPathComponent(chatID, isDirectory: true)
            .appendingPathComponent("store.db")
    }
}
