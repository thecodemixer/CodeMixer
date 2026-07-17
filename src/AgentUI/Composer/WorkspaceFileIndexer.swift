import Foundation

/// Scans a workspace tree for relative file paths used by the composer @-file picker.
struct WorkspaceFileIndexer: Sendable {

    static let defaultLimit = 200

    private static let skipDirectories: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", ".swiftpm", "__pycache__", ".DS_Store",
    ]
    private static let photoLibraryExtensions: Set<String> = [
        "photoslibrary", "photolibrary", "aplibrary",
    ]

    func files(in workspace: URL, limit: Int = Self.defaultLimit) -> [String] {
        var results: [String] = []
        let workspacePrefix = workspace.standardizedFileURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: workspace,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in enumerator {
            if results.count >= limit { break }
            let name = url.lastPathComponent
            if Self.skipDirectories.contains(name)
                || Self.photoLibraryExtensions.contains(url.pathExtension.lowercased()) {
                enumerator.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
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
