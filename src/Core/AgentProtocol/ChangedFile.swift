import Foundation

/// A workspace file with uncommitted changes, tracked for the diff panel and
/// engine reconcile loop. Identity is the display path — relative to the
/// workspace when possible, otherwise absolute.
public struct ChangedFile: Sendable, Hashable, Identifiable, Codable {
    public var id: String { relativePath }
    public let relativePath: String

    public init(relativePath: String) {
        self.relativePath = relativePath
    }

    public init(url: URL, workspace: URL?) {
        self.relativePath = Self.relativePath(for: url, workspace: workspace)
    }

  /// Path to store and display: relative to `workspace` when the file lies
    /// inside it, otherwise the absolute filesystem path.
    public static func relativePath(for url: URL, workspace: URL?) -> String {
        guard let workspace else { return url.path }
        let workspacePaths = [workspace, workspace.resolvingSymlinksInPath()]
            .map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }
        let filePath = url.path
        let resolvedFilePath = url.resolvingSymlinksInPath().path
        for root in workspacePaths {
            if filePath.hasPrefix(root) {
                return String(filePath.dropFirst(root.count))
            }
            if resolvedFilePath.hasPrefix(root) {
                return String(resolvedFilePath.dropFirst(root.count))
            }
        }
        return filePath
    }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let path = try? single.decode(String.self) {
            relativePath = path
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        relativePath = try container.decode(String.self, forKey: .relativePath)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(relativePath)
    }

    private enum CodingKeys: String, CodingKey {
        case relativePath
    }
}
