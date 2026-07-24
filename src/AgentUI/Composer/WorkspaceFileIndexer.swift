import Foundation
import AgentCore

/// Scans a workspace tree for relative file paths used by the composer @-file picker.
struct WorkspaceFileIndexer: Sendable {
    private let fileSystem: any FileSystem

    static let defaultLimit = 200

    private static let skipDirectories: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", ".swiftpm", "__pycache__", ".DS_Store",
    ]
    private static let photoLibraryExtensions: Set<String> = [
        "photoslibrary", "photolibrary", "aplibrary",
    ]

    init(fileSystem: any FileSystem = SystemFileSystem()) {
        self.fileSystem = fileSystem
    }

    func files(in workspace: URL, limit: Int = Self.defaultLimit) -> [String] {
        var results: [String] = []
        let workspacePrefix = workspace.standardizedFileURL.path + "/"
        var pending = [workspace]

        while let directory = pending.popLast(), results.count < limit {
            let children = (try? fileSystem.contentsOfDirectory(at: directory)) ?? []
            for url in children where results.count < limit {
                let name = url.lastPathComponent
                if Self.skipDirectories.contains(name)
                    || Self.photoLibraryExtensions.contains(url.pathExtension.lowercased()) {
                    continue
                }
                if fileSystem.isDirectory(at: url) {
                    pending.append(url)
                    continue
                }
                let path = url.standardizedFileURL.path
                let relativePath = path.hasPrefix(workspacePrefix)
                    ? String(path.dropFirst(workspacePrefix.count))
                    : url.lastPathComponent
                results.append(relativePath)
            }
        }
        return results.sorted()
    }
}
